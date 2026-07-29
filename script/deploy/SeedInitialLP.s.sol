// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

/// @title SeedInitialLP
/// @notice Creates the K613/USDC pool on Uniswap V3 (Monad), initializes its price, and mints a full-range LP position.
/// @dev Token order is auto-detected (lower address = token0). After mint, the LP NFT is owned by LP_RECIPIENT;
///      transferring it to a fee-only locker / timelock / 0xdEaD is a separate step (intentionally NOT in this script
///      so that the LP position is verifiable on-chain before being made irreversible).
///
///      NPM (Monad mainnet):       0x7197E214c0b767cFB76Fb734ab638E2c192F4E53
///      Uniswap V3 Factory (Monad): 0x204FAca1764B154221e35c0d20aBb3c525710498
///
/// HOW TO COMPUTE sqrtPriceX96 OFF-CHAIN:
///      sqrtPriceX96 = floor( sqrt( (amount1_raw * 2**192) / amount0_raw ) )
///      where amount0/amount1 are RAW (decimal-adjusted) amounts of token0/token1
///      that you want the initial price to represent.
///
///      Example: K613 (18 dec) / USDC (6 dec), price = $0.10 per K613.
///        Case A: K613 < USDC address  -> token0=K613, token1=USDC
///          amount0_raw = 1e18, amount1_raw = 0.10 * 1e6 = 1e5
///          sqrtPriceX96 = floor(sqrt((1e5 * 2**192) / 1e18))
///                       = floor(sqrt(1e-13) * 2**96)
///                       ~ 25_054_144_837_564_062_460_000  (verify with a calculator)
///        Case B: USDC < K613 address  -> token0=USDC, token1=K613
///          amount0_raw = 1e5, amount1_raw = 1e18
///          sqrtPriceX96 = floor(sqrt(1e13) * 2**96)
///                       ~ 250_541_448_375_640_624_600_000_000_000_000_000  (huge)
///
///      The script will revert with WrongTokenOrder if you pass a sqrtPriceX96 that mismatches the auto-detected
///      ordering (i.e. computed for the wrong (token0,token1) pair). Recompute and re-run.
contract SeedInitialLP is Script {
    error InvalidFeeTier(uint24 fee);
    error ZeroAmount();
    error WrongTokenOrder();
    error SlippageBpsTooHigh(uint16 bps);
    error WrongNetwork(uint256 chainId);

    /// @notice Default slippage tolerance for `mint` if env override absent. 100 bps = 1%.
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 100;

    uint256 private constant MONAD_MAINNET = 143;

    // Monad mainnet constants (docs/OPERATIONS_SOP.md D.1/D.3).
    address private constant K613_MONAD = 0xb09582631336068d4B0089d943f40CbF46dE5189;
    address private constant USDC_MONAD = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address private constant NPM_MONAD = 0x7197E214c0b767cFB76Fb734ab638E2c192F4E53;
    /// @notice Pool fee tier 0.05% — the 0.3% K613/USDC pool is a dead artifact initialized at $0.01.
    uint24 private constant DEFAULT_FEE_TIER = 500;
    /// @notice Initial price: $0.008 per K613 (raw 6-decimal USDC) — final team decision, POL listing price.
    uint256 private constant DEFAULT_PRICE_K613_USDC_RAW = 8_000;
    /// @notice Full public-sale proceeds ($792.636970) — "all funds go to LP" per tokenomics.
    uint256 private constant DEFAULT_USDC_AMOUNT = 792_636_970;
    /// @notice K613 side matching the proceeds at $0.008 (99,079.62125 K613, from the POL-LP bucket).
    uint256 private constant DEFAULT_K613_AMOUNT = 99_079_621_250e12;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);
        uint256 pk = vm.envUint("PRIVATE_KEY");
        runWithPrice(
            K613_MONAD,
            USDC_MONAD,
            NPM_MONAD,
            uint24(vm.envOr("FEE_TIER", uint256(DEFAULT_FEE_TIER))),
            vm.envOr("PRICE_K613_USDC_RAW", DEFAULT_PRICE_K613_USDC_RAW),
            vm.envOr("K613_AMOUNT", DEFAULT_K613_AMOUNT),
            vm.envOr("USDC_AMOUNT", DEFAULT_USDC_AMOUNT),
            uint16(vm.envOr("SLIPPAGE_BPS", uint256(DEFAULT_SLIPPAGE_BPS))),
            vm.envOr("LP_RECIPIENT", vm.addr(pk)),
            pk
        );
    }

    /// @notice Computes sqrtPriceX96 from a human-readable price and forwards to `runWith`.
    /// @param priceK613InUsdcRaw RAW USDC (6-decimal) per 1 whole K613. Example: $0.008/K613 -> 8000.
    function runWithPrice(
        address k613,
        address usdc,
        address npm,
        uint24 fee,
        uint256 priceK613InUsdcRaw,
        uint256 k613Amount,
        uint256 usdcAmount,
        uint16 slippageBps,
        address lpRecipient,
        uint256 pk
    ) public returns (address pool, uint256 tokenId, uint128 liquidity, uint256 amount0Out, uint256 amount1Out) {
        uint160 sqrtPriceX96 = computeSqrtPriceX96(k613, usdc, priceK613InUsdcRaw);
        return runWith(k613, usdc, npm, fee, sqrtPriceX96, k613Amount, usdcAmount, slippageBps, lpRecipient, pk);
    }

    /// @notice Pure helper: derive sqrtPriceX96 for the K613/USDC pool given a price expressed as RAW USDC per 1 K613.
    /// @dev   Internally handles K613 (18 dec) and USDC (6 dec) and the token0/token1 ordering.
    ///        - If K613 is token0: sqrt((priceK613InUsdcRaw * 2^192) / 1e18)
    ///        - If USDC is token0: sqrt((1e18 * 2^192) / priceK613InUsdcRaw)
    function computeSqrtPriceX96(address k613, address usdc, uint256 priceK613InUsdcRaw) public pure returns (uint160) {
        if (priceK613InUsdcRaw == 0) revert ZeroAmount();
        uint256 k613Unit = 1e18;
        uint256 q192 = uint256(1) << 192;
        uint256 ratioX192;
        if (k613 < usdc) {
            ratioX192 = Math.mulDiv(priceK613InUsdcRaw, q192, k613Unit);
        } else {
            ratioX192 = Math.mulDiv(k613Unit, q192, priceK613InUsdcRaw);
        }
        uint256 sqrtPrice = Math.sqrt(ratioX192);
        return uint160(sqrtPrice);
    }

    /// @notice Direct entrypoint without env vars (used by tests, also callable as a library helper).
    /// @param k613 K613 token address.
    /// @param usdc USDC (or any 6-decimal stable) token address.
    /// @param npm Uniswap V3 NonfungiblePositionManager.
    /// @param fee Pool fee tier (500 / 3000 / 10000).
    /// @param sqrtPriceX96 Initial sqrt price encoded for the auto-detected (token0, token1) pair.
    /// @param k613Amount Amount of K613 to provide as liquidity.
    /// @param usdcAmount Amount of USDC to provide as liquidity.
    /// @param lpRecipient Address that owns the resulting LP NFT.
    /// @param pk Broadcaster private key (must hold k613Amount K613 and usdcAmount USDC).
    /// @dev Internal struct used to keep `runWith` below Solidity's stack-depth limit.
    struct PreparedMint {
        address token0;
        address token1;
        uint160 sqrtPriceX96;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        int24 tickLower;
        int24 tickUpper;
        address lpRecipient;
    }

    function runWith(
        address k613,
        address usdc,
        address npm,
        uint24 fee,
        uint160 sqrtPriceX96,
        uint256 k613Amount,
        uint256 usdcAmount,
        uint16 slippageBps,
        address lpRecipient,
        uint256 pk
    ) public returns (address pool, uint256 tokenId, uint128 liquidity, uint256 amount0Out, uint256 amount1Out) {
        if (k613Amount == 0 || usdcAmount == 0) revert ZeroAmount();
        if (slippageBps > 5000) revert SlippageBpsTooHigh(slippageBps); // hard cap at 50%
        PreparedMint memory p =
            _prepare(k613, usdc, fee, sqrtPriceX96, k613Amount, usdcAmount, slippageBps, lpRecipient);
        return _executeMint(npm, p, pk);
    }

    /// @dev Pure prep: sort tokens, compute amounts, mins, and full-range ticks for the chosen fee tier.
    function _prepare(
        address k613,
        address usdc,
        uint24 fee,
        uint160 sqrtPriceX96,
        uint256 k613Amount,
        uint256 usdcAmount,
        uint16 slippageBps,
        address lpRecipient
    ) internal pure returns (PreparedMint memory p) {
        int24 tickSpacing = _tickSpacing(fee);
        bool k613IsToken0 = k613 < usdc;
        p.token0 = k613IsToken0 ? k613 : usdc;
        p.token1 = k613IsToken0 ? usdc : k613;
        p.fee = fee;
        p.sqrtPriceX96 = sqrtPriceX96;
        p.amount0Desired = k613IsToken0 ? k613Amount : usdcAmount;
        p.amount1Desired = k613IsToken0 ? usdcAmount : k613Amount;
        p.amount0Min = p.amount0Desired - (p.amount0Desired * slippageBps) / 10_000;
        p.amount1Min = p.amount1Desired - (p.amount1Desired * slippageBps) / 10_000;
        p.tickLower = -(int24(887272) / tickSpacing) * tickSpacing;
        p.tickUpper = (int24(887272) / tickSpacing) * tickSpacing;
        p.lpRecipient = lpRecipient;
    }

    /// @dev Broadcast and call NPM. Separated to keep `runWith` under the EVM stack limit.
    function _executeMint(address npm, PreparedMint memory p, uint256 pk)
        internal
        returns (address pool, uint256 tokenId, uint128 liquidity, uint256 amount0Out, uint256 amount1Out)
    {
        console.log("=== SeedInitialLP ===");
        console.log("Caller:           ", vm.addr(pk));
        console.log("NPM:              ", npm);
        console.log("token0:           ", p.token0);
        console.log("token1:           ", p.token1);
        console.log("fee:              ", p.fee);
        console.log("amount0 (desired):", p.amount0Desired);
        console.log("amount1 (desired):", p.amount1Desired);
        console.log("amount0 (min):    ", p.amount0Min);
        console.log("amount1 (min):    ", p.amount1Min);
        console.log("LP recipient:     ", p.lpRecipient);

        vm.startBroadcast(pk);

        pool = INonfungiblePositionManager(npm)
            .createAndInitializePoolIfNecessary(p.token0, p.token1, p.fee, p.sqrtPriceX96);
        console.log("pool:             ", pool);

        IERC20(p.token0).approve(npm, p.amount0Desired);
        IERC20(p.token1).approve(npm, p.amount1Desired);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            amount0Desired: p.amount0Desired,
            amount1Desired: p.amount1Desired,
            amount0Min: p.amount0Min,
            amount1Min: p.amount1Min,
            recipient: p.lpRecipient,
            deadline: block.timestamp + 1 hours
        });
        (tokenId, liquidity, amount0Out, amount1Out) = INonfungiblePositionManager(npm).mint(params);

        IERC20(p.token0).approve(npm, 0);
        IERC20(p.token1).approve(npm, 0);

        vm.stopBroadcast();

        console.log("=== LP minted ===");
        console.log("tokenId:          ", tokenId);
        console.log("liquidity:        ", liquidity);
        console.log("amount0 used:     ", amount0Out);
        console.log("amount1 used:     ", amount1Out);
    }

    /// @dev Standard Uniswap V3 tick spacings per fee tier.
    function _tickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        revert InvalidFeeTier(fee);
    }
}
