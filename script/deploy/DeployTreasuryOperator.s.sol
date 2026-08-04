// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613TreasuryOperator} from "src/treasury/K613TreasuryOperator.sol";

/// @title DeployTreasuryOperator
/// @notice Deploys the rate-limited Treasury automation front-end. Admin is the governance Safe;
///         the operator is the cron key that will run the weekly jobs.
/// @dev Env: PRIVATE_KEY; optional OPERATOR_ADDRESS (defaults to the broadcaster).
///      After deploy the Safe must grant the contract Treasury admin — see
///      docs/safe-batches/grant-operator-role.json. The Safe keeps its own role and can revoke
///      the contract at any time.
contract DeployTreasuryOperator is Script {
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;
    address private constant GOVERNANCE_SAFE = 0x7D5cF07621228a3D622b4695A1e28991E4620eBB;
    address private constant TREASURY = 0x3377BAB9A510A586627D2f9013e132d269Eb9871;

    /// @notice Weekly K613 budget for tranche top-ups. Current emission is 479,452 K613/week;
    ///         the headroom lets a missed week be caught up without touching the Safe.
    uint256 private constant TRANCHE_CAP = 600_000e18;
    /// @notice Weekly USDC budget for buybacks (6 decimals). Well above today's ~$40/month of
    ///         protocol fees — raise via `setCaps` from the Safe as revenue grows.
    uint256 private constant BUYBACK_CAP = 1_000e6;
    /// @notice K613/USD TWAP feed of the protocol-owned pool — bounds how bad a buyback may execute.
    address private constant PRICE_FEED = 0x83002Fe57364Def515B5bbA326484bE2e220255E;
    /// @notice Buybacks may not execute more than 3% below the feed price.
    uint256 private constant MAX_SLIPPAGE_BPS = 300;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address operator = vm.envOr("OPERATOR_ADDRESS", vm.addr(pk));

        vm.startBroadcast(pk);
        K613TreasuryOperator op = new K613TreasuryOperator(
            GOVERNANCE_SAFE, operator, TRANCHE_CAP, BUYBACK_CAP, PRICE_FEED, MAX_SLIPPAGE_BPS
        );
        vm.stopBroadcast();

        require(op.hasRole(op.DEFAULT_ADMIN_ROLE(), GOVERNANCE_SAFE), "safe is not admin");
        require(op.hasRole(op.OPERATOR_ROLE(), operator), "operator not set");
        // Sanity-check the price guard against a live quote: $100 of USDC must floor above zero.
        uint256 floor100 = op.minOutFloor(100e6);
        require(floor100 > 0, "price guard returns zero floor");
        console.log("  minOut floor for $100:", floor100);

        console.log("--- K613TreasuryOperator deployed (Monad mainnet 143) ---");
        console.log("  Operator contract:", address(op));
        console.log("  Admin (Safe):     ", GOVERNANCE_SAFE);
        console.log("  Operator key:     ", operator);
        console.log("  Tranche cap/week: ", TRANCHE_CAP);
        console.log("  Buyback cap/week: ", BUYBACK_CAP);
        console.log("");
        console.log("REMAINING STEP - Safe grants Treasury admin to the contract:");
        console.log("  Treasury:", TREASURY);
        console.log("  grantRole(0x00, <operator contract>)");
        console.log("  batch: docs/safe-batches/grant-operator-role.json (put the address in)");
    }
}
