// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";

contract K613Test is Test {
    K613 private token;

    address private owner = address(this);
    address private minter = address(0xBEEF);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    function setUp() public {
        token = new K613(minter);
    }

    function testConstructorSetsMinter() public view {
        assertEq(token.minter(), minter);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), owner));
    }

    function testSetMinterOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setMinter(alice);

        token.setMinter(alice);
        assertEq(token.minter(), alice);
    }

    function testSetMinterRejectsZero() public {
        vm.expectRevert(K613.ZeroAddress.selector);
        token.setMinter(address(0));
    }

    function testMintOnlyMinter() public {
        vm.prank(alice);
        vm.expectRevert(K613.OnlyMinter.selector);
        token.mint(alice, 1e18);

        vm.prank(minter);
        token.mint(alice, 2e18);
        assertEq(token.balanceOf(alice), 2e18);
        assertEq(token.totalSupply(), 2e18);
    }

    function testBurnOnlyMinter() public {
        vm.prank(minter);
        token.mint(alice, 3e18);

        vm.prank(alice);
        vm.expectRevert(K613.OnlyMinter.selector);
        token.burnFrom(alice, 1e18);

        vm.prank(minter);
        token.burnFrom(alice, 1e18);
        assertEq(token.balanceOf(alice), 2e18);
        assertEq(token.totalSupply(), 2e18);
    }

    function testTransfer_PauseBlocks() public {
        vm.prank(minter);
        token.mint(alice, 2e18);
        token.pause();
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1e18);
    }
}
