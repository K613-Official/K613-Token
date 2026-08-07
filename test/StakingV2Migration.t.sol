// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, stdError} from "forge-std/Test.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {StakingV2} from "../src/staking/StakingV2.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";

/// @title StakingV2MigrationTest
/// @notice Demonstrates why V1 and V2 MUST NOT both hold MINTER_ROLE on xK613 at the same time.
///         An earlier version of StakingV2's NatSpec claimed "xK613 minted by V1 can only ever be
///         burned by V1" and used that to justify running both in parallel during a drain window.
///         That claim was false: xK613 is a plain fungible ERC20 with no memory of which contract
///         minted a given unit, and `exit()` burns whatever was escrowed into it via
///         `initiateExit`. These tests pin the real behavior so the false assumption cannot be
///         reintroduced.
contract StakingV2MigrationTest is Test {
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant PENALTY_BPS = 5_000;
    uint256 private constant ONE = 1e18;

    K613 private k613;
    xK613 private xk613;
    Staking private v1;
    StakingV2 private v2;
    RewardsDistributor private distributor;

    address private alice = address(0xA11CE); // stakes in V1
    address private bob = address(0xB0B); // stakes in V2

    function setUp() public {
        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        v1 = new Staking(address(k613), address(xk613), LOCK_DURATION, PENALTY_BPS);
        v2 = new StakingV2(address(k613), address(xk613), LOCK_DURATION, PENALTY_BPS);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);

        v1.setRewardsDistributor(address(distributor));
        v2.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(v2));

        // The exact parallel-role setup the original migration plan called for: grant V2 the role
        // directly (not via setMinter, which would revoke V1's) so both can mint and burn.
        xk613.setMinter(address(v1));
        xk613.grantRole(xk613.MINTER_ROLE(), address(v2));
        xk613.setTransferWhitelist(address(v1), true);
        xk613.setTransferWhitelist(address(v2), true);
        xk613.setTransferWhitelist(address(distributor), true);

        k613.mint(alice, 10_000 * ONE);
        k613.mint(bob, 10_000 * ONE);
    }

    /// @dev Warps to the moment a specific exit request unlocks. Deliberately absolute rather than
    ///      `vm.warp(block.timestamp + LOCK_DURATION)`: inside a single test frame `block.timestamp`
    ///      does not reflect an earlier warp, so the relative form silently re-warps to the same
    ///      point. A second exit then reverts with Locked() — which a bare `expectRevert` would
    ///      happily accept as proof of something else entirely.
    function _warpPastLock(address user, uint256 index) private {
        (, uint256 startedAt) = v2.exitRequestAt(user, index);
        vm.warp(startedAt + LOCK_DURATION);
    }

    /// @notice The core disproof: xK613 minted by V1 is accepted, escrowed and burned by V2, paying
    ///         out of V2's backing. Nothing in the token or either contract prevents it.
    function test_V1MintedXK613_CanBeBurnedByV2() public {
        vm.startPrank(alice);
        k613.approve(address(v1), 1_000 * ONE);
        v1.stake(1_000 * ONE);
        vm.stopPrank();

        // V1 holds Alice's backing; V2 holds nothing yet.
        assertEq(k613.balanceOf(address(v1)), 1_000 * ONE);
        assertEq(v2.totalBacking(), 0);

        // Bob stakes into V2, giving V2 backing that belongs to him.
        vm.startPrank(bob);
        k613.approve(address(v2), 1_000 * ONE);
        v2.stake(1_000 * ONE);
        vm.stopPrank();
        assertEq(v2.totalBacking(), 1_000 * ONE);

        // Alice routes her V1-minted xK613 through V2. V2's only gate is her balance.
        vm.startPrank(alice);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        v2.exit(0);

        // Alice got paid — out of Bob's backing.
        assertEq(k613.balanceOf(alice), 10_000 * ONE);
        assertEq(v2.totalBacking(), 0);
        // Her original backing is still sitting in V1, now unclaimable by her.
        assertEq(k613.balanceOf(address(v1)), 1_000 * ONE);
    }

    /// @notice The consequence: Bob, who staked honestly into V2, can no longer exit. His backing
    ///         was paid to Alice, and he has no position in V1 to fall back on — V1 gates exits on
    ///         its own per-user position record, which Bob never had. His funds are stranded.
    function test_V2Staker_StrandedAfterCrossContractDrain() public {
        vm.startPrank(alice);
        k613.approve(address(v1), 1_000 * ONE);
        v1.stake(1_000 * ONE);
        vm.stopPrank();

        vm.startPrank(bob);
        k613.approve(address(v2), 1_000 * ONE);
        v2.stake(1_000 * ONE);
        vm.stopPrank();

        // Alice drains V2's backing using V1-minted tokens.
        vm.startPrank(alice);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        v2.exit(0);

        // Bob still holds 1,000 xK613 and tries to leave through V2.
        assertEq(xk613.balanceOf(bob), 1_000 * ONE);
        vm.startPrank(bob);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();

        _warpPastLock(bob, 0);
        // V2 has no backing left: the subtraction underflows and reverts. V2 stays solvent — it
        // simply cannot pay Bob.
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        v2.exit(0);

        // And V1 is not an escape hatch: Bob has no position there.
        vm.prank(bob);
        v2.cancelExit(0);
        vm.startPrank(bob);
        xk613.approve(address(v1), 1_000 * ONE);
        vm.expectRevert(Staking.NothingToInitiate.selector);
        v1.initiateExit(1_000 * ONE);
        vm.stopPrank();

        // Bob's 1,000 K613 is stranded: V1 holds it, only Alice had the position that unlocks it.
        assertEq(k613.balanceOf(bob), 9_000 * ONE);
        assertEq(k613.balanceOf(address(v1)), 1_000 * ONE);
    }

    /// @notice Global accounting stays consistent even as per-contract claims break — which is
    ///         exactly why this is easy to miss: no aggregate invariant is violated. Total supply
    ///         still equals the sum of both contracts' backing throughout.
    function test_GlobalInvariantHolds_WhilePerContractClaimsBreak() public {
        vm.startPrank(alice);
        k613.approve(address(v1), 1_000 * ONE);
        v1.stake(1_000 * ONE);
        vm.stopPrank();

        vm.startPrank(bob);
        k613.approve(address(v2), 1_000 * ONE);
        v2.stake(1_000 * ONE);
        vm.stopPrank();

        assertEq(xk613.totalSupply(), v1.totalBacking() + v2.totalBacking());

        vm.startPrank(alice);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        v2.exit(0);

        // Still balanced in aggregate — the damage is entirely in who can reach which reserve.
        assertEq(xk613.totalSupply(), v1.totalBacking() + v2.totalBacking());
        assertEq(xk613.totalSupply(), 1_000 * ONE);
        assertEq(v1.totalBacking(), 1_000 * ONE);
        assertEq(v2.totalBacking(), 0);
    }

    /// @notice Sanity: with only V2 holding MINTER_ROLE (the safe configuration), V2 behaves
    ///         normally. Included so the tests above read as "parallel roles are the problem",
    ///         not "V2 is broken".
    function test_V2Alone_IsSafe() public {
        xk613.setMinter(address(v2)); // revokes V1's role

        vm.startPrank(bob);
        k613.approve(address(v2), 1_000 * ONE);
        v2.stake(1_000 * ONE);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(bob);
        v2.exit(0);

        assertEq(k613.balanceOf(bob), 10_000 * ONE);
        assertEq(v2.totalBacking(), 0);
        assertEq(xk613.totalSupply(), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Seeded cutover — the migration `seedBacking` exists for.
    //
    // The tests above establish that running two minters is unsafe, and that revoking V1's role
    // strands its reserve. `seedBacking` resolves the deadlock by paying for the stranding up
    // front: the Safe funds V2 with K613 equal to the outstanding xK613, then swaps the minter in
    // the same batch. Legacy holders redeem against V2 and never touch V1 again. What follows pins
    // both that this works and the two ways to size it wrong.
    // ---------------------------------------------------------------------------------------

    /// @notice Executes the cutover exactly as the Safe batch does — seed, then `setMinter` — and
    ///         checks the property that matters: a holder whose xK613 was minted by V1, and who has
    ///         no position in V2 at all, exits V2 in full. V1 is dead by then and never consulted.
    function test_SeededCutover_LegacyHolderExitsThroughV2() public {
        xk613.setMinter(address(v1)); // undo setUp's parallel grant: V1 is the sole minter again

        vm.startPrank(alice);
        k613.approve(address(v1), 1_000 * ONE);
        v1.stake(1_000 * ONE);
        vm.stopPrank();

        // --- the Safe batch, in order ---
        uint256 seed = xk613.totalSupply();
        k613.mint(address(this), seed);
        k613.approve(address(v2), seed);
        v2.seedBacking(seed);
        xk613.setMinter(address(v2)); // atomic swap; no window where both hold the role
        // --- end batch ---

        // Every outstanding xK613 is now backed by V2 and by nothing else.
        assertEq(v2.totalBacking(), xk613.totalSupply());
        assertFalse(xk613.hasRole(xk613.MINTER_ROLE(), address(v1)));

        vm.startPrank(alice);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        v2.exit(0);

        assertEq(k613.balanceOf(alice), 10_000 * ONE, "legacy holder made whole");
        assertEq(v2.totalBacking(), 0);
        assertEq(xk613.totalSupply(), 0);
        // The cost, stated as an assertion so it cannot be forgotten: V1's reserve is still there
        // and is now unreachable forever — no minter role, so nothing can burn against it.
        assertEq(k613.balanceOf(address(v1)), 1_000 * ONE, "V1 reserve written off by design");
    }

    /// @notice A staker who joins V2 after the cutover is not competing with legacy holders for the
    ///         same reserve — the seed covers the legacy claim, their stake covers theirs.
    function test_SeededCutover_NewStakerUnaffectedByLegacyRedemption() public {
        xk613.setMinter(address(v1));

        vm.startPrank(alice);
        k613.approve(address(v1), 1_000 * ONE);
        v1.stake(1_000 * ONE);
        vm.stopPrank();

        uint256 seed = xk613.totalSupply();
        k613.mint(address(this), seed);
        k613.approve(address(v2), seed);
        v2.seedBacking(seed);
        xk613.setMinter(address(v2));

        vm.startPrank(bob);
        k613.approve(address(v2), 1_000 * ONE);
        v2.stake(1_000 * ONE);
        vm.stopPrank();

        assertEq(v2.totalBacking(), 2_000 * ONE);
        assertEq(xk613.totalSupply(), 2_000 * ONE);

        // Alice redeems her legacy tokens in full.
        vm.startPrank(alice);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        v2.exit(0);

        // Bob is untouched and still exits normally afterwards.
        vm.startPrank(bob);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();
        _warpPastLock(bob, 0);
        vm.prank(bob);
        v2.exit(0);

        assertEq(k613.balanceOf(bob), 10_000 * ONE);
        assertEq(v2.totalBacking(), 0);
        assertEq(xk613.totalSupply(), 0);
    }

    /// @notice Sizing failure one: seeding less than `xK613.totalSupply()`. The shortfall does not
    ///         announce itself at cutover — it surfaces as a revert for whichever holder exits last.
    ///         This is why the batch must read totalSupply with StakingV1 already paused.
    function test_SeededCutover_UnderSeed_StrandsTheLastHolder() public {
        xk613.setMinter(address(v1));

        vm.startPrank(alice);
        k613.approve(address(v1), 1_000 * ONE);
        v1.stake(1_000 * ONE);
        vm.stopPrank();
        vm.startPrank(bob);
        k613.approve(address(v1), 1_000 * ONE);
        v1.stake(1_000 * ONE);
        vm.stopPrank();

        // Seed 1,500 against 2,000 outstanding — e.g. supply read before Bob's stake landed.
        uint256 seed = 1_500 * ONE;
        assertLt(seed, xk613.totalSupply());
        k613.mint(address(this), seed);
        k613.approve(address(v2), seed);
        v2.seedBacking(seed);
        xk613.setMinter(address(v2));

        vm.startPrank(alice);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        v2.exit(0); // succeeds — nothing here warns that the reserve is short

        vm.startPrank(bob);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();
        _warpPastLock(bob, 0);
        vm.prank(bob);
        // Specifically the underflow, not just any revert — a bare expectRevert here would also
        // swallow a Locked(), which is how a mis-timed warp turns this into a test of nothing.
        vm.expectRevert(stdError.arithmeticError); // 500 backing against a 1,000 claim
        v2.exit(0);
    }

    /// @notice Sizing failure two: seeding more than outstanding leaves K613 no xK613 can claim.
    ///         Harmless to holders, but it is a permanent donation — there is no un-seed.
    function test_SeededCutover_OverSeed_LeavesUnclaimableSurplus() public {
        xk613.setMinter(address(v1));

        vm.startPrank(alice);
        k613.approve(address(v1), 1_000 * ONE);
        v1.stake(1_000 * ONE);
        vm.stopPrank();

        uint256 seed = 1_500 * ONE; // 500 more than outstanding
        k613.mint(address(this), seed);
        k613.approve(address(v2), seed);
        v2.seedBacking(seed);
        xk613.setMinter(address(v2));

        vm.startPrank(alice);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(1_000 * ONE);
        vm.stopPrank();
        vm.warp(block.timestamp + LOCK_DURATION);
        vm.prank(alice);
        v2.exit(0);

        assertEq(xk613.totalSupply(), 0, "every claim settled");
        assertEq(v2.totalBacking(), 500 * ONE, "surplus counted as backing");
        assertEq(k613.balanceOf(address(v2)), 500 * ONE, "and sitting in the contract, unclaimable");
    }

    /// @notice `seedBacking` is deliberately not `whenNotPaused`: the cutover is meant to run with
    ///         staking paused so nothing can interleave between the seed and the minter swap.
    function test_SeedBacking_WorksWhilePaused() public {
        v2.pause();

        k613.mint(address(this), 1_000 * ONE);
        k613.approve(address(v2), 1_000 * ONE);
        v2.seedBacking(1_000 * ONE);

        assertEq(v2.totalBacking(), 1_000 * ONE);
    }

    function test_SeedBacking_OnlyAdmin() public {
        k613.mint(alice, 1_000 * ONE);
        vm.startPrank(alice);
        k613.approve(address(v2), 1_000 * ONE);
        vm.expectRevert();
        v2.seedBacking(1_000 * ONE);
        vm.stopPrank();
    }

    function test_SeedBacking_ZeroReverts() public {
        vm.expectRevert(StakingV2.ZeroAmount.selector);
        v2.seedBacking(0);
    }

    /// @notice Seeding mints nothing — that is the entire distinction from `stake()`, and the
    ///         reason it can back tokens another contract issued.
    function test_SeedBacking_DoesNotMint() public {
        uint256 supplyBefore = xk613.totalSupply();

        k613.mint(address(this), 1_000 * ONE);
        k613.approve(address(v2), 1_000 * ONE);
        v2.seedBacking(1_000 * ONE);

        assertEq(xk613.totalSupply(), supplyBefore);
        assertEq(xk613.balanceOf(address(this)), 0);
        assertEq(v2.totalBacking(), 1_000 * ONE);
    }

    /// @notice `setMaxExitRequests` had no test on V2 at all, yet it is the only bound on how many
    ///         requests a wallet can park in the contract — and `exitPendingSum` loops over them.
    function test_SetMaxExitRequests_GatesTheQueueAndIsAdminOnly() public {
        xk613.setMinter(address(v2));

        v2.setMaxExitRequests(1);
        assertEq(v2.maxExitRequests(), 1);
        assertEq(v2.MAX_EXIT_REQUESTS(), 1, "legacy alias must track the setter");

        vm.startPrank(bob);
        k613.approve(address(v2), 1_000 * ONE);
        v2.stake(1_000 * ONE);
        xk613.approve(address(v2), 1_000 * ONE);
        v2.initiateExit(400 * ONE);
        vm.expectRevert(StakingV2.ExitQueueFull.selector);
        v2.initiateExit(400 * ONE);
        vm.stopPrank();

        // Raising the cap unblocks the same caller without touching the existing request.
        v2.setMaxExitRequests(2);
        vm.startPrank(bob);
        v2.initiateExit(400 * ONE);
        vm.stopPrank();
        assertEq(v2.exitQueueLength(bob), 2);
        assertEq(v2.exitPendingSum(bob), 800 * ONE);

        vm.expectRevert(StakingV2.InvalidMaxExitRequests.selector);
        v2.setMaxExitRequests(0);

        vm.prank(alice);
        vm.expectRevert();
        v2.setMaxExitRequests(5);
    }
}
