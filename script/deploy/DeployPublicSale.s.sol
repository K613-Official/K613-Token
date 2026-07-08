// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613PublicSale} from "src/sale/K613PublicSale.sol";

/// @title DeployPublicSale
/// @notice Deploys `K613PublicSale` on Monad mainnet (chainId 143): the fixed-price overflow public sale of
///         10,000,000 K613 at $0.01 against USDC with a $100k hard cap.
/// @dev Env interface: PRIVATE_KEY, K613_ADDRESS; optional SALE_ALLOCATION (default 10,000,000e18),
///      HARD_CAP (default 100,000e6), SALE_ADMIN (default deployer EOA; production should pass the
///      governance Safe). USDC and the sale window are hardcoded constants below.
///      Funding the sale with K613 is NOT automated - the contract refuses deposits until
///      it holds the full sale allocation, so the transfer must happen before `SALE_START` (see log summary).
contract DeployPublicSale is Script {
    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;
    uint256 private constant DEFAULT_SALE_ALLOCATION = 10_000_000e18; // 10M K613
    uint256 private constant DEFAULT_HARD_CAP = 100_000e6; // $100k USDC

    /// @notice USDC on Monad mainnet (docs/OPERATIONS_SOP.md D.3).
    address private constant USDC_MONAD = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    /// @notice Deposit window opens 2026-07-13 00:00:00 UTC.
    uint256 private constant SALE_START_TS = 1783900800;
    /// @notice Deposit window closes 2026-07-20 00:00:00 UTC (claims open after finalize()).
    uint256 private constant SALE_END_TS = 1784505600;

    /// @notice Deployed K613PublicSale address. Set by `runWith` so tests can assert without log parsing.
    address public publicSaleAddr;

    /// @notice Entrypoint for `forge script`. Reads all parameters from the environment.
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        runWith(
            USDC_MONAD,
            vm.envAddress("K613_ADDRESS"),
            vm.envOr("SALE_ALLOCATION", DEFAULT_SALE_ALLOCATION),
            vm.envOr("HARD_CAP", DEFAULT_HARD_CAP),
            SALE_START_TS,
            SALE_END_TS,
            vm.envOr("SALE_ADMIN", vm.addr(pk)),
            pk
        );
    }

    /// @notice Deploys K613PublicSale with explicit parameters. Used by `run()` and tests.
    /// @param usdc USDC address on Monad (payment token).
    /// @param k613 K613 token address (sold token).
    /// @param saleAllocation Total K613 sold (10,000,000e18 for this sale).
    /// @param hardCap Maximum USDC retained (100,000e6 for this sale).
    /// @param saleStart Deposit window opening timestamp (must be in the future).
    /// @param saleEnd Deposit window closing timestamp (exclusive).
    /// @param admin Address granted DEFAULT_ADMIN_ROLE + PAUSER_ROLE (production: governance Safe).
    /// @param deployerPrivateKey Deployer EOA key.
    function runWith(
        address usdc,
        address k613,
        uint256 saleAllocation,
        uint256 hardCap,
        uint256 saleStart,
        uint256 saleEnd,
        address admin,
        uint256 deployerPrivateKey
    ) public {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);
        K613PublicSale sale = new K613PublicSale(usdc, k613, saleAllocation, hardCap, saleStart, saleEnd, admin);
        vm.stopBroadcast();

        publicSaleAddr = address(sale);

        // Post-deploy validation against chain state.
        require(address(sale.usdc()) == usdc, "usdc mismatch");
        require(address(sale.saleToken()) == k613, "sale token mismatch");
        require(sale.saleAllocation() == saleAllocation, "allocation mismatch");
        require(sale.hardCap() == hardCap, "hard cap mismatch");
        require(sale.hasRole(sale.DEFAULT_ADMIN_ROLE(), admin), "admin role missing");
        require(sale.hasRole(sale.PAUSER_ROLE(), admin), "pauser role missing");

        _logSummary(sale, usdc, k613, admin);
    }

    function _logSummary(K613PublicSale sale, address usdc_, address k613_, address admin_) internal view {
        console.log("");
        console.log("--- K613PublicSale deployment complete (Monad mainnet 143) ---");
        console.log("  K613PublicSale:", address(sale));
        console.log("  -> USDC (payment):", usdc_);
        console.log("  -> K613 (sold):", k613_);
        console.log("  Sale allocation (wei):", sale.saleAllocation());
        console.log("  Hard cap (USDC units):", sale.hardCap());
        console.log("  Sale start (unix):", sale.saleStart());
        console.log("  Sale end (unix):", sale.saleEnd());
        console.log("  Funded:", sale.funded());
        console.log("");
        console.log("Roles:");
        console.log("  DEFAULT_ADMIN_ROLE / PAUSER_ROLE ->", admin_);
        console.log("");
        console.log("REMAINING MANUAL STEP (not automated - needs a K613 balance):");
        console.log("  K613.transfer(K613PublicSale, saleAllocation) BEFORE saleStart");
        console.log("  Without full funding, deposit() reverts SaleNotFunded.");
    }
}
