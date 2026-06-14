// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {K613} from "../src/token/K613.sol";
import {K613PublicSale} from "../src/sale/K613PublicSale.sol";
import {DeployPublicSale} from "../script/deploy/DeployPublicSale.s.sol";

/// @notice Minimal 6-decimal USDC stand-in for the deploy-script test.
contract DeployMockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployPublicSaleTest is Test {
    DeployPublicSale private script;
    K613 private k613;
    DeployMockUSDC private usdc;

    uint256 private constant DEPLOYER_PK = 0xA11CE;
    uint256 private constant MONAD_MAINNET = 143;
    uint256 private constant SALE_ALLOCATION = 10_000_000e18;
    uint256 private constant HARD_CAP = 100_000e6;

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address private deployer;
    address private admin = address(0x5AFE);
    address private alice = address(0xA11CE);

    uint256 private saleStart;
    uint256 private saleEnd;

    function setUp() public {
        vm.warp(1_750_000_000);
        saleStart = block.timestamp + 1 days;
        saleEnd = saleStart + 3 days;

        deployer = vm.addr(DEPLOYER_PK);
        vm.startPrank(deployer);
        k613 = new K613(deployer); // deployer is K613 minter
        usdc = new DeployMockUSDC();
        vm.stopPrank();
        script = new DeployPublicSale();
    }

    function _run() private {
        script.runWith(address(usdc), address(k613), SALE_ALLOCATION, HARD_CAP, saleStart, saleEnd, admin, DEPLOYER_PK);
    }

    /// @notice On Monad mainnet: deploys the sale with the exact parameters, unfunded.
    function testRunWith_DeploysAndWires() public {
        vm.chainId(MONAD_MAINNET);
        _run();

        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());
        assertTrue(script.publicSaleAddr() != address(0), "sale deployed");
        assertEq(address(sale.usdc()), address(usdc), "usdc wired");
        assertEq(address(sale.saleToken()), address(k613), "k613 wired");
        assertEq(sale.saleAllocation(), SALE_ALLOCATION, "allocation");
        assertEq(sale.hardCap(), HARD_CAP, "hard cap");
        assertEq(sale.saleStart(), saleStart, "start");
        assertEq(sale.saleEnd(), saleEnd, "end");
        assertFalse(sale.funded(), "not funded by the script");
    }

    /// @notice Admin param (not the deployer or the script) holds DEFAULT_ADMIN_ROLE + PAUSER_ROLE.
    function testRunWith_AdminRoles() public {
        vm.chainId(MONAD_MAINNET);
        _run();

        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());
        assertTrue(sale.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin role -> admin");
        assertTrue(sale.hasRole(PAUSER_ROLE, admin), "pauser role -> admin");
        assertFalse(sale.hasRole(DEFAULT_ADMIN_ROLE, deployer), "deployer has no admin role");
        assertFalse(sale.hasRole(DEFAULT_ADMIN_ROLE, address(script)), "script has no admin role");
    }

    /// @notice On any non-Monad chain the script reverts WrongNetwork.
    function testRunWith_RevertsOnWrongNetwork() public {
        vm.chainId(421614); // Arbitrum Sepolia
        vm.expectRevert(abi.encodeWithSelector(DeployPublicSale.WrongNetwork.selector, uint256(421614)));
        _run();
    }

    /// @notice A sale window starting in the past propagates the contract's InvalidSaleWindow revert.
    function testRunWith_RevertsOnInvalidWindow() public {
        vm.chainId(MONAD_MAINNET);
        vm.expectRevert(K613PublicSale.InvalidSaleWindow.selector);
        script.runWith(
            address(usdc), address(k613), SALE_ALLOCATION, HARD_CAP, block.timestamp, saleEnd, admin, DEPLOYER_PK
        );
    }

    /// @notice After the manual K613 funding step the deployed sale is fully operational end-to-end.
    function testRunWith_EndToEndAfterManualFunding() public {
        vm.chainId(MONAD_MAINNET);
        _run();
        K613PublicSale sale = K613PublicSale(script.publicSaleAddr());

        // Manual step from the log summary: fund the sale with the full allocation.
        vm.prank(deployer);
        k613.mint(address(sale), SALE_ALLOCATION);
        assertTrue(sale.funded(), "funded");

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
