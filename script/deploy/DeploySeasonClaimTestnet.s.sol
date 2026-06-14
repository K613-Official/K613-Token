// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613S1} from "src/token/K613S1.sol";
import {K613SeasonClaim} from "src/campaign/K613SeasonClaim.sol";

/// @title DeploySeasonClaimTestnet
/// @notice Testnet-only deploy of `K613SeasonClaim` on Arbitrum Sepolia (chainId 421614).
///         There is no production `DeploySeasonClaim` script in this repo - this is the first
///         deploy script ever written for the contract; it intentionally targets testnet only.
/// @dev Mirrors the env interface documented in OPERATIONS_SOP 5.2
///      (K613_ADDRESS, K613S1_ADDRESS, FINAL_MERKLE_ROOT, TGE_TIMESTAMP). On testnet `_admin`
///      is the deployer EOA (no Safe). Because sub-project A leaves `K613S1.DEFAULT_ADMIN_ROLE`
///      on the deployer EOA, this script also grants `K613S1.BURNER_ROLE` to the freshly
///      deployed SeasonClaim in the same run (on mainnet that step is a separate Safe action).
///      Funding the contract with K613 is NOT automated here - it depends on the deployer
///      holding a K613 balance and is left as an explicit manual step (see log summary).
contract DeploySeasonClaimTestnet is Script {
    /// @notice Reverts if invoked on a chain other than Arbitrum Sepolia.
    error WrongNetwork(uint256 chainId);

    uint256 private constant ARBITRUM_SEPOLIA = 421614;

    /// @notice Deployed K613SeasonClaim address. Set by `runWith` so tests can assert without log parsing.
    address public seasonClaimAddr;

    /// @notice Entrypoint for `forge script`. Reads all parameters from the environment.
    /// @dev FINAL_MERKLE_ROOT comes from the K613-points season-final export (sub-project B).
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        runWith(
            vm.envAddress("K613_ADDRESS"),
            vm.envAddress("K613S1_ADDRESS"),
            vm.envBytes32("FINAL_MERKLE_ROOT"),
            vm.envUint("TGE_TIMESTAMP"),
            vm.addr(pk), // testnet: admin = deployer EOA (no Safe handover)
            pk
        );
    }

    /// @notice Deploys K613SeasonClaim with explicit parameters. Used by `run()` and tests.
    /// @param k613 K613 token address (paid out on claim).
    /// @param k613s1 K613S1 token address (burned 1:1 on claim).
    /// @param merkleRoot Final Season 1 K613-allocation Merkle root (must be non-zero).
    /// @param tgeTimestamp Vesting-curve anchor.
    /// @param admin Address granted DEFAULT_ADMIN_ROLE + PAUSER_ROLE on SeasonClaim.
    /// @param deployerPrivateKey Deployer EOA key; must hold K613S1.DEFAULT_ADMIN_ROLE for the BURNER_ROLE grant.
    function runWith(
        address k613,
        address k613s1,
        bytes32 merkleRoot,
        uint256 tgeTimestamp,
        address admin,
        uint256 deployerPrivateKey
    ) public {
        if (block.chainid != ARBITRUM_SEPOLIA) revert WrongNetwork(block.chainid);

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        K613SeasonClaim seasonClaim = new K613SeasonClaim(k613, k613s1, merkleRoot, tgeTimestamp, admin);
        console.log("K613SeasonClaim:", address(seasonClaim));

        // On testnet the deployer still holds K613S1.DEFAULT_ADMIN_ROLE (sub-project A leaves it
        // on the EOA), so wire BURNER_ROLE here instead of as a separate Safe step.
        K613S1(k613s1).grantRole(keccak256("BURNER_ROLE"), address(seasonClaim));

        vm.stopBroadcast();

        seasonClaimAddr = address(seasonClaim);

        _logSummary(address(seasonClaim), k613, k613s1, admin);
    }

    function _logSummary(address seasonClaim_, address k613_, address k613s1_, address admin_) internal pure {
        console.log("");
        console.log("--- SeasonClaim TESTNET deployment complete (Arbitrum Sepolia 421614) ---");
        console.log("  K613SeasonClaim:", seasonClaim_);
        console.log("  -> K613 (payout):", k613_);
        console.log("  -> K613S1 (burned 1:1):", k613s1_);
        console.log("");
        console.log("Roles:");
        console.log("  K613S1.BURNER_ROLE -> K613SeasonClaim (granted in this run)");
        console.log("  SeasonClaim.DEFAULT_ADMIN_ROLE / PAUSER_ROLE ->", admin_);
        console.log("");
        console.log("REMAINING MANUAL STEP (not automated - needs a K613 balance):");
        console.log("  K613.transfer(K613SeasonClaim, totalK613ToFund)");
        console.log("  Without funding, claim() reverts on the K613 safeTransfer.");
    }
}
