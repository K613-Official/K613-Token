// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613S1} from "../src/token/K613S1.sol";
import {K613S1Distributor} from "../src/campaign/K613S1Distributor.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

contract K613S1DistributorTest is Test {
    K613S1 private k613s1;
    K613S1Distributor private distributor;

    address private admin = address(this);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCAFE);

    uint256 private constant INITIAL_CAP = 5_000_000e18;

    function setUp() public {
        k613s1 = new K613S1();
        distributor = new K613S1Distributor(address(k613s1), INITIAL_CAP);
        k613s1.grantRole(k613s1.MINTER_ROLE(), address(distributor));
    }

    // ---------- helpers ----------

    /// @dev OZ StandardMerkleTree leaf format: double-hashed `abi.encode(account, amount)`.
    function _hashLeaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    /// @dev OZ MerkleProof sorted-pair hashing.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory) {
        bytes32[] memory p = new bytes32[](1);
        p[0] = sibling;
        return p;
    }

    // ---------- constructor ----------

    /// @notice testConstructorZeroAddressReverts: zero K613S1 address reverts with ZeroAddress.
    function testConstructorZeroAddressReverts() public {
        vm.expectRevert(K613S1Distributor.ZeroAddress.selector);
        new K613S1Distributor(address(0), INITIAL_CAP);
    }

    /// @notice testConstructorCapAboveMaxReverts: initial cap > MAX_WEEKLY_MINT_CAP reverts with CapExceedsMaximum.
    function testConstructorCapAboveMaxReverts() public {
        uint256 maxCap = distributor.MAX_WEEKLY_MINT_CAP();
        vm.expectRevert(K613S1Distributor.CapExceedsMaximum.selector);
        new K613S1Distributor(address(k613s1), maxCap + 1);
    }

    /// @notice testConstructorAtMaxCapBoundary: initial cap == MAX_WEEKLY_MINT_CAP is accepted.
    function testConstructorAtMaxCapBoundary() public {
        uint256 maxCap = distributor.MAX_WEEKLY_MINT_CAP();
        K613S1Distributor d = new K613S1Distributor(address(k613s1), maxCap);
        assertEq(d.weeklyMintCap(), maxCap);
    }

    /// @notice testConstructorRoles: deployer holds DEFAULT_ADMIN_ROLE, PAUSER_ROLE, OPERATOR_ROLE; immutables set; initial cap stored.
    function testConstructorRoles() public view {
        assertTrue(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(distributor.hasRole(distributor.PAUSER_ROLE(), admin));
        assertTrue(distributor.hasRole(distributor.OPERATOR_ROLE(), admin));
        assertEq(address(distributor.k613s1()), address(k613s1));
        assertEq(distributor.weeklyMintCap(), INITIAL_CAP);
        assertEq(distributor.lastRootCumulativeSupply(), 0);
        assertEq(distributor.merkleRoot(), bytes32(0));
    }

    // ---------- claim happy path ----------

    /// @notice testClaimWithValidProof: 2-leaf tree, alice proves her allocation and receives the full amount in K613S1.
    function testClaimWithValidProof() public {
        uint256 aliceAmt = 100e18;
        uint256 bobAmt = 200e18;
        bytes32 aliceLeaf = _hashLeaf(alice, aliceAmt);
        bytes32 bobLeaf = _hashLeaf(bob, bobAmt);
        bytes32 root = _hashPair(aliceLeaf, bobLeaf);

        distributor.setMerkleRoot(root, aliceAmt + bobAmt, 1);

        vm.prank(alice);
        distributor.claim(aliceAmt, _proof(bobLeaf));

        assertEq(k613s1.balanceOf(alice), aliceAmt);
        assertEq(distributor.claimed(alice), aliceAmt);
    }

    /// @notice testClaimAfterRootUpdate: week 2 root contains a higher cumulative for alice; she claims the delta only.
    function testClaimAfterRootUpdate() public {
        // Week 1: alice 100, bob 50.
        bytes32 a1 = _hashLeaf(alice, 100e18);
        bytes32 b1 = _hashLeaf(bob, 50e18);
        distributor.setMerkleRoot(_hashPair(a1, b1), 150e18, 1);

        vm.prank(alice);
        distributor.claim(100e18, _proof(b1));
        assertEq(k613s1.balanceOf(alice), 100e18);

        // Week 2: alice 250 (cumulative), bob 80 (cumulative).
        bytes32 a2 = _hashLeaf(alice, 250e18);
        bytes32 b2 = _hashLeaf(bob, 80e18);
        distributor.setMerkleRoot(_hashPair(a2, b2), 330e18, 2);

        vm.prank(alice);
        distributor.claim(250e18, _proof(b2));
        assertEq(k613s1.balanceOf(alice), 250e18, "alice should have full cumulative balance");
        assertEq(distributor.claimed(alice), 250e18);
    }

    // ---------- claim revert paths ----------

    /// @notice testClaimDuplicateReverts: claiming the same cumulative twice reverts with NothingToClaim.
    function testClaimDuplicateReverts() public {
        bytes32 aliceLeaf = _hashLeaf(alice, 100e18);
        bytes32 bobLeaf = _hashLeaf(bob, 200e18);
        distributor.setMerkleRoot(_hashPair(aliceLeaf, bobLeaf), 300e18, 1);

        vm.prank(alice);
        distributor.claim(100e18, _proof(bobLeaf));

        vm.prank(alice);
        vm.expectRevert(K613S1Distributor.NothingToClaim.selector);
        distributor.claim(100e18, _proof(bobLeaf));
    }

    /// @notice testClaimOldProofAgainstNewRootReverts: a proof valid under root1 fails against root2 with InvalidProof.
    function testClaimOldProofAgainstNewRootReverts() public {
        // Week 1.
        bytes32 a1 = _hashLeaf(alice, 100e18);
        bytes32 b1 = _hashLeaf(bob, 200e18);
        distributor.setMerkleRoot(_hashPair(a1, b1), 300e18, 1);

        // Week 2 — alice not in this root.
        bytes32 c2 = _hashLeaf(carol, 50e18);
        bytes32 b2 = _hashLeaf(bob, 250e18);
        distributor.setMerkleRoot(_hashPair(c2, b2), 300e18, 2);

        // Alice's old proof must fail.
        vm.prank(alice);
        vm.expectRevert(K613S1Distributor.InvalidProof.selector);
        distributor.claim(100e18, _proof(b1));
    }

    /// @notice testClaimWithWrongAmountReverts: same account, wrong amount → InvalidProof.
    function testClaimWithWrongAmountReverts() public {
        bytes32 aliceLeaf = _hashLeaf(alice, 100e18);
        bytes32 bobLeaf = _hashLeaf(bob, 200e18);
        distributor.setMerkleRoot(_hashPair(aliceLeaf, bobLeaf), 300e18, 1);

        vm.prank(alice);
        vm.expectRevert(K613S1Distributor.InvalidProof.selector);
        distributor.claim(101e18, _proof(bobLeaf));
    }

    // ---------- setMerkleRoot ----------

    /// @notice testEmptyMerkleRootReverts: posting bytes32(0) as root reverts with EmptyMerkleRoot.
    function testEmptyMerkleRootReverts() public {
        vm.expectRevert(K613S1Distributor.EmptyMerkleRoot.selector);
        distributor.setMerkleRoot(bytes32(0), 0, 1);
    }

    /// @notice testSetMerkleRootByNonOperatorReverts: AccessControl revert.
    function testSetMerkleRootByNonOperatorReverts() public {
        bytes32 operatorRole = distributor.OPERATOR_ROLE();
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, operatorRole);

        vm.prank(alice);
        vm.expectRevert(expected);
        distributor.setMerkleRoot(bytes32(uint256(1)), 0, 1);
    }

    /// @notice testNonMonotonicSupplyReverts: newCumulativeSupply < lastRootCumulativeSupply → revert.
    function testNonMonotonicSupplyReverts() public {
        distributor.setMerkleRoot(bytes32(uint256(1)), 100e18, 1);

        vm.expectRevert(K613S1Distributor.NonMonotonicSupply.selector);
        distributor.setMerkleRoot(bytes32(uint256(2)), 99e18, 2);
    }

    /// @notice testCapExceededReverts: increase > weeklyMintCap → revert.
    function testCapExceededReverts() public {
        // First call sets baseline at INITIAL_CAP (delta == cap, ok).
        distributor.setMerkleRoot(bytes32(uint256(1)), INITIAL_CAP, 1);

        // Second call: delta = 1 wei beyond cap → revert.
        vm.expectRevert(K613S1Distributor.WeeklyCapExceeded.selector);
        distributor.setMerkleRoot(bytes32(uint256(2)), INITIAL_CAP + INITIAL_CAP + 1, 2);
    }

    /// @notice testCapBoundary: delta exactly equal to weeklyMintCap is accepted.
    function testCapBoundary() public {
        distributor.setMerkleRoot(bytes32(uint256(1)), INITIAL_CAP, 1);
        distributor.setMerkleRoot(bytes32(uint256(2)), INITIAL_CAP * 2, 2);
        assertEq(distributor.lastRootCumulativeSupply(), INITIAL_CAP * 2);
    }

    /// @notice testSetMerkleRootEmitsEvent: MerkleRootUpdated event is emitted.
    function testSetMerkleRootEmitsEvent() public {
        bytes32 root = bytes32(uint256(0xdeadbeef));
        vm.expectEmit(true, false, false, true);
        emit K613S1Distributor.MerkleRootUpdated(root, 1_000e18, 7);
        distributor.setMerkleRoot(root, 1_000e18, 7);
    }

    // ---------- setWeeklyMintCap ----------

    /// @notice testSetWeeklyMintCapByAdmin: admin updates cap, event fires.
    function testSetWeeklyMintCapByAdmin() public {
        vm.expectEmit(false, false, false, true);
        emit K613S1Distributor.WeeklyMintCapSet(7_000_000e18);
        distributor.setWeeklyMintCap(7_000_000e18);
        assertEq(distributor.weeklyMintCap(), 7_000_000e18);
    }

    /// @notice testSetWeeklyMintCapAboveMaxReverts: admin cannot raise cap above MAX_WEEKLY_MINT_CAP.
    function testSetWeeklyMintCapAboveMaxReverts() public {
        uint256 maxCap = distributor.MAX_WEEKLY_MINT_CAP();
        vm.expectRevert(K613S1Distributor.CapExceedsMaximum.selector);
        distributor.setWeeklyMintCap(maxCap + 1);
    }

    /// @notice testSetWeeklyMintCapAtMaxBoundary: setting cap to exactly MAX is accepted.
    function testSetWeeklyMintCapAtMaxBoundary() public {
        uint256 maxCap = distributor.MAX_WEEKLY_MINT_CAP();
        distributor.setWeeklyMintCap(maxCap);
        assertEq(distributor.weeklyMintCap(), maxCap);
    }

    /// @notice testSetWeeklyMintCapByNonAdminReverts: non-admin call reverts.
    function testSetWeeklyMintCapByNonAdminReverts() public {
        bytes32 adminRole = distributor.DEFAULT_ADMIN_ROLE();
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole);

        vm.prank(alice);
        vm.expectRevert(expected);
        distributor.setWeeklyMintCap(7_000_000e18);
    }

    // ---------- pause ----------

    /// @notice testPauseBlocksClaim: paused state reverts claim with EnforcedPause.
    function testPauseBlocksClaim() public {
        bytes32 aliceLeaf = _hashLeaf(alice, 100e18);
        bytes32 bobLeaf = _hashLeaf(bob, 200e18);
        distributor.setMerkleRoot(_hashPair(aliceLeaf, bobLeaf), 300e18, 1);

        distributor.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.claim(100e18, _proof(bobLeaf));
    }

    /// @notice testPauseBlocksSetMerkleRoot: paused state reverts setMerkleRoot.
    function testPauseBlocksSetMerkleRoot() public {
        distributor.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        distributor.setMerkleRoot(bytes32(uint256(1)), 1e18, 1);
    }

    /// @notice testUnpauseRestoresClaim: unpause restores normal flow.
    function testUnpauseRestoresClaim() public {
        bytes32 aliceLeaf = _hashLeaf(alice, 100e18);
        bytes32 bobLeaf = _hashLeaf(bob, 200e18);
        distributor.setMerkleRoot(_hashPair(aliceLeaf, bobLeaf), 300e18, 1);

        distributor.pause();
        distributor.unpause();

        vm.prank(alice);
        distributor.claim(100e18, _proof(bobLeaf));
        assertEq(k613s1.balanceOf(alice), 100e18);
    }

    // ---------- operator rotation ----------

    /// @notice testOperatorRotation: revoke EOA, grant new operator, old operator can no longer post; new one can.
    function testOperatorRotation() public {
        address newOperator = address(0xBEEF);
        bytes32 operatorRole = distributor.OPERATOR_ROLE();

        distributor.revokeRole(operatorRole, admin);
        distributor.grantRole(operatorRole, newOperator);

        // Old operator (admin in this test) cannot post (admin still holds DEFAULT_ADMIN but not OPERATOR).
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, operatorRole);
        vm.expectRevert(expected);
        distributor.setMerkleRoot(bytes32(uint256(1)), 1e18, 1);

        // New operator can post.
        vm.prank(newOperator);
        distributor.setMerkleRoot(bytes32(uint256(1)), 1e18, 1);
        assertEq(distributor.lastRootCumulativeSupply(), 1e18);
    }
}
