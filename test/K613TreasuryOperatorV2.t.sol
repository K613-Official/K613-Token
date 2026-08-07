// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IV3SwapRouter} from "swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {StakingV2} from "../src/staking/StakingV2.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {TreasuryV2} from "../src/treasury/TreasuryV2.sol";
import {K613TreasuryOperatorV2} from "../src/treasury/K613TreasuryOperatorV2.sol";

/// @notice Minimal Chainlink-shaped feed. Only `latestAnswer` is exercised by the operator.
contract MockPriceFeed {
    int256 public answer;

    constructor(int256 answer_) {
        answer = answer_;
    }

    function setAnswer(int256 v) external {
        answer = v;
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @notice USDC stand-in: 6 decimals, matching the real token the operator spends.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Router that pays out a settable amount of K613, so tests can simulate both an honest
///         fill and a sandwiched one (far less K613 out than the feed price implies).
contract MockRouter {
    K613 public k613;
    IERC20 public tokenIn;
    uint256 public outAmount;

    /// @dev Set post-`vm.etch` rather than in a constructor: the operator hardcodes the router
    ///      address, so the mock's runtime code is etched onto that address and constructor-set
    ///      storage would be lost.
    function init(address k613_, address tokenIn_) external {
        k613 = K613(k613_);
        tokenIn = IERC20(tokenIn_);
    }

    function setOutAmount(uint256 v) external {
        outAmount = v;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        tokenIn.transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = outAmount;
        k613.transfer(p.recipient, amountOut);
    }
}

/// @title K613TreasuryOperatorV2Test
/// @notice First test coverage for the operator contract in either version — V1 shipped to mainnet
///         holding Treasury admin over the full K613 treasury with no automated tests at all,
///         relying solely on a one-off manual review. These tests pin down the two properties that
///         review turned on:
///           1. the per-period caps actually bound spend (including across the period boundary,
///              where the fixed-window design permits a 2x burst by construction — asserted here so
///              it stays a known, deliberate property rather than a surprise);
///           2. `minK613Out` is validated against the price feed, not merely required to be
///              non-zero — the V1 review found a compromised operator key could pass `1` and hand
///              the Treasury's USDC to a sandwich bot. `test_RunBuyback_RejectsDustMinOut` is the
///              direct regression test for that hole.
contract K613TreasuryOperatorV2Test is Test {
    uint256 private constant ONE = 1e18;
    uint256 private constant EPOCH = 7 days;
    uint256 private constant PERIOD = 7 days;

    /// @notice $0.0095 with 8 decimals — roughly the live K613 price at the time of writing.
    int256 private constant FEED_PRICE = 950_000;
    uint256 private constant TRANCHE_CAP = 600_000 * ONE;
    uint256 private constant BUYBACK_CAP = 1_000e6;
    uint256 private constant MAX_SLIPPAGE_BPS = 300;

    K613 private k613;
    xK613 private xk613;
    StakingV2 private staking;
    RewardsDistributor private distributor;
    TreasuryV2 private treasury;
    K613TreasuryOperatorV2 private operator;
    MockPriceFeed private feed;
    MockUSDC private usdc;
    MockRouter private router;

    /// @dev Mirrors K613TreasuryOperatorV2.USDC — the mock is etched here.
    function operatorUsdc() internal pure returns (address) {
        return 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    }

    /// @dev Mirrors K613TreasuryOperatorV2.SWAP_ROUTER_02 — the mock is etched here.
    function operatorRouter() internal pure returns (address) {
        return 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;
    }

    address private safe = address(0x5AFE);
    address private cronKey = address(0xC0DE);
    address private stranger = address(0xBAD);

    function setUp() public {
        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new StakingV2(address(k613), address(xk613), 7 days, 5_000);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH);
        treasury = new TreasuryV2(address(k613), address(xk613), address(staking), address(distributor));

        feed = new MockPriceFeed(FEED_PRICE);

        // The operator hardcodes USDC and SwapRouter02 as constants, so the mocks must live at
        // exactly those addresses for the call chain to resolve.
        MockUSDC usdcImpl = new MockUSDC();
        vm.etch(operatorUsdc(), address(usdcImpl).code);
        usdc = MockUSDC(operatorUsdc());

        MockRouter routerImpl = new MockRouter();
        vm.etch(operatorRouter(), address(routerImpl).code);
        router = MockRouter(operatorRouter());
        router.init(address(k613), address(usdc));

        operator = new K613TreasuryOperatorV2(
            safe, cronKey, address(treasury), TRANCHE_CAP, BUYBACK_CAP, address(feed), MAX_SLIPPAGE_BPS
        );

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(treasury), true);
        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury));

        treasury.setRouterWhitelist(address(router), true);
        // The operator drives the Treasury, exactly as the Safe batch grants it on mainnet.
        treasury.grantRole(treasury.DEFAULT_ADMIN_ROLE(), address(operator));

        k613.mint(address(treasury), 5_000_000 * ONE);
        usdc.mint(address(treasury), 10_000e6);
        k613.mint(address(router), 5_000_000 * ONE);
    }

    /// @dev Honest fill: router pays exactly what the feed price implies, before slippage.
    function _atFeedPrice(uint256 amountIn) internal pure returns (uint256) {
        return (amountIn * 1e20) / uint256(FEED_PRICE);
    }

    // ---------------------------------------------------------------------------------------
    //  Wiring & access control
    // ---------------------------------------------------------------------------------------

    /// @notice Constructor stores the Safe as admin, the cron key as operator, and the caps/guard.
    function test_Constructor_SetsRolesAndConfig() public view {
        assertTrue(operator.hasRole(operator.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(operator.hasRole(operator.OPERATOR_ROLE(), cronKey));
        assertEq(address(operator.TREASURY()), address(treasury));
        assertEq(operator.trancheCapPerPeriod(), TRANCHE_CAP);
        assertEq(operator.buybackCapPerPeriod(), BUYBACK_CAP);
        assertEq(address(operator.priceFeed()), address(feed));
        assertEq(operator.maxSlippageBps(), MAX_SLIPPAGE_BPS);
    }

    /// @notice Constructor rejects every zero address, including the new `treasury_` parameter.
    function test_Constructor_RejectsZeroAddresses() public {
        vm.expectRevert(K613TreasuryOperatorV2.ZeroAddress.selector);
        new K613TreasuryOperatorV2(
            address(0), cronKey, address(treasury), TRANCHE_CAP, BUYBACK_CAP, address(feed), MAX_SLIPPAGE_BPS
        );

        vm.expectRevert(K613TreasuryOperatorV2.ZeroAddress.selector);
        new K613TreasuryOperatorV2(
            safe, address(0), address(treasury), TRANCHE_CAP, BUYBACK_CAP, address(feed), MAX_SLIPPAGE_BPS
        );

        vm.expectRevert(K613TreasuryOperatorV2.ZeroAddress.selector);
        new K613TreasuryOperatorV2(safe, cronKey, address(0), TRANCHE_CAP, BUYBACK_CAP, address(feed), MAX_SLIPPAGE_BPS);

        vm.expectRevert(K613TreasuryOperatorV2.ZeroAddress.selector);
        new K613TreasuryOperatorV2(
            safe, cronKey, address(treasury), TRANCHE_CAP, BUYBACK_CAP, address(0), MAX_SLIPPAGE_BPS
        );
    }

    /// @notice Only OPERATOR_ROLE may run the jobs — the Safe itself is deliberately not an operator.
    function test_Jobs_OnlyOperator() public {
        vm.prank(stranger);
        vm.expectRevert();
        operator.topUpTranche(1 * ONE);

        vm.prank(safe);
        vm.expectRevert();
        operator.topUpTranche(1 * ONE);
    }

    /// @notice Only the Safe may retune caps and the price guard.
    function test_Setters_OnlyAdmin() public {
        vm.prank(cronKey);
        vm.expectRevert();
        operator.setCaps(1, 1);

        vm.prank(cronKey);
        vm.expectRevert();
        operator.setPriceGuard(address(feed), 100);

        vm.prank(safe);
        operator.setCaps(123 * ONE, 456e6);
        assertEq(operator.trancheCapPerPeriod(), 123 * ONE);
        assertEq(operator.buybackCapPerPeriod(), 456e6);
    }

    /// @notice The Safe's kill switch: revoking the operator's Treasury admin stops both jobs dead,
    ///         without touching the operator contract itself.
    function test_KillSwitch_RevokingTreasuryAdminStopsJobs() public {
        vm.prank(cronKey);
        operator.topUpTranche(1_000 * ONE);

        treasury.revokeRole(treasury.DEFAULT_ADMIN_ROLE(), address(operator));

        vm.prank(cronKey);
        vm.expectRevert();
        operator.topUpTranche(1_000 * ONE);
    }

    // ---------------------------------------------------------------------------------------
    //  topUpTranche
    // ---------------------------------------------------------------------------------------

    /// @notice Happy path: Treasury K613 becomes Treasury xK613, and nothing leaves the Treasury.
    function test_TopUpTranche_ConvertsK613ToXK613_NothingLeaves() public {
        uint256 amount = 100_000 * ONE;
        uint256 k613Before = k613.balanceOf(address(treasury));

        vm.prank(cronKey);
        operator.topUpTranche(amount);

        assertEq(k613.balanceOf(address(treasury)), k613Before - amount);
        assertEq(xk613.balanceOf(address(treasury)), amount);
        assertEq(staking.totalBacking(), amount);
    }

    /// @notice Zero amount is rejected before any external call.
    function test_TopUpTranche_ZeroReverts() public {
        vm.prank(cronKey);
        vm.expectRevert(K613TreasuryOperatorV2.ZeroAmount.selector);
        operator.topUpTranche(0);
    }

    /// @notice Spend is bounded by the period cap, and `trancheRemaining` tracks it.
    function test_TopUpTranche_RespectsPeriodCap() public {
        vm.prank(cronKey);
        operator.topUpTranche(TRANCHE_CAP - 1_000 * ONE);
        assertEq(operator.trancheRemaining(), 1_000 * ONE);

        vm.prank(cronKey);
        vm.expectRevert(
            abi.encodeWithSelector(K613TreasuryOperatorV2.PeriodCapExceeded.selector, 1_001 * ONE, 1_000 * ONE)
        );
        operator.topUpTranche(1_001 * ONE);

        vm.prank(cronKey);
        operator.topUpTranche(1_000 * ONE);
        assertEq(operator.trancheRemaining(), 0);
    }

    /// @notice A fresh period restores the full budget.
    function test_TopUpTranche_BudgetResetsNextPeriod() public {
        vm.prank(cronKey);
        operator.topUpTranche(TRANCHE_CAP);
        assertEq(operator.trancheRemaining(), 0);

        vm.warp(block.timestamp + PERIOD);
        assertEq(operator.trancheRemaining(), TRANCHE_CAP);

        vm.prank(cronKey);
        operator.topUpTranche(TRANCHE_CAP);
        assertEq(xk613.balanceOf(address(treasury)), TRANCHE_CAP * 2);
    }

    /// @notice Documents the fixed-window burst: draining period N then N+1 back-to-back moves 2x the
    ///         cap within moments. This is inherent to calendar-aligned windows and is called out in
    ///         the contract's NatSpec — asserted here so it stays a deliberate, sized-for property.
    function test_TopUpTranche_PeriodBoundaryBurst_IsTwoCaps() public {
        uint256 boundary = (block.timestamp / PERIOD + 1) * PERIOD;
        vm.warp(boundary - 1);

        vm.prank(cronKey);
        operator.topUpTranche(TRANCHE_CAP);

        vm.warp(boundary);
        vm.prank(cronKey);
        operator.topUpTranche(TRANCHE_CAP);

        assertEq(xk613.balanceOf(address(treasury)), TRANCHE_CAP * 2);
    }

    // ---------------------------------------------------------------------------------------
    //  runBuyback — including the V1 review's finding
    // ---------------------------------------------------------------------------------------

    /// @notice Happy path: USDC is spent, K613 is bought, staked, and streamed to RD as rewards.
    function test_RunBuyback_BuysAndDistributes() public {
        // Someone must hold RD deposits for notifyReward to credit rather than queue.
        k613.mint(address(this), 1_000 * ONE);
        k613.approve(address(staking), 1_000 * ONE);
        staking.stake(1_000 * ONE);
        xk613.approve(address(distributor), 1_000 * ONE);
        distributor.deposit(1_000 * ONE);

        uint256 amountIn = 500e6;
        uint256 out = _atFeedPrice(amountIn);
        router.setOutAmount(out);

        uint256 rdBefore = xk613.balanceOf(address(distributor));

        uint256 minOut = operator.minOutFloor(amountIn);
        vm.prank(cronKey);
        uint256 k613Out = operator.runBuyback(amountIn, minOut);

        assertEq(k613Out, out);
        assertEq(usdc.balanceOf(address(treasury)), 10_000e6 - amountIn);
        assertEq(xk613.balanceOf(address(distributor)), rdBefore + out);
        assertEq(operator.buybackRemaining(), BUYBACK_CAP - amountIn);
    }

    /// @notice REGRESSION for the V1 manual-review finding: a dust `minK613Out` is rejected. Before
    ///         the fix, any non-zero value passed, so `1` disabled slippage protection entirely and a
    ///         compromised operator key could sandwich the Treasury's USDC.
    function test_RunBuyback_RejectsDustMinOut() public {
        uint256 amountIn = 500e6;
        uint256 floor = operator.minOutFloor(amountIn);

        vm.prank(cronKey);
        vm.expectRevert(abi.encodeWithSelector(K613TreasuryOperatorV2.MinOutTooLow.selector, 1, floor));
        operator.runBuyback(amountIn, 1);
    }

    /// @notice The floor sits exactly `maxSlippageBps` below the feed price, and a `minOut` one wei
    ///         under it is rejected — pinning the boundary, not just the obvious cases.
    function test_RunBuyback_MinOutFloorBoundary() public {
        uint256 amountIn = 500e6;
        uint256 atPrice = _atFeedPrice(amountIn);
        uint256 expectedFloor = (atPrice * (10_000 - MAX_SLIPPAGE_BPS)) / 10_000;
        assertEq(operator.minOutFloor(amountIn), expectedFloor);

        vm.prank(cronKey);
        vm.expectRevert(
            abi.encodeWithSelector(K613TreasuryOperatorV2.MinOutTooLow.selector, expectedFloor - 1, expectedFloor)
        );
        operator.runBuyback(amountIn, expectedFloor - 1);

        router.setOutAmount(atPrice);
        vm.prank(cronKey);
        operator.runBuyback(amountIn, expectedFloor);
    }

    /// @notice Even with an acceptable `minOut`, a router that underpays still reverts — the guard is
    ///         a floor on the declared bound, and the Treasury independently enforces actual output.
    function test_RunBuyback_UnderfillRevertsInTreasury() public {
        uint256 amountIn = 500e6;
        uint256 floor = operator.minOutFloor(amountIn);
        router.setOutAmount(floor - 1);

        vm.prank(cronKey);
        vm.expectRevert(TreasuryV2.InsufficientOutput.selector);
        operator.runBuyback(amountIn, floor);
    }

    /// @notice A broken feed fails closed: no buyback can be declared at all.
    function test_RunBuyback_BadFeedReverts() public {
        feed.setAnswer(0);

        vm.prank(cronKey);
        vm.expectRevert(K613TreasuryOperatorV2.BadPriceFeed.selector);
        operator.runBuyback(500e6, 1);

        feed.setAnswer(-1);
        vm.expectRevert(K613TreasuryOperatorV2.BadPriceFeed.selector);
        operator.minOutFloor(500e6);
    }

    /// @notice Zero amount is rejected.
    function test_RunBuyback_ZeroReverts() public {
        vm.prank(cronKey);
        vm.expectRevert(K613TreasuryOperatorV2.ZeroAmount.selector);
        operator.runBuyback(0, 1);
    }

    /// @notice Spend is bounded by the period cap.
    function test_RunBuyback_RespectsPeriodCap() public {
        uint256 amountIn = BUYBACK_CAP;
        router.setOutAmount(_atFeedPrice(amountIn));

        uint256 minOut = operator.minOutFloor(amountIn);
        vm.prank(cronKey);
        operator.runBuyback(amountIn, minOut);
        assertEq(operator.buybackRemaining(), 0);

        uint256 minOutSmall = operator.minOutFloor(1e6);
        vm.prank(cronKey);
        vm.expectRevert(abi.encodeWithSelector(K613TreasuryOperatorV2.PeriodCapExceeded.selector, 1e6, 0));
        operator.runBuyback(1e6, minOutSmall);
    }

    // ---------------------------------------------------------------------------------------
    //  Price guard administration
    // ---------------------------------------------------------------------------------------

    /// @notice The Safe can repoint the feed and retighten tolerance.
    function test_SetPriceGuard_UpdatesFeedAndTolerance() public {
        MockPriceFeed newFeed = new MockPriceFeed(1_000_000);

        vm.prank(safe);
        operator.setPriceGuard(address(newFeed), 100);

        assertEq(address(operator.priceFeed()), address(newFeed));
        assertEq(operator.maxSlippageBps(), 100);
        // 1e20 / 1e6 == 1e14 K613 wei per USDC unit at $0.01, minus 1%.
        assertEq(operator.minOutFloor(100e6), (100e6 * 1e20 / 1_000_000) * 9_900 / 10_000);
    }

    /// @notice Tolerance is capped at 10%, so the guard can never be widened into irrelevance —
    ///         not even by the Safe, and not by a mistyped batch.
    function test_SetPriceGuard_ToleranceCappedAtTenPercent() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(K613TreasuryOperatorV2.MinOutTooLow.selector, 1_001, 1_000));
        operator.setPriceGuard(address(feed), 1_001);

        vm.prank(safe);
        operator.setPriceGuard(address(feed), 1_000);
        assertEq(operator.maxSlippageBps(), 1_000);
    }

    /// @notice A zero feed address is rejected.
    function test_SetPriceGuard_RejectsZeroFeed() public {
        vm.prank(safe);
        vm.expectRevert(K613TreasuryOperatorV2.ZeroAddress.selector);
        operator.setPriceGuard(address(0), 100);
    }

    // ---------------------------------------------------------------------------------------
    //  Fuzz
    // ---------------------------------------------------------------------------------------

    /// @notice Across any amount and any feed price, a buyback can never be declared below the
    ///         feed-implied floor — the property the V1 review found missing.
    function testFuzz_RunBuyback_NeverAcceptsBelowFloor(uint256 rawAmountIn, int256 rawPrice, uint256 rawMinOut)
        public
    {
        uint256 amountIn = bound(rawAmountIn, 1e6, BUYBACK_CAP);
        int256 price = int256(bound(uint256(rawPrice), 1_000, 100_000_000));
        feed.setAnswer(price);

        uint256 floor = operator.minOutFloor(amountIn);
        vm.assume(floor > 0);
        uint256 minOut = bound(rawMinOut, 0, floor - 1);

        vm.prank(cronKey);
        vm.expectRevert(abi.encodeWithSelector(K613TreasuryOperatorV2.MinOutTooLow.selector, minOut, floor));
        operator.runBuyback(amountIn, minOut);
    }

    /// @notice Across any split of top-ups, total staked in a period never exceeds the cap.
    function testFuzz_TopUpTranche_NeverExceedsPeriodCap(uint256 rawA, uint256 rawB) public {
        uint256 a = bound(rawA, 1, TRANCHE_CAP);
        uint256 b = bound(rawB, 1, TRANCHE_CAP);

        vm.prank(cronKey);
        operator.topUpTranche(a);

        if (a + b > TRANCHE_CAP) {
            vm.prank(cronKey);
            vm.expectRevert(
                abi.encodeWithSelector(K613TreasuryOperatorV2.PeriodCapExceeded.selector, b, TRANCHE_CAP - a)
            );
            operator.topUpTranche(b);
            assertEq(xk613.balanceOf(address(treasury)), a);
        } else {
            vm.prank(cronKey);
            operator.topUpTranche(b);
            assertEq(xk613.balanceOf(address(treasury)), a + b);
        }
        assertLe(xk613.balanceOf(address(treasury)), TRANCHE_CAP);
    }

    // -------------------------------------------------------------------------------------
    //  currentPeriod — the boundary the budgets reset on
    // -------------------------------------------------------------------------------------

    /// @notice `currentPeriod` is a plain `block.timestamp / PERIOD`, so periods are aligned to the
    ///         epoch, not to when the operator was deployed or last ran.
    function test_CurrentPeriod_IsEpochAlignedNotDeployAligned() public {
        assertEq(operator.currentPeriod(), block.timestamp / PERIOD);

        uint256 p = operator.currentPeriod();
        vm.warp((p + 1) * PERIOD - 1);
        assertEq(operator.currentPeriod(), p, "still the same period one second before the boundary");

        vm.warp((p + 1) * PERIOD);
        assertEq(operator.currentPeriod(), p + 1, "rolls exactly on the boundary");
    }
}
