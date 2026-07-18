// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613SeasonClaim} from "src/campaign/K613SeasonClaim.sol";

/// @title DeploySeasonClaim
/// @notice Deploys `K613SeasonClaim` on Monad mainnet (chainId 143) — the post-TGE conversion of
///         K613S1 points into K613 (1:1, step vesting: 20% at TGE + 4 x 20% every 15 days, claims
///         burn K613S1). The Merkle root is immutable — a bad root requires a redeploy.
/// @dev Env interface: PRIVATE_KEY only. K613, K613S1, the TGE timestamp, the final Merkle root and
///      the admin (governance Safe) are hardcoded constants below.
///      After deploy (see log summary):
///        1. K613S1.grantRole(BURNER_ROLE, seasonClaim) — claims revert without it;
///        2. K613.transfer(seasonClaim, totalK613ToFund) BEFORE TGE_TIMESTAMP.
contract DeploySeasonClaim is Script {
    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);
    /// @notice Reverts if TGE_TIMESTAMP constant is already in the past at broadcast time.
    error TgeInPast(uint256 tge, uint256 nowTs);

    uint256 private constant MONAD_MAINNET = 143;

    /// @notice K613 on Monad mainnet, deployed 2026-07-10 (see docs/OPERATIONS_SOP.md D.1).
    address private constant K613_MONAD = 0xb09582631336068d4B0089d943f40CbF46dE5189;
    /// @notice K613S1 points token on Monad mainnet (Season 1 campaign, live since June 2026).
    address private constant K613S1_MONAD = 0x4f9ba5CaE0e3F651821283EC4e303fE8D1dA542a;
    /// @notice Season 1 TGE: 2026-07-20 00:00:00 UTC. Vesting curve is anchored here; must match
    ///         the --tge-date used in build-season-merkle.
    uint256 private constant TGE_TIMESTAMP = 1784505600;
    /// @notice Final Season 1 Merkle root (275 holders, totalK613ToFund = 429,198.33 K613) from
    ///         K613-points snapshots/season-final-mainnet (commit 2862c4a4).
    bytes32 private constant FINAL_MERKLE_ROOT = 0x986ad9b1823fd92cc93e52d6a46f29c3f6e076b20b7df006f4c04a77f2a8063a;
    /// @notice Governance Safe (2-of-3) — receives DEFAULT_ADMIN_ROLE + PAUSER_ROLE on the claim
    ///         contract (can pause and recover unclaimed K613 after the 365-day deadline).
    address private constant GOVERNANCE_SAFE = 0x7D5cF07621228a3D622b4695A1e28991E4620eBB;

    /// @notice Deployed K613SeasonClaim address. Set by `run` so tests can assert without log parsing.
    address public seasonClaimAddr;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);
        if (TGE_TIMESTAMP <= block.timestamp) revert TgeInPast(TGE_TIMESTAMP, block.timestamp);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address k613 = K613_MONAD;
        bytes32 finalRoot = FINAL_MERKLE_ROOT;
        address admin = GOVERNANCE_SAFE;

        console.log("Deployer:", vm.addr(pk));
        console.log("K613:    ", k613);
        console.log("K613S1:  ", K613S1_MONAD);
        console.log("Admin:   ", admin);
        console.log("TGE:     ", TGE_TIMESTAMP);
        console.logBytes32(finalRoot);

        vm.startBroadcast(pk);
        K613SeasonClaim seasonClaim = new K613SeasonClaim(k613, K613S1_MONAD, finalRoot, TGE_TIMESTAMP, admin);
        vm.stopBroadcast();

        seasonClaimAddr = address(seasonClaim);

        // Post-deploy validation against chain state.
        require(address(seasonClaim.k613()) == k613, "k613 mismatch");
        require(address(seasonClaim.k613s1()) == K613S1_MONAD, "k613s1 mismatch");
        require(seasonClaim.merkleRoot() == finalRoot, "root mismatch");
        require(seasonClaim.tgeTimestamp() == TGE_TIMESTAMP, "tge mismatch");
        require(seasonClaim.claimDeadline() == TGE_TIMESTAMP + seasonClaim.CLAIM_WINDOW(), "deadline mismatch");
        require(seasonClaim.hasRole(seasonClaim.DEFAULT_ADMIN_ROLE(), admin), "admin role missing");

        console.log("");
        console.log("--- K613SeasonClaim deployment complete (Monad mainnet 143) ---");
        console.log("  K613SeasonClaim:", address(seasonClaim));
        console.log("  Claim deadline (unix):", seasonClaim.claimDeadline());
        console.log("");
        console.log("REMAINING MANUAL STEPS (claims revert until both are done):");
        console.log("  1. K613S1.grantRole(BURNER_ROLE, seasonClaim)  - from K613S1 admin");
        console.log("  2. K613.transfer(seasonClaim, totalK613ToFund) - BEFORE TGE_TIMESTAMP");
    }
}
