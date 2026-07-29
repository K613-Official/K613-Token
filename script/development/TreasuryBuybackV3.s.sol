// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IQuoterV2} from "swap-router-contracts/contracts/interfaces/IQuoterV2.sol";
import {Treasury} from "src/treasury/Treasury.sol";

/// @title TreasuryBuybackV3
/// @notice Step 3 of the monthly fee cycle (SOP C.1): the Treasury buys K613 with its USDC through
///         the live K613/USDC 0.05% pool and (distributeRewards=true) atomically stakes the K613 and
///         streams the resulting xK613 to stakers via the RewardsDistributor.
///         minK613Out is quoted on-chain via QuoterV2 and protected by SLIPPAGE_BPS (default 1%);
///         MIN_K613_OUT env overrides the quote entirely if set.
/// @dev Env: PRIVATE_KEY (must hold DEFAULT_ADMIN_ROLE on the Treasury); optional AMOUNT (raw USDC,
///      default = full Treasury USDC balance), SLIPPAGE_BPS (default 100), MIN_K613_OUT (manual override).
///      Monad mainnet addresses and the pool fee tier are hardcoded constants below.
contract TreasuryBuybackV3 is Script {
    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);
    /// @notice Reverts when slippage tolerance is above the 10% hard cap.
    error SlippageBpsTooHigh(uint256 bps);

    uint256 private constant MONAD_MAINNET = 143;
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100; // 1%

    // Monad mainnet (docs/OPERATIONS_SOP.md D.1/D.3)
    address private constant TREASURY_MONAD = 0x3377BAB9A510A586627D2f9013e132d269Eb9871;
    address private constant USDC_MONAD = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address private constant SWAP_ROUTER_02 = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;
    address private constant QUOTER_V2 = 0x661E93cca42AfacB172121EF892830cA3b70F08d;
    /// @notice Live K613/USDC pool tier: 0.05% (pool 0xDD5557CE..., seeded at $0.008).
    uint24 private constant POOL_FEE = 500;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 amountIn = vm.envOr("AMOUNT", uint256(0));
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", DEFAULT_SLIPPAGE_BPS);
        if (slippageBps > 1000) revert SlippageBpsTooHigh(slippageBps);

        Treasury treasury = Treasury(TREASURY_MONAD);
        address k613Addr = address(treasury.k613());

        if (amountIn == 0) {
            amountIn = IERC20(USDC_MONAD).balanceOf(TREASURY_MONAD);
            console.log("Using full Treasury USDC balance:", amountIn);
        }
        require(amountIn != 0, "TreasuryBuybackV3: zero amount");

        uint256 minK613Out = vm.envOr("MIN_K613_OUT", uint256(0));
        if (minK613Out == 0) {
            (uint256 quoted,,,) = IQuoterV2(QUOTER_V2)
                .quoteExactInputSingle(
                    IQuoterV2.QuoteExactInputSingleParams({
                        tokenIn: USDC_MONAD, tokenOut: k613Addr, amountIn: amountIn, fee: POOL_FEE, sqrtPriceLimitX96: 0
                    })
                );
            require(quoted != 0, "TreasuryBuybackV3: zero quote");
            minK613Out = quoted - (quoted * slippageBps) / 10_000;
        }

        console.log("Treasury:", TREASURY_MONAD);
        console.log("Router  :", SWAP_ROUTER_02);
        console.log("K613    :", k613Addr);
        console.log("poolFee :", uint256(POOL_FEE));
        console.log("amountIn:", amountIn);
        console.log("minOut  :", minK613Out);

        vm.startBroadcast(pk);
        uint256 k613Out =
            treasury.buybackV3ExactInputSingle(USDC_MONAD, SWAP_ROUTER_02, amountIn, minK613Out, POOL_FEE, true);
        vm.stopBroadcast();

        console.log("Buyback V3 done. K613 out:", k613Out);
    }
}
