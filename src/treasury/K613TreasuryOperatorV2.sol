// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {TreasuryV2} from "src/treasury/TreasuryV2.sol";
import {AggregatorInterface} from "lib/K613-Protocol/src/contracts/dependencies/chainlink/AggregatorInterface.sol";

/// @title K613TreasuryOperator V2
/// @notice Rate-limited automation front-end for the two recurring Treasury jobs, so they can run
///         from a cron key instead of collecting two multisig signatures every week:
///           - `topUpTranche`  — restock the xK613 the lending-rewards strategy pays from;
///           - `runBuyback`    — spend collected protocol fees on K613 and stream it to stakers.
///         The governance Safe grants this contract DEFAULT_ADMIN_ROLE on the Treasury; the Safe
///         keeps its own role, so it loses nothing and can revoke this contract at any moment.
/// @dev DELTA FROM V1
///      -------------
///      Points at `TreasuryV2` instead of `Treasury` (see `StakingV2`'s NatSpec for why the
///      Staking/Treasury migration exists at all). One deliberate change beyond the retarget:
///      `TREASURY` moved from a compile-time `constant` to a constructor-set `immutable`. V1 had
///      the address baked into source as a literal — correct once, but it means every future
///      Treasury migration requires hand-editing that literal and re-verifying nobody fat-fingered
///      it, rather than just passing an address to the same deploy script. Neither form lets the
///      address change post-deploy (both are frozen into the bytecode either way) — the only thing
///      that changes is where the address is written down.
///
///      Why a weekly swap must not go through the Safe: `minK613Out` is computed against the price
///      at build time, and a Safe transaction can sit in the queue for hours waiting on a second
///      signature — by execution the bound is stale, so it either reverts or is signed blind.
///
///      Risk, stated plainly: AccessControl roles are all-or-nothing, so while this contract holds
///      Treasury admin, a bug here is a full-Treasury bug. It is therefore deliberately small, has
///      no upgrade path, no arbitrary-call function, and no way to move funds anywhere except the
///      two hard-wired Treasury calls below. The Safe's kill switch is one transaction:
///      `Treasury.revokeRole(DEFAULT_ADMIN_ROLE, operatorContract)`.
///
///      Note on relative danger: `topUpTranche` moves nothing out of the Treasury — it converts
///      Treasury-held K613 into Treasury-held xK613. Its cap bounds how much can later be drawn by
///      the rewards strategy, not how much can be stolen. `runBuyback` does spend USDC, so its cap
///      is the one that bounds real loss.
contract K613TreasuryOperatorV2 is AccessControl {
    /// @notice Callers allowed to run the jobs (cron key).
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Rate-limit window. Budgets are per fixed week, not a rolling average — so a burst of
    ///         up to 2x a budget is possible across a period boundary (spend week N's remainder at
    ///         23:59, week N+1's at 00:01). Size the caps with that in mind.
    uint256 public constant PERIOD = 7 days;

    /// @notice TreasuryV2 this operator is authorized against. Set once at deploy — see DELTA note above.
    TreasuryV2 public immutable TREASURY;
    // Monad mainnet, see docs/OPERATIONS_SOP.md D.1/D.3 — network-level constants, unrelated to
    // the Treasury/Staking migration, so these stay literal.
    address public constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address public constant SWAP_ROUTER_02 = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;
    /// @notice Live K613/USDC pool tier: 0.05%.
    uint24 public constant POOL_FEE = 500;

    /// @notice Basis-point denominator. Same meaning as StakingV2's constant of the same name.
    uint256 public constant MAX_BASIS_POINTS = 10_000;
    /// @notice Hard ceiling on the slippage tolerance: 10%. Above this the price guard stops being
    ///         a guard, so it is a compile-time constant rather than another admin-settable knob.
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    /// @notice K613/USD price feed used to bound `runBuyback`'s slippage (the TWAP feed of the
    ///         protocol-owned pool, 8 decimals). Settable by the Safe so a feed swap does not
    ///         require redeploying this contract.
    AggregatorInterface public priceFeed;
    /// @notice How far below the feed price a buyback may execute, in bps.
    uint256 public maxSlippageBps;

    /// @notice Max K613 that may be staked into the rewards stock per period.
    uint256 public trancheCapPerPeriod;
    /// @notice Max USDC (6 decimals) that may be spent on buybacks per period.
    uint256 public buybackCapPerPeriod;

    /// @notice Amount already used in a given period index (`block.timestamp / PERIOD`).
    mapping(uint256 => uint256) public trancheUsed;
    /// @notice USDC already spent on buybacks in a given period index.
    mapping(uint256 => uint256) public buybackUsed;

    /// @notice Thrown when a job would exceed its budget for the current period.
    error PeriodCapExceeded(uint256 requested, uint256 remaining);
    /// @notice Thrown when `minK613Out` is looser than the feed price allows.
    error MinOutTooLow(uint256 provided, uint256 required);
    /// @notice Thrown when the price feed is unset or returns a non-positive answer.
    error BadPriceFeed();
    /// @notice Thrown on a zero amount.
    error ZeroAmount();
    /// @notice Thrown when a zero address is passed to the constructor.
    error ZeroAddress();

    /// @notice Emitted after a successful tranche top-up.
    event TrancheToppedUp(uint256 amount, uint256 remainingThisPeriod);
    /// @notice Emitted after a successful buyback.
    event BuybackRun(uint256 amountIn, uint256 k613Out, uint256 remainingThisPeriod);
    /// @notice Emitted when the governance Safe changes a budget.
    event CapsUpdated(uint256 trancheCap, uint256 buybackCap);
    /// @notice Emitted when the governance Safe changes the price guard.
    event PriceGuardUpdated(address priceFeed, uint256 maxSlippageBps);

    /// @param admin Governance Safe — manages caps and operators.
    /// @param operator Initial cron key allowed to run the jobs.
    /// @param treasury_ TreasuryV2 this operator is authorized against.
    /// @param trancheCap Initial per-period K613 budget for `topUpTranche`.
    /// @param buybackCap Initial per-period USDC budget for `runBuyback`.
    constructor(
        address admin,
        address operator,
        address treasury_,
        uint256 trancheCap,
        uint256 buybackCap,
        address priceFeed_,
        uint256 maxSlippageBps_
    ) {
        if (admin == address(0) || operator == address(0) || treasury_ == address(0) || priceFeed_ == address(0)) {
            revert ZeroAddress();
        }
        // Same ceiling `setPriceGuard` enforces. Without it here the cap was only ever applied to
        // updates, never to the initial value — and a deploy above MAX_BASIS_POINTS would make
        // `_minOut`'s subtraction underflow, bricking `runBuyback` for the contract's whole life.
        if (maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert MinOutTooLow(maxSlippageBps_, MAX_SLIPPAGE_BPS);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        TREASURY = TreasuryV2(treasury_);
        trancheCapPerPeriod = trancheCap;
        buybackCapPerPeriod = buybackCap;
        priceFeed = AggregatorInterface(priceFeed_);
        maxSlippageBps = maxSlippageBps_;
        emit CapsUpdated(trancheCap, buybackCap);
        emit PriceGuardUpdated(priceFeed_, maxSlippageBps_);
    }

    /// @notice Current period index — budgets reset when this increments.
    function currentPeriod() public view returns (uint256) {
        return block.timestamp / PERIOD;
    }

    /// @notice K613 still available for `topUpTranche` in this period.
    function trancheRemaining() public view returns (uint256) {
        uint256 used = trancheUsed[currentPeriod()];
        return used >= trancheCapPerPeriod ? 0 : trancheCapPerPeriod - used;
    }

    /// @notice USDC still available for `runBuyback` in this period.
    function buybackRemaining() public view returns (uint256) {
        uint256 used = buybackUsed[currentPeriod()];
        return used >= buybackCapPerPeriod ? 0 : buybackCapPerPeriod - used;
    }

    /// @notice Stakes Treasury K613 into xK613 so the lending-rewards strategy has stock to pay from.
    /// @param amount K613 to stake this call; must fit the remaining period budget.
    function topUpTranche(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint256 left = trancheRemaining();
        if (amount > left) revert PeriodCapExceeded(amount, left);

        trancheUsed[currentPeriod()] += amount;
        TREASURY.stakeForExternalIncentives(amount);
        emit TrancheToppedUp(amount, trancheRemaining());
    }

    /// @notice Buys K613 with the Treasury's USDC and streams it to stakers.
    /// @param amountIn USDC to spend (6 decimals); must fit the remaining period budget.
    /// @param minK613Out Slippage bound, computed fresh by the caller. It is checked against the
    ///        price feed: merely being non-zero is not enough, or a compromised operator key could
    ///        pass 1 wei and hand the Treasury's USDC to a sandwich bot.
    function runBuyback(uint256 amountIn, uint256 minK613Out)
        external
        onlyRole(OPERATOR_ROLE)
        returns (uint256 k613Out)
    {
        if (amountIn == 0) revert ZeroAmount();
        uint256 floor = minOutFloor(amountIn);
        if (minK613Out < floor) revert MinOutTooLow(minK613Out, floor);
        uint256 left = buybackRemaining();
        if (amountIn > left) revert PeriodCapExceeded(amountIn, left);

        buybackUsed[currentPeriod()] += amountIn;
        k613Out = TREASURY.buybackV3ExactInputSingle(USDC, SWAP_ROUTER_02, amountIn, minK613Out, POOL_FEE, true);
        emit BuybackRun(amountIn, k613Out, buybackRemaining());
    }

    /// @notice Lowest `minK613Out` a buyback of `amountIn` USDC may declare, derived from the feed.
    /// @dev USDC is treated as $1. amountIn has 6 decimals, the feed 8, K613 18:
    ///      K613 at feed price = amountIn * 1e18 * 1e8 / (1e6 * answer) = amountIn * 1e20 / answer.
    ///      Kept as a single fused expression rather than dividing by the feed price first and then
    ///      applying slippage: the two-step form truncates twice, and each truncation nudges the
    ///      floor DOWN, i.e. loosens the guard. The error is sub-wei against a ~1e22 result, but
    ///      there is no reason to spend it. Overflow: `runBuyback` calls this BEFORE its period-cap
    ///      check, so amountIn is caller-controlled here and NOT yet bounded by
    ///      `buybackCapPerPeriod`. The 1e24 scaling overflows above ~1.15e53 raw USDC, which
    ///      reverts — the same outcome as the cap check it would have hit anyway, so this is a
    ///      worse error message, not a hole.
    function minOutFloor(uint256 amountIn) public view returns (uint256) {
        if (address(priceFeed) == address(0)) revert BadPriceFeed();
        int256 answer = priceFeed.latestAnswer();
        if (answer <= 0) revert BadPriceFeed();
        return (amountIn * 1e20 * (MAX_BASIS_POINTS - maxSlippageBps)) / (uint256(answer) * MAX_BASIS_POINTS);
    }

    /// @notice Governance Safe adjusts the per-period budgets (e.g. after an emission-rate change).
    function setCaps(uint256 trancheCap, uint256 buybackCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trancheCapPerPeriod = trancheCap;
        buybackCapPerPeriod = buybackCap;
        emit CapsUpdated(trancheCap, buybackCap);
    }

    /// @notice Governance Safe repoints the price guard (new feed, or a different tolerance).
    /// @param priceFeed_ K613/USD feed, 8 decimals.
    /// @param maxSlippageBps_ Tolerance in bps; capped at 10% so the guard cannot be nullified
    ///        without the Safe noticing.
    function setPriceGuard(address priceFeed_, uint256 maxSlippageBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (priceFeed_ == address(0)) revert ZeroAddress();
        if (maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert MinOutTooLow(maxSlippageBps_, MAX_SLIPPAGE_BPS);
        priceFeed = AggregatorInterface(priceFeed_);
        maxSlippageBps = maxSlippageBps_;
        emit PriceGuardUpdated(priceFeed_, maxSlippageBps_);
    }
}
