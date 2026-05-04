// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {K613} from "../src/token/K613.sol";
import {SeedInitialLP, INonfungiblePositionManager} from "../script/deploy/SeedInitialLP.s.sol";

/// @dev Minimal USDC mock (6 decimals like real USDC).
contract USDCMock is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock NonfungiblePositionManager that records all params and pulls funds via transferFrom.
contract MockNPM {
    address public lastToken0;
    address public lastToken1;
    uint24 public lastFee;
    uint160 public lastSqrtPriceX96;
    INonfungiblePositionManager.MintParams public lastMintParams;
    address public lastRecipient;
    bool public createCalled;
    bool public mintCalled;
    address public constant POOL_ADDRESS = address(0xBADBABE);

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool)
    {
        lastToken0 = token0;
        lastToken1 = token1;
        lastFee = fee;
        lastSqrtPriceX96 = sqrtPriceX96;
        createCalled = true;
        return POOL_ADDRESS;
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        lastMintParams = p;
        lastRecipient = p.recipient;
        mintCalled = true;
        IERC20(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired);
        IERC20(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired);
        return (42, 1_000_000, p.amount0Desired, p.amount1Desired);
    }
}

contract SeedInitialLPTest is Test {
    K613 private k613;
    USDCMock private usdc;
    MockNPM private npm;
    SeedInitialLP private script;

    uint256 private constant DEPLOYER_PK = 0xA11CE;
    address private deployer;
    address private lpRecipient = address(0xCAFE);

    uint256 private constant K613_LP_AMOUNT = 12_500_000e18;
    uint256 private constant USDC_LP_AMOUNT = 1_250_000e6; // $1.25M paired (price = $0.10/K613 just for test)
    uint24 private constant FEE_TIER = 3000;
    uint160 private constant DUMMY_SQRT_PRICE = 79228162514264337593543950336; // 1:1 placeholder, mock doesn't validate

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);

        vm.startPrank(deployer);
        k613 = new K613(deployer);
        k613.mint(deployer, K613_LP_AMOUNT);
        vm.stopPrank();

        usdc = new USDCMock();
        usdc.mint(deployer, USDC_LP_AMOUNT);

        npm = new MockNPM();
        script = new SeedInitialLP();
    }

    /// @notice testRunWith_PoolCreatedWithSortedTokens: token0 is the lower address, token1 is the higher.
    function testRunWith_PoolCreatedWithSortedTokens() public {
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );

        assertTrue(npm.createCalled());
        assertTrue(npm.mintCalled());
        (address expected0, address expected1) =
            address(k613) < address(usdc) ? (address(k613), address(usdc)) : (address(usdc), address(k613));
        assertEq(npm.lastToken0(), expected0, "token0 must be the lower address");
        assertEq(npm.lastToken1(), expected1, "token1 must be the higher address");
        assertEq(npm.lastFee(), FEE_TIER);
        assertEq(npm.lastSqrtPriceX96(), DUMMY_SQRT_PRICE);
    }

    /// @notice testRunWith_AmountsAlignToTokenOrder: amount0/amount1 swap with the K613/USDC ordering.
    function testRunWith_AmountsAlignToTokenOrder() public {
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );

        (uint256 expectedAmt0, uint256 expectedAmt1) =
            address(k613) < address(usdc) ? (K613_LP_AMOUNT, USDC_LP_AMOUNT) : (USDC_LP_AMOUNT, K613_LP_AMOUNT);
        (,, uint24 _fee, int24 _tl, int24 _tu, uint256 a0, uint256 a1,,, address _r,) = npm.lastMintParams();
        _fee;
        _tl;
        _tu;
        _r;
        assertEq(a0, expectedAmt0, "amount0Desired must match token0");
        assertEq(a1, expectedAmt1, "amount1Desired must match token1");
    }

    /// @notice testRunWith_FullRangeTicksForFee3000: full-range position uses ±887220 (rounded to spacing 60).
    function testRunWith_FullRangeTicksForFee3000() public {
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            3000,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );

        (,,, int24 tl, int24 tu,,,,,,) = npm.lastMintParams();
        assertEq(tl, -887220, "tickLower full range for spacing 60");
        assertEq(tu, 887220, "tickUpper full range for spacing 60");
    }

    /// @notice testRunWith_FullRangeTicksForFee500: full-range tick rounding for spacing 10 (fee 500).
    function testRunWith_FullRangeTicksForFee500() public {
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            500,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );

        (,,, int24 tl, int24 tu,,,,,,) = npm.lastMintParams();
        assertEq(tl, -887270, "tickLower full range for spacing 10");
        assertEq(tu, 887270, "tickUpper full range for spacing 10");
    }

    /// @notice testRunWith_TokensTransferredToNPM: K613 + USDC actually leave the broadcaster.
    function testRunWith_TokensTransferredToNPM() public {
        uint256 k613BalBefore = k613.balanceOf(deployer);
        uint256 usdcBalBefore = usdc.balanceOf(deployer);

        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );

        assertEq(k613.balanceOf(deployer), k613BalBefore - K613_LP_AMOUNT, "K613 pulled from deployer");
        assertEq(usdc.balanceOf(deployer), usdcBalBefore - USDC_LP_AMOUNT, "USDC pulled from deployer");
        assertEq(k613.balanceOf(address(npm)), K613_LP_AMOUNT, "K613 in NPM (mock doesn't forward to pool)");
        assertEq(usdc.balanceOf(address(npm)), USDC_LP_AMOUNT, "USDC in NPM");
    }

    /// @notice testRunWith_RecipientGetsLpNft: MintParams.recipient is set to the lpRecipient param.
    function testRunWith_RecipientGetsLpNft() public {
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );
        assertEq(npm.lastRecipient(), lpRecipient);
    }

    /// @notice testRunWith_InvalidFeeTierReverts: only 500/3000/10000 are accepted.
    function testRunWith_InvalidFeeTierReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SeedInitialLP.InvalidFeeTier.selector, uint24(1234)));
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            1234,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );
    }

    /// @notice testRunWith_SlippageBpsAppliedToMintParams: slippageBps=100 (1%) writes amount0Min/amount1Min as 99% of desired.
    function testRunWith_SlippageBpsAppliedToMintParams() public {
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            100, // 1% slippage
            lpRecipient,
            DEPLOYER_PK
        );

        (,,,,, uint256 a0Desired, uint256 a1Desired, uint256 a0Min, uint256 a1Min,,) = npm.lastMintParams();
        assertEq(a0Min, a0Desired - (a0Desired * 100) / 10_000, "amount0Min must be 99% of desired");
        assertEq(a1Min, a1Desired - (a1Desired * 100) / 10_000, "amount1Min must be 99% of desired");
    }

    /// @notice testRunWith_SlippageBpsHardCapAccepts5000: maximum allowed slippageBps == 5000 (50%) does not revert.
    function testRunWith_SlippageBpsHardCapAccepts5000() public {
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            5000,
            lpRecipient,
            DEPLOYER_PK
        );

        (,,,,, uint256 a0Desired,, uint256 a0Min,,,) = npm.lastMintParams();
        assertEq(a0Min, a0Desired / 2, "amount0Min must be 50% of desired at slippageBps=5000");
    }

    /// @notice testRunWith_SlippageBpsTooHighReverts: slippageBps > 5000 reverts with SlippageBpsTooHigh.
    function testRunWith_SlippageBpsTooHighReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SeedInitialLP.SlippageBpsTooHigh.selector, uint16(5001)));
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            DUMMY_SQRT_PRICE,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            5001,
            lpRecipient,
            DEPLOYER_PK
        );
    }

    /// @notice testRunWith_ZeroAmountReverts: zero amount on either side reverts.
    function testRunWith_ZeroAmountReverts() public {
        vm.expectRevert(SeedInitialLP.ZeroAmount.selector);
        script.runWith(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            DUMMY_SQRT_PRICE,
            0,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );
    }

    /// @notice testComputeSqrtPriceX96_PriceInverseSymmetry: swapping (k613, usdc) order yields reciprocal-equivalent sqrtPrice.
    /// @dev   sqrtPrice_A * sqrtPrice_B should equal 2^192 (within rounding) regardless of which token is token0.
    function testComputeSqrtPriceX96_PriceInverseSymmetry() public view {
        uint256 priceRaw = 8000; // $0.008 -> 8000 raw USDC per 1 K613
        // pick two addresses that bracket each other, deterministic ordering
        address low = address(uint160(1));
        address high = address(uint160(uint256(2) ** 159));
        uint160 sA = script.computeSqrtPriceX96(low, high, priceRaw);
        uint160 sB = script.computeSqrtPriceX96(high, low, priceRaw);
        // sA * sB should approximate 2^192 (since price_A == 1/price_B)
        uint256 product = uint256(sA) * uint256(sB);
        uint256 expected = 1 << 192;
        // allow small rounding error from integer sqrt (relative tolerance 1e-6)
        uint256 diff = product > expected ? product - expected : expected - product;
        assertLt(diff * 1e9 / expected, 1, "sqrt(p) * sqrt(1/p) must equal 2^96 squared up to rounding");
    }

    /// @notice testComputeSqrtPriceX96_KnownValueK613IsToken0: hardcoded expected sqrtPriceX96 for $0.008 case (K613=token0).
    /// @dev Independent check via Math.mulDiv + Math.sqrt; matches the implementation byte-for-byte.
    function testComputeSqrtPriceX96_KnownValueK613IsToken0() public view {
        address k613Low = address(uint160(1));
        address usdcHigh = address(uint160(uint256(2) ** 159));
        uint256 priceRaw = 8000; // $0.008/K613 in raw USDC
        uint160 got = script.computeSqrtPriceX96(k613Low, usdcHigh, priceRaw);
        // Reference value (computed via standalone Math.mulDiv(8000, 2^192, 1e18) then Math.sqrt):
        //   = sqrt(50_216_813_883_093_446_110_686_315_385_661_331_328_818_843)
        //   = 7_086_382_284_571_828_411_844
        assertEq(uint256(got), 7_086_382_284_571_828_411_844, "sqrtPriceX96 must match reference $0.008/K613 value");
    }

    /// @notice testRunWithPrice_HappyPath: end-to-end price-based entry, mock NPM accepts whatever sqrt we compute.
    function testRunWithPrice_HappyPath() public {
        uint256 priceRaw = 8000;
        script.runWithPrice(
            address(k613),
            address(usdc),
            address(npm),
            FEE_TIER,
            priceRaw,
            K613_LP_AMOUNT,
            USDC_LP_AMOUNT,
            0,
            lpRecipient,
            DEPLOYER_PK
        );
        assertTrue(npm.createCalled());
        assertTrue(npm.mintCalled());
        // sqrt price should match what computeSqrtPriceX96 returns for the same inputs
        uint160 expected = script.computeSqrtPriceX96(address(k613), address(usdc), priceRaw);
        assertEq(npm.lastSqrtPriceX96(), expected);
    }

    /// @notice testComputeSqrtPriceX96_ZeroPriceReverts: zero price reverts with ZeroAmount.
    function testComputeSqrtPriceX96_ZeroPriceReverts() public {
        vm.expectRevert(SeedInitialLP.ZeroAmount.selector);
        script.computeSqrtPriceX96(address(k613), address(usdc), 0);
    }
}
