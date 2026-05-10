// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";
import {K613S1} from "../src/token/K613S1.sol";
import {K613SeasonClaim} from "../src/campaign/K613SeasonClaim.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

contract K613SeasonClaimTest is Test {
    K613 private k613;
    K613S1 private k613s1;
    K613SeasonClaim private claim_;

    address private admin = address(this);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCAFE);
    address private treasury = address(0x77E45);

    uint256 private aliceAlloc = 1000e18;
    uint256 private bobAlloc = 500e18;
    uint256 private tgeTimestamp;
    bytes32 private aliceLeaf;
    bytes32 private bobLeaf;
    bytes32 private merkleRoot;

    function setUp() public {
        // K613 — admin = test, initialMinter = test (so we can mint K613 for funding).
        k613 = new K613(address(this));
        k613s1 = new K613S1();

        tgeTimestamp = block.timestamp + 1000;

        aliceLeaf = _hashLeaf(alice, aliceAlloc);
        bobLeaf = _hashLeaf(bob, bobAlloc);
        merkleRoot = _hashPair(aliceLeaf, bobLeaf);

        claim_ = new K613SeasonClaim(address(k613), address(k613s1), merkleRoot, tgeTimestamp, address(this));

        // Wire roles: SeasonClaim needs BURNER_ROLE on K613S1; test needs MINTER_ROLE for setup.
        k613s1.grantRole(k613s1.BURNER_ROLE(), address(claim_));
        k613s1.grantRole(k613s1.MINTER_ROLE(), address(this));

        // Mint K613S1 to participants (simulating Distributor claim).
        k613s1.mint(alice, aliceAlloc);
        k613s1.mint(bob, bobAlloc);

        // Fund SeasonClaim with K613.
        k613.mint(address(claim_), aliceAlloc + bobAlloc);
    }

    // ---------- helpers ----------

    function _hashLeaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory) {
        bytes32[] memory p = new bytes32[](1);
        p[0] = sibling;
        return p;
    }

    // ---------- constructor ----------

    /// @notice testConstructorImmutables: all immutables set; claimDeadline = TGE + 365d.
    function testConstructorImmutables() public view {
        assertEq(address(claim_.k613()), address(k613));
        assertEq(address(claim_.k613s1()), address(k613s1));
        assertEq(claim_.merkleRoot(), merkleRoot);
        assertEq(claim_.tgeTimestamp(), tgeTimestamp);
        assertEq(claim_.claimDeadline(), tgeTimestamp + 365 days);
        assertTrue(claim_.hasRole(claim_.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(claim_.hasRole(claim_.PAUSER_ROLE(), address(this)));
    }

    /// @notice testConstructorRevertsOnZeroK613: zero K613 address reverts.
    function testConstructorRevertsOnZeroK613() public {
        vm.expectRevert(K613SeasonClaim.ZeroAddress.selector);
        new K613SeasonClaim(address(0), address(k613s1), merkleRoot, tgeTimestamp, address(this));
    }

    /// @notice testConstructorRevertsOnZeroK613S1: zero K613S1 address reverts.
    function testConstructorRevertsOnZeroK613S1() public {
        vm.expectRevert(K613SeasonClaim.ZeroAddress.selector);
        new K613SeasonClaim(address(k613), address(0), merkleRoot, tgeTimestamp, address(this));
    }

    /// @notice testConstructorRevertsOnZeroAdmin: zero admin reverts.
    function testConstructorRevertsOnZeroAdmin() public {
        vm.expectRevert(K613SeasonClaim.ZeroAddress.selector);
        new K613SeasonClaim(address(k613), address(k613s1), merkleRoot, tgeTimestamp, address(0));
    }

    /// @notice testConstructorRevertsOnEmptyRoot: bytes32(0) merkle root reverts.
    function testConstructorRevertsOnEmptyRoot() public {
        vm.expectRevert(K613SeasonClaim.EmptyMerkleRoot.selector);
        new K613SeasonClaim(address(k613), address(k613s1), bytes32(0), tgeTimestamp, address(this));
    }

    // ---------- vestedFraction ----------

    /// @notice testVestedFractionSchedule: 0% pre-TGE, 20%/40%/60%/80%/100% at each 15-day step.
    function testVestedFractionSchedule() public view {
        assertEq(claim_.vestedFraction(tgeTimestamp - 1), 0);
        assertEq(claim_.vestedFraction(tgeTimestamp), 2_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 1), 2_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 15 days - 1), 2_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 15 days), 4_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 30 days - 1), 4_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 30 days), 6_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 45 days), 8_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 60 days - 1), 8_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 60 days), 10_000);
        assertEq(claim_.vestedFraction(tgeTimestamp + 365 days - 1), 10_000);
    }

    // ---------- claim happy paths ----------

    /// @notice testFirstClaimAtTGE: at exactly TGE, alice gets 20% K613, 20% K613S1 burned.
    function testFirstClaimAtTGE() public {
        vm.warp(tgeTimestamp);
        vm.prank(alice);
        claim_.claim(aliceAlloc, _proof(bobLeaf));

        uint256 expected = aliceAlloc * 2_000 / 10_000;
        assertEq(k613.balanceOf(alice), expected);
        assertEq(k613s1.balanceOf(alice), aliceAlloc - expected);
        assertEq(claim_.claimed(alice), expected);
    }

    /// @notice testSequentialClaimsAtCheckpoints: claims at each vesting step pay exactly the delta; at TGE+60d alice has full alloc and zero K613S1.
    function testSequentialClaimsAtCheckpoints() public {
        uint256[5] memory pcts = [uint256(2_000), 4_000, 6_000, 8_000, 10_000];
        uint256[5] memory offsets = [uint256(0), 15 days, 30 days, 45 days, 60 days];

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(tgeTimestamp + offsets[i]);
            vm.prank(alice);
            claim_.claim(aliceAlloc, _proof(bobLeaf));

            uint256 expectedCum = aliceAlloc * pcts[i] / 10_000;
            assertEq(claim_.claimed(alice), expectedCum, "cumulative claimed");
            assertEq(k613.balanceOf(alice), expectedCum, "K613 balance");
            assertEq(k613s1.balanceOf(alice), aliceAlloc - expectedCum, "K613S1 remaining");
        }

        assertEq(k613.balanceOf(alice), aliceAlloc);
        assertEq(k613s1.balanceOf(alice), 0);
        // bob never claimed, so K613S1 totalSupply = bob's allocation only
        assertEq(k613s1.totalSupply(), bobAlloc);
    }

    /// @notice testLateFirstClaimGetsFullVested: alice does not claim until TGE+60d, then receives 100% in one tx.
    function testLateFirstClaimGetsFullVested() public {
        vm.warp(tgeTimestamp + 60 days);
        vm.prank(alice);
        claim_.claim(aliceAlloc, _proof(bobLeaf));

        assertEq(k613.balanceOf(alice), aliceAlloc);
        assertEq(k613s1.balanceOf(alice), 0);
        assertEq(claim_.claimed(alice), aliceAlloc);
    }

    // ---------- claim revert paths ----------

    /// @notice testClaimBeforeTGEReverts: pre-TGE vested = 0 → NothingToClaim.
    function testClaimBeforeTGEReverts() public {
        vm.warp(tgeTimestamp - 1);
        vm.prank(alice);
        vm.expectRevert(K613SeasonClaim.NothingToClaim.selector);
        claim_.claim(aliceAlloc, _proof(bobLeaf));
    }

    /// @notice testRepeatClaimSameMomentReverts: second claim in same vesting tier → NothingToClaim.
    function testRepeatClaimSameMomentReverts() public {
        vm.warp(tgeTimestamp);
        vm.prank(alice);
        claim_.claim(aliceAlloc, _proof(bobLeaf));

        vm.prank(alice);
        vm.expectRevert(K613SeasonClaim.NothingToClaim.selector);
        claim_.claim(aliceAlloc, _proof(bobLeaf));
    }

    /// @notice testInvalidProofReverts: wrong account or amount in leaf → InvalidProof.
    function testInvalidProofReverts() public {
        vm.warp(tgeTimestamp);

        // wrong amount
        vm.prank(alice);
        vm.expectRevert(K613SeasonClaim.InvalidProof.selector);
        claim_.claim(aliceAlloc + 1, _proof(bobLeaf));

        // not in tree
        vm.prank(carol);
        vm.expectRevert(K613SeasonClaim.InvalidProof.selector);
        claim_.claim(100e18, _proof(bobLeaf));
    }

    /// @notice testInsufficientK613S1Reverts: alice has valid proof but no K613S1 → InsufficientK613S1.
    function testInsufficientK613S1Reverts() public {
        // Burn alice's K613S1 (test takes BURNER_ROLE temporarily).
        k613s1.grantRole(k613s1.BURNER_ROLE(), address(this));
        k613s1.burnFrom(alice, aliceAlloc);

        vm.warp(tgeTimestamp);
        vm.prank(alice);
        vm.expectRevert(K613SeasonClaim.InsufficientK613S1.selector);
        claim_.claim(aliceAlloc, _proof(bobLeaf));
    }

    /// @notice testClaimAfterDeadlineReverts: at exactly claimDeadline → ClaimWindowClosed.
    function testClaimAfterDeadlineReverts() public {
        vm.warp(claim_.claimDeadline());
        vm.prank(alice);
        vm.expectRevert(K613SeasonClaim.ClaimWindowClosed.selector);
        claim_.claim(aliceAlloc, _proof(bobLeaf));
    }

    /// @notice testPauseBlocksClaim: paused → claim reverts EnforcedPause.
    function testPauseBlocksClaim() public {
        claim_.pause();
        vm.warp(tgeTimestamp);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        claim_.claim(aliceAlloc, _proof(bobLeaf));
    }

    // ---------- recover ----------

    /// @notice testRecoverBeforeDeadlineReverts: recovery cannot happen while claims are still open.
    function testRecoverBeforeDeadlineReverts() public {
        vm.warp(tgeTimestamp + 60 days);
        vm.expectRevert(K613SeasonClaim.ClaimsStillOpen.selector);
        claim_.recoverUnclaimedK613(treasury, 1);
    }

    /// @notice testRecoverAfterDeadline: after deadline, admin sweeps remaining K613 to treasury.
    function testRecoverAfterDeadline() public {
        // Alice claims fully; bob never claims.
        vm.warp(tgeTimestamp + 60 days);
        vm.prank(alice);
        claim_.claim(aliceAlloc, _proof(bobLeaf));

        vm.warp(claim_.claimDeadline());
        uint256 remaining = k613.balanceOf(address(claim_));
        assertEq(remaining, bobAlloc, "remaining K613 = bob's unclaimed alloc");

        claim_.recoverUnclaimedK613(treasury, remaining);
        assertEq(k613.balanceOf(treasury), remaining);
        assertEq(k613.balanceOf(address(claim_)), 0);
    }

    /// @notice testRecoverByNonAdminReverts: only DEFAULT_ADMIN_ROLE may recover.
    function testRecoverByNonAdminReverts() public {
        vm.warp(claim_.claimDeadline());

        bytes32 adminRole = claim_.DEFAULT_ADMIN_ROLE();
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole);

        vm.prank(alice);
        vm.expectRevert(expected);
        claim_.recoverUnclaimedK613(treasury, 1);
    }

    /// @notice testRecoverToZeroReverts: zero address target → ZeroAddress.
    function testRecoverToZeroReverts() public {
        vm.warp(claim_.claimDeadline());
        vm.expectRevert(K613SeasonClaim.ZeroAddress.selector);
        claim_.recoverUnclaimedK613(address(0), 1);
    }

    // ---------- pause ----------

    /// @notice testPauseOnlyByPauser: non-PAUSER cannot pause.
    function testPauseOnlyByPauser() public {
        bytes32 pauserRole = claim_.PAUSER_ROLE();
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pauserRole);

        vm.prank(alice);
        vm.expectRevert(expected);
        claim_.pause();
    }

    /// @notice testUnpauseRestoresClaim: unpause → claim resumes normally.
    function testUnpauseRestoresClaim() public {
        claim_.pause();
        claim_.unpause();

        vm.warp(tgeTimestamp);
        vm.prank(alice);
        claim_.claim(aliceAlloc, _proof(bobLeaf));
        assertEq(claim_.claimed(alice), aliceAlloc * 2_000 / 10_000);
    }
}
