// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613} from "src/token/K613.sol";
import {K613PublicSale} from "src/sale/K613PublicSale.sol";

/// @title DeployPublicSaleTestnet
/// @notice Testnet-only deploy of `K613PublicSale` on Arbitrum Sepolia (chainId 421614), wired to the
///         testnet K613 stand. Payment token defaults to Circle's canonical Arbitrum Sepolia USDC
///         (the same token the testnet lending stand uses), so QA wallets can top up from the Circle faucet.
/// @dev Env interface: PRIVATE_KEY, K613_ADDRESS; optional USDC_ADDRESS (default Circle USDC),
///      SALE_ALLOCATION (default 10,000,000e18), HARD_CAP (default 100,000e6), SALE_START (default
///      now + 10 minutes), SALE_END (default start + 7 days). Admin is the deployer EOA (no Safe on testnet).
///      Unlike the mainnet script, this one also attempts to FUND the sale in the same run: it mints the
///      allocation if the deployer still holds `K613.MINTER_ROLE` and the supply cap allows, otherwise
///      transfers from the deployer's balance, otherwise leaves funding as a logged manual step.
contract DeployPublicSaleTestnet is Script {
    /// @notice Reverts if invoked on a chain other than Arbitrum Sepolia.
    error WrongNetwork(uint256 chainId);

    uint256 private constant ARBITRUM_SEPOLIA = 421614;
    /// @notice Circle's canonical USDC on Arbitrum Sepolia (6 decimals, faucet-backed).
    address private constant ARB_SEPOLIA_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    uint256 private constant DEFAULT_SALE_ALLOCATION = 10_000_000e18; // 10M K613
    uint256 private constant DEFAULT_HARD_CAP = 100_000e6; // $100k USDC

    /// @notice Deployed K613PublicSale address. Set by `runWith` so tests can assert without log parsing.
    address public publicSaleAddr;

    /// @notice Entrypoint for `forge script`. Reads all parameters from the environment.
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 saleStart = vm.envOr("SALE_START", block.timestamp + 10 minutes);
        runWith(
            vm.envOr("USDC_ADDRESS", ARB_SEPOLIA_USDC),
            vm.envAddress("K613_ADDRESS"),
            vm.envOr("SALE_ALLOCATION", DEFAULT_SALE_ALLOCATION),
            vm.envOr("HARD_CAP", DEFAULT_HARD_CAP),
            saleStart,
            vm.envOr("SALE_END", saleStart + 7 days),
            pk
        );
    }

    /// @notice Deploys K613PublicSale with explicit parameters and tries to fund it. Used by `run()` and tests.
    /// @param usdc Payment token (Circle USDC on Arbitrum Sepolia unless overridden).
    /// @param k613 Testnet K613 token address (sold token).
    /// @param saleAllocation Total K613 sold.
    /// @param hardCap Maximum USDC retained.
    /// @param saleStart Deposit window opening timestamp (must be in the future).
    /// @param saleEnd Deposit window closing timestamp (exclusive).
    /// @param deployerPrivateKey Deployer EOA key; becomes admin and pauser (no Safe handover on testnet).
    function runWith(
        address usdc,
        address k613,
        uint256 saleAllocation,
        uint256 hardCap,
        uint256 saleStart,
        uint256 saleEnd,
        uint256 deployerPrivateKey
    ) public {
        if (block.chainid != ARBITRUM_SEPOLIA) revert WrongNetwork(block.chainid);

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        K613 token = K613(k613);

        // Decide the funding path BEFORE broadcasting. Older testnet K613 deployments predate the
        // ERC20Capped upgrade and have no MAX_SUPPLY() getter, so the cap is probed via staticcall
        // and treated as absent when the getter is missing.
        bool canMint = token.hasRole(token.MINTER_ROLE(), deployer);
        if (canMint) {
            (bool hasCap, bytes memory capData) = k613.staticcall(abi.encodeWithSignature("MAX_SUPPLY()"));
            if (hasCap && capData.length == 32) {
                canMint = token.totalSupply() + saleAllocation <= abi.decode(capData, (uint256));
            }
        }

        vm.startBroadcast(deployerPrivateKey);

        K613PublicSale sale = new K613PublicSale(usdc, k613, saleAllocation, hardCap, saleStart, saleEnd, deployer);
        console.log("K613PublicSale:", address(sale));

        // Testnet convenience: fund the sale in the same run when the deployer is able to.
        bool funded;
        if (canMint) {
            token.mint(address(sale), saleAllocation);
            funded = true;
            console.log("Funding: minted sale allocation to the sale contract");
        } else if (token.balanceOf(deployer) >= saleAllocation) {
            token.transfer(address(sale), saleAllocation);
            funded = true;
            console.log("Funding: transferred sale allocation from the deployer balance");
        }

        vm.stopBroadcast();

        publicSaleAddr = address(sale);

        require(address(sale.usdc()) == usdc, "usdc mismatch");
        require(address(sale.saleToken()) == k613, "sale token mismatch");
        require(sale.hasRole(sale.DEFAULT_ADMIN_ROLE(), deployer), "admin role missing");
        require(!funded || sale.funded(), "funding did not register");

        _logSummary(sale, usdc, k613, deployer);
    }

    function _logSummary(K613PublicSale sale, address usdc_, address k613_, address admin_) internal view {
        console.log("");
        console.log("--- K613PublicSale TESTNET deployment complete (Arbitrum Sepolia 421614) ---");
        console.log("  K613PublicSale:", address(sale));
        console.log("  -> USDC (payment):", usdc_);
        console.log("  -> K613 (sold):", k613_);
        console.log("  Sale allocation (wei):", sale.saleAllocation());
        console.log("  Hard cap (USDC units):", sale.hardCap());
        console.log("  Sale start (unix):", sale.saleStart());
        console.log("  Sale end (unix):", sale.saleEnd());
        console.log("  Funded:", sale.funded());
        console.log("  Admin (deployer EOA):", admin_);
        if (!sale.funded()) {
            console.log("");
            console.log("REMAINING MANUAL STEP: K613.transfer(K613PublicSale, saleAllocation) BEFORE saleStart");
            console.log("  Without full funding, deposit() reverts SaleNotFunded.");
        }
    }
}
