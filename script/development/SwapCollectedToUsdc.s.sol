// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV3SwapRouter} from "swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {IQuoterV2} from "swap-router-contracts/contracts/interfaces/IQuoterV2.sol";

/// @title SwapCollectedToUsdc
/// @notice Step 2 of the monthly fee cycle (SOP C.1): swaps the protocol-fee assets sitting on the
///         broadcaster's wallet into USDC via the Uniswap V3 pools from SOP D.4. Handles the six
///         assets that have V3/USDC pools (WMON, WETH, WBTC, wstETH at 0.3%; USDT0, AUSD at 0.05%).
///         shMON / sMON / gMON / wsrUSD have no V3 pools — hold them or swap manually on Kuru.
///         Each swap is quoted on-chain via QuoterV2 and protected by SLIPPAGE_BPS (default 1%).
/// @dev Env: PRIVATE_KEY (wallet holding the collected assets); optional SLIPPAGE_BPS (default 100).
///      Swaps the FULL balance of each listed asset; zero balances are skipped.
contract SwapCollectedToUsdc is Script {
    using SafeERC20 for IERC20;

    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);
    /// @notice Reverts when slippage tolerance is above the 10% hard cap.
    error SlippageBpsTooHigh(uint256 bps);

    uint256 private constant MONAD_MAINNET = 143;
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100; // 1%

    // Monad mainnet (docs/OPERATIONS_SOP.md D.1/D.3/D.5)
    address private constant SWAP_ROUTER_02 = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;
    address private constant QUOTER_V2 = 0x661E93cca42AfacB172121EF892830cA3b70F08d;
    address private constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address private constant TREASURY = 0x10aCE88f2F2c361218615F5dcA8987DD16C54282;

    struct Route {
        address token;
        uint24 fee;
        string symbol;
    }

    /// @notice The six fee assets with live V3/USDC pools (SOP D.4) and their fee tiers.
    function _routes() internal pure returns (Route[] memory r) {
        r = new Route[](6);
        r[0] = Route(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A, 3000, "WMON");
        r[1] = Route(0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242, 3000, "WETH");
        r[2] = Route(0x0555E30da8f98308EdB960aa94C0Db47230d2B9c, 3000, "WBTC");
        r[3] = Route(0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417, 3000, "wstETH");
        r[4] = Route(0xe7cd86e13AC4309349F30B3435a9d337750fC82D, 500, "USDT0");
        r[5] = Route(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a, 500, "AUSD");
    }

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", DEFAULT_SLIPPAGE_BPS);
        if (slippageBps > 1000) revert SlippageBpsTooHigh(slippageBps);

        address wallet = vm.addr(pk);
        uint256 usdcBefore = IERC20(USDC).balanceOf(wallet);
        Route[] memory routes = _routes();

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < routes.length; i++) {
            Route memory r = routes[i];
            uint256 bal = IERC20(r.token).balanceOf(wallet);
            if (bal == 0) {
                console.log("skip (zero):", r.symbol);
                continue;
            }

            (uint256 quoted,,,) = IQuoterV2(QUOTER_V2)
                .quoteExactInputSingle(
                    IQuoterV2.QuoteExactInputSingleParams({
                        tokenIn: r.token, tokenOut: USDC, amountIn: bal, fee: r.fee, sqrtPriceLimitX96: 0
                    })
                );
            if (quoted == 0) {
                console.log("skip (no quote):", r.symbol);
                continue;
            }
            uint256 minOut = quoted - (quoted * slippageBps) / 10_000;

            IERC20(r.token).forceApprove(SWAP_ROUTER_02, bal);
            uint256 out = IV3SwapRouter(SWAP_ROUTER_02)
                .exactInputSingle(
                    IV3SwapRouter.ExactInputSingleParams({
                        tokenIn: r.token,
                        tokenOut: USDC,
                        fee: r.fee,
                        recipient: wallet,
                        amountIn: bal,
                        amountOutMinimum: minOut,
                        sqrtPriceLimitX96: 0
                    })
                );
            IERC20(r.token).forceApprove(SWAP_ROUTER_02, 0);
            console.log("swapped", r.symbol, bal, out);
        }

        // Forward exactly the freshly swapped USDC to the Treasury — the wallet's pre-existing
        // USDC balance is untouched. Override with SEND_TO_TREASURY=false to keep it on the wallet.
        uint256 gained = IERC20(USDC).balanceOf(wallet) - usdcBefore;
        bool sendToTreasury = vm.envOr("SEND_TO_TREASURY", true);
        if (sendToTreasury && gained > 0) {
            IERC20(USDC).safeTransfer(TREASURY, gained);
            console.log("USDC sent to Treasury:", gained);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("USDC gained from swaps:", gained);
        console.log("NOT swapped (no V3 pools): shMON / sMON / gMON / wsrUSD - hold or swap on Kuru manually.");
        console.log("Next step: run TreasuryBuybackV3.s.sol");
    }
}
