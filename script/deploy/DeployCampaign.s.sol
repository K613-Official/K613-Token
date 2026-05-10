// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613S1} from "src/token/K613S1.sol";
import {K613S1Distributor} from "src/campaign/K613S1Distributor.sol";

/// @title DeployCampaign
/// @notice Deploys the K613 Points Campaign Season 1 stack on Monad mainnet (chainId 143): K613S1 token + K613S1Distributor, then wires `MINTER_ROLE` from the token to the distributor.
/// @dev Reverts on non-Monad chains. K613SeasonClaim is intentionally not deployed here - it is a separate ticket near TGE.
///      Post-deploy operational steps (executed by governance, not the script):
///        1. (later) deploy K613SeasonClaim and grant `BURNER_ROLE` on K613S1 to that contract.
///        2. when migrating from deployer EOA to a multisig: `grantRole(OPERATOR_ROLE, safe)` and `revokeRole(OPERATOR_ROLE, deployerEOA)` on the distributor.
///        3. handover `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` on both contracts to the governance Safe (mirrors HandoverRoles flow used for the K613 stack).
contract DeployCampaign is Script {
    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;

    /// @notice Initial cap on the cumulative-supply increase per `setMerkleRoot` call. 5M K613S1 (~3x of the planned monthly distribution).
    /// @dev Adjustable post-deploy by `DEFAULT_ADMIN_ROLE` via `K613S1Distributor.setWeeklyMintCap`.
    uint256 private constant INITIAL_WEEKLY_MINT_CAP = 5_000_000e18;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        K613S1 k613s1 = new K613S1();
        console.log("K613S1:", address(k613s1));

        K613S1Distributor distributor = new K613S1Distributor(address(k613s1), INITIAL_WEEKLY_MINT_CAP);
        console.log("K613S1Distributor:", address(distributor));

        k613s1.grantRole(k613s1.MINTER_ROLE(), address(distributor));

        vm.stopBroadcast();

        _logSummary(address(k613s1), address(distributor), deployer);
    }

    function _logSummary(address k613s1_, address distributor_, address deployer_) internal pure {
        console.log("");
        console.log("--- Campaign deployment complete ---");
        console.log("Deployed addresses:");
        console.log("  K613S1:           ", k613s1_);
        console.log("  K613S1Distributor:", distributor_);
        console.log("");
        console.log("Roles wired:");
        console.log("  K613S1.MINTER_ROLE             -> K613S1Distributor");
        console.log("");
        console.log("Roles still on deployer (handover pending):");
        console.log("  K613S1.DEFAULT_ADMIN_ROLE      ->", deployer_);
        console.log("  K613S1.PAUSER_ROLE             ->", deployer_);
        console.log("  K613S1Distributor.DEFAULT_ADMIN_ROLE ->", deployer_);
        console.log("  K613S1Distributor.PAUSER_ROLE  ->", deployer_);
        console.log("  K613S1Distributor.OPERATOR_ROLE->", deployer_);
        console.log("");
        console.log("Initial weekly mint cap: 5,000,000 K613S1 (5e24 wei)");
        console.log("");
        console.log("Next manual steps:");
        console.log("  - Use HandoverRoles-style script to transfer admin/pauser roles to governance Safe.");
        console.log("  - Operator role stays on deployer EOA until migration to multisig is decided.");
        console.log("  - K613SeasonClaim deployment is deferred (separate ticket near TGE).");
    }
}
