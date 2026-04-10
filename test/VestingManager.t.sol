// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";
import {K613VestingManager} from "../src/vesting/K613VestingManager.sol";
import {K613VestingWallet} from "../src/vesting/K613VestingWallet.sol";

contract VestingManagerTest is Test {
    uint256 private constant ONE = 1e18;

    K613 private token;
    K613VestingManager private manager;

    address private admin = address(this);
    address private beneficiary = address(0xBEEF);

    function setUp() public {
        token = new K613(admin);
        manager = new K613VestingManager(admin, address(token));
        token.mint(admin, 10_000 * ONE);
        token.approve(address(manager), type(uint256).max);
    }

    /// @notice testCreateVestingWalletAndReleaseAfterCliff: creates wallet, tracks record, and releases after cliff.
    function testCreateVestingWalletAndReleaseAfterCliff() public {
        uint64 start = uint64(block.timestamp + 7 days);
        uint64 duration = 180 days;
        uint64 cliff = 30 days;
        uint256 amount = 1_000 * ONE;

        address walletAddress = manager.createVestingWallet(beneficiary, start, duration, cliff, amount);
        K613VestingWallet wallet = K613VestingWallet(payable(walletAddress));

        assertEq(token.balanceOf(walletAddress), amount);
        assertEq(wallet.owner(), beneficiary);
        assertEq(wallet.start(), start);
        assertEq(wallet.duration(), duration);
        assertEq(wallet.cliff(), start + cliff);
        assertEq(manager.isManagedWallet(walletAddress), true);
        assertEq(manager.totalWallets(), 1);
        assertEq(manager.getWalletAt(0), walletAddress);

        K613VestingManager.VestingRecord memory record = manager.getVestingRecord(walletAddress);
        assertEq(record.beneficiary, beneficiary);
        assertEq(record.vestingWallet, walletAddress);
        assertEq(record.startTimestamp, start);
        assertEq(record.durationSeconds, duration);
        assertEq(record.cliffSeconds, cliff);
        assertEq(record.initialAmount, amount);
        assertEq(record.totalFunded, amount);
        assertEq(record.createdAt, block.timestamp);

        vm.warp(start + cliff - 1);
        assertEq(wallet.releasable(address(token)), 0);

        vm.warp(start + cliff + 30 days);
        uint256 releasable = wallet.releasable(address(token));
        assertGt(releasable, 0);

        vm.prank(beneficiary);
        wallet.release(address(token));

        assertEq(token.balanceOf(beneficiary), releasable);
    }

    /// @notice testFundExistingVestingWallet: extra funding updates wallet balance and totalFunded.
    function testFundExistingVestingWallet() public {
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 duration = 90 days;
        uint64 cliff = 15 days;
        uint256 initialAmount = 100 * ONE;
        uint256 extraAmount = 50 * ONE;

        address walletAddress = manager.createVestingWallet(beneficiary, start, duration, cliff, initialAmount);
        manager.fundVestingWallet(walletAddress, extraAmount);

        assertEq(token.balanceOf(walletAddress), initialAmount + extraAmount);
        K613VestingManager.VestingRecord memory record = manager.getVestingRecord(walletAddress);
        assertEq(record.totalFunded, initialAmount + extraAmount);
    }

    /// @notice testMultipleVestingsForSameBeneficiary: beneficiary wallet list and pagination reflect creation order.
    function testMultipleVestingsForSameBeneficiary() public {
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 duration = 60 days;
        uint64 cliff = 10 days;

        address w1 = manager.createVestingWallet(beneficiary, start, duration, cliff, 100 * ONE);
        address w2 = manager.createVestingWallet(beneficiary, start + 1, duration, cliff, 200 * ONE);

        assertTrue(w1 != w2);
        address[] memory list = manager.getWalletsByBeneficiary(beneficiary);
        assertEq(list.length, 2);
        assertEq(list[0], w1);
        assertEq(list[1], w2);

        address[] memory allWallets = manager.getAllWallets();
        assertEq(allWallets.length, 2);
        assertEq(allWallets[0], w1);
        assertEq(allWallets[1], w2);

        address[] memory sliceA = manager.getWalletsSlice(0, 1);
        assertEq(sliceA.length, 1);
        assertEq(sliceA[0], w1);

        address[] memory sliceB = manager.getWalletsSlice(1, 10);
        assertEq(sliceB.length, 1);
        assertEq(sliceB[0], w2);
    }

    /// @notice testFundUnknownWalletReverts: funding unmanaged wallet reverts with WalletNotManaged.
    function testFundUnknownWalletReverts() public {
        vm.expectRevert(K613VestingManager.WalletNotManaged.selector);
        manager.fundVestingWallet(address(0x1234), ONE);
    }

    /// @notice testConstructorZeroAddressReverts: constructor rejects zero owner or zero token.
    function testConstructorZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new K613VestingManager(address(0), address(token));

        vm.expectRevert(K613VestingManager.ZeroAddress.selector);
        new K613VestingManager(admin, address(0));
    }

    /// @notice testCreateVestingWalletOnlyOwnerAndInputValidation: only owner can create; zero beneficiary and zero amount revert.
    function testCreateVestingWalletOnlyOwnerAndInputValidation() public {
        vm.prank(beneficiary);
        vm.expectRevert();
        manager.createVestingWallet(beneficiary, uint64(block.timestamp), 1 days, 1 days, ONE);

        vm.expectRevert(K613VestingManager.ZeroAddress.selector);
        manager.createVestingWallet(address(0), uint64(block.timestamp), 1 days, 1 days, ONE);

        vm.expectRevert(K613VestingManager.ZeroAmount.selector);
        manager.createVestingWallet(beneficiary, uint64(block.timestamp), 1 days, 1 days, 0);
    }

    /// @notice testFundVestingWalletOnlyOwnerAndInputValidation: only owner can fund; zero wallet and zero amount revert.
    function testFundVestingWalletOnlyOwnerAndInputValidation() public {
        address walletAddress =
            manager.createVestingWallet(beneficiary, uint64(block.timestamp), 30 days, 5 days, 10 * ONE);

        vm.prank(beneficiary);
        vm.expectRevert();
        manager.fundVestingWallet(walletAddress, ONE);

        vm.expectRevert(K613VestingManager.ZeroAddress.selector);
        manager.fundVestingWallet(address(0), ONE);

        vm.expectRevert(K613VestingManager.ZeroAmount.selector);
        manager.fundVestingWallet(walletAddress, 0);
    }

    /// @notice testGetWalletsSliceEdgeCases: slice handles zero limit, out-of-range offset, and oversize limit.
    function testGetWalletsSliceEdgeCases() public {
        address w1 = manager.createVestingWallet(beneficiary, uint64(block.timestamp), 30 days, 5 days, 10 * ONE);
        address w2 = manager.createVestingWallet(beneficiary, uint64(block.timestamp + 1), 30 days, 5 days, 20 * ONE);

        address[] memory emptyByLimit = manager.getWalletsSlice(0, 0);
        assertEq(emptyByLimit.length, 0);

        address[] memory emptyByOffset = manager.getWalletsSlice(2, 1);
        assertEq(emptyByOffset.length, 0);

        address[] memory full = manager.getWalletsSlice(0, 10);
        assertEq(full.length, 2);
        assertEq(full[0], w1);
        assertEq(full[1], w2);
    }

    /// @notice testUnknownRecordIsZeroed: unknown wallet returns zeroed vesting record.
    function testUnknownRecordIsZeroed() public view {
        K613VestingManager.VestingRecord memory record = manager.getVestingRecord(address(0x9999));
        assertEq(record.beneficiary, address(0));
        assertEq(record.vestingWallet, address(0));
        assertEq(record.startTimestamp, 0);
        assertEq(record.durationSeconds, 0);
        assertEq(record.cliffSeconds, 0);
        assertEq(record.initialAmount, 0);
        assertEq(record.totalFunded, 0);
        assertEq(record.createdAt, 0);
    }
}
