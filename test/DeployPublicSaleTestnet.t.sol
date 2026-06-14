// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {K613} from "../src/token/K613.sol";
import {K613S1} from "../src/token/K613S1.sol";
import {K613PublicSale} from "../src/sale/K613PublicSale.sol";
import {DeployPublicSaleTestnet} from "../script/deploy/DeployPublicSaleTestnet.s.sol";

/// @notice Minimal 6-decimal USDC stand-in for the testnet deploy-script test.
contract TestnetMockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployPublicSaleTestnetTest is Test {
    DeployPublicSaleTestnet private script;
    K613 private k613;
    TestnetMockUSDC private usdc;

    uint256 private constant DEPLOYER_PK = 0xA11CE;
    uint256 private constant ARBITRUM_SEPOLIA = 421614;
    uint256 private constant SALE_ALLOCATION = 10_000_000e18;
    uint256 private constant HARD_CAP = 100_000e6;

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address private deployer;
    address private alice = address(0xA11CE7);

    uint256 private saleStart;
    uint256 private saleEnd;

    function setUp() public {
        vm.warp(1_750_000_000);
        saleStart = block.timestamp + 10 minutes;
        saleEnd = saleStart + 7 days;

        deployer = vm.addr(DEPLOYER_PK);
        vm.startPrank(deployer);
        k613 = new K613(deployer); // deployer holds MINTER_ROLE
        usdc = new TestnetMockUSDC();
        vm.stopPrank();
        script = new DeployPublicSaleTestnet();
    }

    function _run() private {
        script.runWith(address(usdc), address(k613), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, DEPLOYER_PK);
    }

    /// @notice On Arbitrum Sepolia: deploys, wires params, makes the deployer admin, and auto-funds via mint.
    function testRunWith_DeploysWiresAndAutoFundsViaMint() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        _run();

        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());
        assertTrue(script.publicSaleAddr() != address(0), "sale deployed");
        assertEq(address(sale.usdc()), address(usdc), "usdc wired");
        assertEq(address(sale.saleToken()), address(k613), "k613 wired");
        assertEq(sale.saleStart(), saleStart, "start");
        assertEq(sale.saleEnd(), saleEnd, "end");
        assertTrue(sale.hasRole(DEFAULT_ADMIN_ROLE, deployer), "admin -> deployer");
        assertTrue(sale.hasRole(PAUSER_ROLE, deployer), "pauser -> deployer");
        assertTrue(sale.funded(), "auto-funded by mint");
        assertEq(k613.balanceOf(address(sale)), SALE_ALLOCATION, "exact allocation minted");
    }

    /// @notice When the deployer is no longer the minter, funding falls back to a balance transfer.
    function testRunWith_AutoFundsViaTransferWhenNotMinter() public {
        vm.startPrank(deployer);
        k613.mint(deployer, SALE_ALLOCATION); // pre-mint to own balance
        k613.setMinter(address(0xDEAD)); // revoke own MINTER_ROLE
        vm.stopPrank();

        vm.chainId(ARBITRUM_SEPOLIA);
        _run();

        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());
        assertTrue(sale.funded(), "auto-funded by transfer");
        assertEq(k613.balanceOf(deployer), 0, "deployer balance spent");
    }

    /// @notice When the deployer can neither mint nor transfer, the sale deploys unfunded (manual step).
    function testRunWith_DeploysUnfundedWhenDeployerCannotFund() public {
        vm.prank(deployer);
        k613.setMinter(address(0xDEAD)); // not minter, zero balance

        vm.chainId(ARBITRUM_SEPOLIA);
        _run();

        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());
        assertFalse(sale.funded(), "left unfunded");
    }

    /// @notice Minting is skipped when the allocation would exceed the K613 supply cap; falls back correctly.
    function testRunWith_RespectsSupplyCap() public {
        vm.startPrank(deployer);
        k613.mint(deployer, k613.MAX_SUPPLY() - 1e18); // cap nearly exhausted, balance covers allocation
        vm.stopPrank();

        vm.chainId(ARBITRUM_SEPOLIA);
        _run();

        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());
        assertTrue(sale.funded(), "funded via transfer fallback");
        assertEq(k613.totalSupply(), k613.MAX_SUPPLY() - 1e18, "no mint above cap");
    }

    /// @notice A legacy sale token without a MAX_SUPPLY() getter (like the April testnet K613) still
    ///         auto-funds via mint: the cap probe treats the missing getter as "no cap".
    function testRunWith_AutoFundsViaMintWhenTokenHasNoCap() public {
        vm.startPrank(deployer);
        K613S1 legacy = new K613S1(); // mintable via MINTER_ROLE, has no MAX_SUPPLY()
        legacy.grantRole(legacy.MINTER_ROLE(), deployer);
        vm.stopPrank();

        vm.chainId(ARBITRUM_SEPOLIA);
        script.runWith(address(usdc), address(legacy), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, DEPLOYER_PK);

        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());
        assertTrue(sale.funded(), "auto-funded despite missing MAX_SUPPLY getter");
        assertEq(legacy.balanceOf(address(sale)), SALE_ALLOCATION, "exact allocation minted");
    }

    /// @notice On any non-Arbitrum-Sepolia chain the script reverts WrongNetwork.
    function testRunWith_RevertsOnWrongNetwork() public {
        vm.chainId(143); // Monad mainnet
        vm.expectRevert(abi.encodeWithSelector(DeployPublicSaleTestnet.WrongNetwork.selector, uint256(143)));
        _run();
    }

    /// @notice The freshly deployed and auto-funded sale is operational end-to-end.
    function testRunWith_EndToEnd() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        _run();
        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());

        usdc.mint(alice, 30_000e6);
        vm.warp(saleStart);
        vm.startPrank(alice);
        usdc.approve(address(sale), 30_000e6);
        sale.deposit(30_000e6);
        vm.stopPrank();

        vm.warp(saleEnd);
        sale.finalize();
        vm.prank(alice);
        sale.claimTokens();
        assertEq(k613.balanceOf(alice), 3_000_000e18, "$30k buys exactly 3M K613 at $0.01");
    }
}
