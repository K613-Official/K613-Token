// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {K613S1} from "src/token/K613S1.sol";
import {K613S1Distributor} from "src/campaign/K613S1Distributor.sol";
import {K613SeasonClaim} from "src/campaign/K613SeasonClaim.sol";

/// @title SmokeFlowTestnet
/// @notice One-shot on-chain smoke test of the FULL campaign flow on Arbitrum Sepolia (421614):
///         deploy K613S1 + K613S1Distributor + K613SeasonClaim, post a synthetic 1-leaf Merkle
///         root, claim K613S1 via the distributor, fund + convert K613S1 -> K613 via SeasonClaim,
///         and assert balances/roles at every step.
/// @dev Synthetic single-leaf tree: root == leaf, proof == []. This validates the on-chain
///      CONTRACT mechanics only - it does NOT touch the subgraph / K613-points pipeline (by
///      explicit decision). The deployer EOA is the single actor (holds gas + K613 + all roles).
///      `K613_ADDRESS` (real K613 on Arb Sepolia) is read from env; everything else is deployed
///      fresh here so the run is self-contained with no .env juggling between steps.
contract SmokeFlowTestnet is Script {
    error WrongNetwork(uint256 chainId);

    uint256 private constant ARBITRUM_SEPOLIA = 421614;
    uint256 private constant WEEKLY_CAP = 5_000_000e18;
    uint256 private constant ALLOC = 1_000e18; // K613S1 claimed AND season K613 allocation

    function run() external {
        if (block.chainid != ARBITRUM_SEPOLIA) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        IERC20 k613 = IERC20(vm.envAddress("K613_ADDRESS"));

        // Synthetic 1-leaf trees (root == leaf, proof == []). Same encoding for both contracts.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(me, ALLOC))));
        bytes32[] memory proof = new bytes32[](0);

        uint256 tge = block.timestamp - 61 days; // -> 100% vested immediately, claim window open
        uint256 k613Before = k613.balanceOf(me);
        require(k613Before >= ALLOC, "deployer K613 balance < ALLOC (cannot fund SeasonClaim)");

        console.log("Actor:", me);
        console.log("K613 token:", address(k613));
        console.log("K613 balance before:", k613Before);

        vm.startBroadcast(pk);

        // --- Phase 1: deploy campaign ---
        K613S1 k613s1 = new K613S1();
        K613S1Distributor distributor = new K613S1Distributor(address(k613s1), WEEKLY_CAP);
        k613s1.grantRole(k613s1.MINTER_ROLE(), address(distributor));
        console.log("K613S1:", address(k613s1));
        console.log("K613S1Distributor:", address(distributor));

        // --- Phase 2: post synthetic root + claim K613S1 ("they give me tokens") ---
        distributor.setMerkleRoot(leaf, ALLOC, 1);
        distributor.claim(ALLOC, proof);
        require(k613s1.balanceOf(me) == ALLOC, "P2: K613S1 balance != ALLOC after claim");
        require(distributor.claimed(me) == ALLOC, "P2: distributor.claimed != ALLOC");
        console.log("Phase 2 OK - K613S1 claimed:", k613s1.balanceOf(me));

        // --- Phase 3: deploy SeasonClaim (synthetic root, TGE 61d ago) ---
        K613SeasonClaim seasonClaim = new K613SeasonClaim(address(k613), address(k613s1), leaf, tge, me);
        k613s1.grantRole(keccak256("BURNER_ROLE"), address(seasonClaim));
        console.log("K613SeasonClaim:", address(seasonClaim));

        // --- Phase 4: fund + convert K613S1 -> K613 ("I convert them to K613") ---
        k613.transfer(address(seasonClaim), ALLOC);
        seasonClaim.claim(ALLOC, proof);

        vm.stopBroadcast();

        // --- Phase 5: assertions ---
        require(k613s1.balanceOf(me) == 0, "P4: K613S1 not fully burned");
        require(seasonClaim.claimed(me) == ALLOC, "P4: seasonClaim.claimed != ALLOC");
        uint256 k613After = k613.balanceOf(me);
        // funded ALLOC out, received ALLOC back via vesting (100%): net K613 unchanged (minus gas).
        require(k613After == k613Before, "P4: K613 net balance changed unexpectedly");

        console.log("");
        console.log("=== SMOKE FLOW PASSED (Arbitrum Sepolia) ===");
        console.log("  K613S1 claimed then fully converted (burned):", ALLOC);
        console.log("  K613 net balance (funded -> claimed back):  ", k613After);
        console.log("  seasonClaim.claimed[me]:", seasonClaim.claimed(me));
        console.log("Addresses:");
        console.log("  K613S1:           ", address(k613s1));
        console.log("  K613S1Distributor:", address(distributor));
        console.log("  K613SeasonClaim:  ", address(seasonClaim));
    }
}
