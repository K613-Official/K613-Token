// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613S1} from "src/token/K613S1.sol";
import {K613S1Distributor} from "src/campaign/K613S1Distributor.sol";

/// @title MigrateDistributor
/// @notice Deploys a fresh K613S1Distributor bound to the EXISTING K613S1 token, then on the token
///         grants MINTER_ROLE to the new distributor and revokes it from the old one.
/// @dev Typical reason: a change to the immutable `MAX_WEEKLY_MINT_CAP` constant requires new
///      bytecode, i.e. a new distributor, while keeping the same K613S1 token.
///      WARNING: the new distributor starts with `lastRootCumulativeSupply = 0` and an empty
///      `claimed` mapping - per-user claim state does NOT carry over. Only safe if no real claims
///      happened on the old distributor, or if the next root is re-baselined accordingly.
///      The new distributor's DEFAULT_ADMIN_ROLE / PAUSER_ROLE / OPERATOR_ROLE are auto-granted to
///      the deployer by its constructor (same role layout as the old one, assuming EOA-held roles).
contract MigrateDistributor is Script {
    /// @notice Deployer does not hold DEFAULT_ADMIN_ROLE on the K613S1 token, so it cannot grant/revoke MINTER_ROLE.
    error NotTokenAdmin(address deployer);
    /// @notice The old distributor does not currently hold MINTER_ROLE - wrong OLD_DISTRIBUTOR_ADDRESS?
    error OldDistributorLacksMinter(address oldDistributor);

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    uint256 private constant DEFAULT_WEEKLY_MINT_CAP = 5_000_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address k613s1Addr = vm.envAddress("K613S1_ADDRESS");
        address oldDistributor = vm.envAddress("OLD_DISTRIBUTOR_ADDRESS");
        uint256 cap = vm.envOr("INITIAL_WEEKLY_MINT_CAP", DEFAULT_WEEKLY_MINT_CAP);

        address deployer = vm.addr(pk);
        K613S1 token = K613S1(k613s1Addr);
        bytes32 minterRole = token.MINTER_ROLE();

        // Fail-fast (simulated against real chain state, before any broadcast):
        if (!token.hasRole(DEFAULT_ADMIN_ROLE, deployer)) revert NotTokenAdmin(deployer);
        if (!token.hasRole(minterRole, oldDistributor)) revert OldDistributorLacksMinter(oldDistributor);

        console.log("Deployer:", deployer);
        console.log("K613S1 token:", k613s1Addr);
        console.log("Old distributor:", oldDistributor);
        console.log("New distributor initial weekly mint cap:", cap);

        vm.startBroadcast(pk);

        K613S1Distributor newDistributor = new K613S1Distributor(k613s1Addr, cap);

        token.grantRole(minterRole, address(newDistributor));
        token.revokeRole(minterRole, oldDistributor);

        vm.stopBroadcast();

        // Post-conditions
        require(token.hasRole(minterRole, address(newDistributor)), "new distributor missing MINTER_ROLE");
        require(!token.hasRole(minterRole, oldDistributor), "old distributor still holds MINTER_ROLE");

        console.log("");
        console.log("--- Distributor migration complete ---");
        console.log("  New K613S1Distributor:", address(newDistributor));
        console.log("  MINTER_ROLE granted -> new, revoked -> old");
        console.log("  Roles on new distributor (admin/pauser/operator) -> deployer EOA");
        console.log("");
        console.log("UPDATE .env:  DISTRIBUTOR_ADDRESS=", address(newDistributor));
        console.log("NOTE: new distributor lastRootCumulativeSupply=0, claimed={} (fresh state).");
    }
}
