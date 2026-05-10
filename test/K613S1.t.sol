// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613S1} from "../src/token/K613S1.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

contract K613S1Test is Test {
    K613S1 private token;

    address private admin = address(this);
    address private minter = address(0xA1);
    address private burner = address(0xB2);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        token = new K613S1();
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.BURNER_ROLE(), burner);
    }

    /// @notice testMetadata: name, symbol, decimals match spec (18 decimals for parity with K613).
    function testMetadata() public view {
        assertEq(token.name(), "K613 Season 1 Points");
        assertEq(token.symbol(), "K613S1");
        assertEq(token.decimals(), 18);
    }

    /// @notice testConstructorRoles: deployer has DEFAULT_ADMIN_ROLE and PAUSER_ROLE; MINTER and BURNER are not granted by constructor.
    function testConstructorRoles() public {
        K613S1 fresh = new K613S1();
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(fresh.hasRole(fresh.PAUSER_ROLE(), address(this)));
        assertFalse(fresh.hasRole(fresh.MINTER_ROLE(), address(this)));
        assertFalse(fresh.hasRole(fresh.BURNER_ROLE(), address(this)));
    }

    /// @notice testMintByMinter: holder of MINTER_ROLE mints to arbitrary address.
    function testMintByMinter() public {
        vm.prank(minter);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    /// @notice testMintByNonMinterReverts: non-minter calling mint reverts with OnlyMinter.
    function testMintByNonMinterReverts() public {
        vm.prank(alice);
        vm.expectRevert(K613S1.OnlyMinter.selector);
        token.mint(alice, 1e18);
    }

    /// @notice testBurnByBurner: holder of BURNER_ROLE burns from arbitrary address without allowance.
    function testBurnByBurner() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(burner);
        token.burnFrom(alice, 30e18);

        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.totalSupply(), 70e18);
    }

    /// @notice testBurnByNonBurnerReverts: non-burner calling burnFrom reverts with OnlyBurner.
    function testBurnByNonBurnerReverts() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(K613S1.OnlyBurner.selector);
        token.burnFrom(alice, 1e18);
    }

    /// @notice testTransferReverts: transfer between non-zero addresses reverts with NonTransferable.
    function testTransferReverts() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(K613S1.NonTransferable.selector);
        token.transfer(bob, 1e18);
    }

    /// @notice testTransferFromReverts: transferFrom between non-zero addresses reverts with NonTransferable (transfer path).
    function testTransferFromReverts() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert(K613S1.NonTransferable.selector);
        token.transferFrom(alice, bob, 1e18);
    }

    /// @notice testApproveReverts: approve reverts with NonTransferable; allowances are not supported.
    function testApproveReverts() public {
        vm.prank(alice);
        vm.expectRevert(K613S1.NonTransferable.selector);
        token.approve(bob, 1e18);
    }

    /// @notice testPauseBlocksMintAndBurn: when paused, mint and burn revert with EnforcedPause.
    function testPauseBlocksMintAndBurn() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        token.pause();

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.mint(alice, 1e18);

        vm.prank(burner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.burnFrom(alice, 1e18);

        token.unpause();

        vm.prank(minter);
        token.mint(alice, 1e18);
        assertEq(token.balanceOf(alice), 101e18);
    }

    /// @notice testPauseOnlyByPauser: non-PAUSER cannot pause.
    function testPauseOnlyByPauser() public {
        bytes32 pauserRole = token.PAUSER_ROLE();
        bytes memory expectedRevert =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pauserRole);

        vm.prank(alice);
        vm.expectRevert(expectedRevert);
        token.pause();
    }

    /// @notice testRoleRotation: admin can revoke a granted role; the revoked address loses access.
    function testRoleRotation() public {
        token.revokeRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(K613S1.OnlyMinter.selector);
        token.mint(alice, 1e18);

        address newMinter = address(0xCAFE);
        token.grantRole(token.MINTER_ROLE(), newMinter);

        vm.prank(newMinter);
        token.mint(alice, 5e18);
        assertEq(token.balanceOf(alice), 5e18);
    }
}
