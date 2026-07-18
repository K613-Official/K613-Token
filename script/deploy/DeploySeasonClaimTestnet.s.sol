// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613SeasonClaim} from "src/campaign/K613SeasonClaim.sol";

/// @title DeploySeasonClaimTestnet
/// @notice Testnet twin of DeploySeasonClaim.s.sol for Arbitrum Sepolia (chainId 421614).
///         Same flow as mainnet — full-snapshot Merkle root from the K613-points build — except:
///         - testnet K613 / K613S1 addresses (existing contracts on Arbitrum Sepolia);
///         - TGE = block.timestamp at deploy, so the vesting curve starts ticking immediately
///           (first 20% claimable right away, +20% every 15 days).
/// @dev Env interface: PRIVATE_KEY; optional SEASON_CLAIM_ADMIN (default deployer EOA).
///      The final Merkle root over the testnet K613S1 snapshot is a hardcoded constant below.
///      After deploy (see log summary):
///        1. K613S1.grantRole(BURNER_ROLE, seasonClaim) — claims revert without it;
///        2. fund the contract: testnet K613.mint(seasonClaim, totalK613ToFund) — broadcaster
///           0xdEc4... holds MINTER_ROLE on the testnet K613.
contract DeploySeasonClaimTestnet is Script {
    /// @notice Reverts if invoked on a chain other than Arbitrum Sepolia.
    error WrongNetwork(uint256 chainId);

    uint256 private constant ARBITRUM_SEPOLIA = 421614;

    /// @notice Testnet K613 on Arbitrum Sepolia (the token sold by the test sale 0x86E5d0ac...).
    address private constant K613_TESTNET = 0xd643dd05646d6d90e1BeCba822184AcD17892bc8;
    /// @notice Testnet K613S1 points token (deployed via DeployCampaignTestnet, live supply).
    address private constant K613S1_TESTNET = 0x71fa5FdDD1022D139aF454F3D34ce30Ad7421655;
    /// @notice Final testnet Merkle root (7 holders, totalK613ToFund = 10,156.96 K613) from
    ///         K613-points snapshots/season-final-testnet (commit 2862c4a4).
    bytes32 private constant FINAL_MERKLE_ROOT = 0x3ba84854695d9959fe8658e4abe356b4341dbbe4daeaca841f13e86af212b281;

    /// @notice Deployed K613SeasonClaim address. Set by `run` so tests can assert without log parsing.
    address public seasonClaimAddr;

    function run() external {
        if (block.chainid != ARBITRUM_SEPOLIA) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        bytes32 finalRoot = FINAL_MERKLE_ROOT;
        address admin = vm.envOr("SEASON_CLAIM_ADMIN", vm.addr(pk));
        // Vesting starts the moment the contract is deployed.
        uint256 tge = block.timestamp;

        console.log("Deployer:", vm.addr(pk));
        console.log("K613:    ", K613_TESTNET);
        console.log("K613S1:  ", K613S1_TESTNET);
        console.log("Admin:   ", admin);
        console.log("TGE:     ", tge);
        console.logBytes32(finalRoot);

        vm.startBroadcast(pk);
        K613SeasonClaim seasonClaim = new K613SeasonClaim(K613_TESTNET, K613S1_TESTNET, finalRoot, tge, admin);
        vm.stopBroadcast();

        seasonClaimAddr = address(seasonClaim);

        // Post-deploy validation against chain state.
        require(address(seasonClaim.k613()) == K613_TESTNET, "k613 mismatch");
        require(address(seasonClaim.k613s1()) == K613S1_TESTNET, "k613s1 mismatch");
        require(seasonClaim.merkleRoot() == finalRoot, "root mismatch");
        require(seasonClaim.tgeTimestamp() == tge, "tge mismatch");
        require(seasonClaim.claimDeadline() == tge + seasonClaim.CLAIM_WINDOW(), "deadline mismatch");
        require(seasonClaim.hasRole(seasonClaim.DEFAULT_ADMIN_ROLE(), admin), "admin role missing");

        console.log("");
        console.log("--- K613SeasonClaim testnet deployment complete (Arbitrum Sepolia 421614) ---");
        console.log("  K613SeasonClaim:", address(seasonClaim));
        console.log("  Claim deadline (unix):", seasonClaim.claimDeadline());
        console.log("");
        console.log("REMAINING MANUAL STEPS (claims revert until both are done):");
        console.log("  1. K613S1.grantRole(BURNER_ROLE, seasonClaim)  - from K613S1 admin (0xdEc4...)");
        console.log("  2. K613.mint(seasonClaim, totalK613ToFund)     - broadcaster is testnet K613 minter");
    }
}
