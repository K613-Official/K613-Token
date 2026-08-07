// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {K613LpTimelock} from "../src/pol/K613LpTimelock.sol";

/// @dev Stand-in for the Uniswap v3 NonfungiblePositionManager. Implements only what the timelock
///      calls, plus a `decreaseLiquidity` that records whether it was ever reached — the point being
///      that the timelock exposes no path to it.
contract MockPositionManager is ERC721 {
    uint256 public collectCalls;
    address public lastCollectRecipient;
    uint128 public feesOwed0;
    uint128 public feesOwed1;

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    constructor() ERC721("MockNPM", "MNPM") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function setFeesOwed(uint128 a0, uint128 a1) external {
        feesOwed0 = a0;
        feesOwed1 = a1;
    }

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1) {
        require(ownerOf(params.tokenId) == msg.sender, "not owner");
        collectCalls++;
        lastCollectRecipient = params.recipient;
        amount0 = feesOwed0;
        amount1 = feesOwed1;
        feesOwed0 = 0;
        feesOwed1 = 0;
    }
}

/// @title K613LpTimelockTest
/// @notice The timelock carries the protocol's on-chain no-rug promise: while it holds the LP NFT,
///         liquidity cannot be pulled. That promise had no tests at all. These pin the three things
///         it rests on — the NFT cannot leave before `unlockTime`, only the beneficiary can touch
///         anything, and fee collection never reaches principal.
contract K613LpTimelockTest is Test {
    K613LpTimelock private timelock;
    MockPositionManager private npm;

    address private beneficiary = address(0xBEEF);
    address private stranger = address(0xBAD);
    uint256 private constant TOKEN_ID = 44252;
    uint256 private constant LOCK = 365 days;

    function setUp() public {
        npm = new MockPositionManager();
        timelock = new K613LpTimelock(address(npm), beneficiary, LOCK);
        npm.mint(address(this), TOKEN_ID);
        npm.safeTransferFrom(address(this), address(timelock), TOKEN_ID);
    }

    function test_Constructor_RejectsZeroAddressesAndZeroDuration() public {
        vm.expectRevert(K613LpTimelock.ZeroAddress.selector);
        new K613LpTimelock(address(0), beneficiary, LOCK);

        vm.expectRevert(K613LpTimelock.ZeroAddress.selector);
        new K613LpTimelock(address(npm), address(0), LOCK);

        vm.expectRevert(K613LpTimelock.ZeroDuration.selector);
        new K613LpTimelock(address(npm), beneficiary, 0);
    }

    function test_Constructor_AnchorsUnlockToDeployment() public view {
        assertEq(timelock.unlockTime(), block.timestamp + LOCK);
        assertEq(timelock.beneficiary(), beneficiary);
        assertEq(timelock.npm(), address(npm));
    }

    function test_HoldsTheNft() public view {
        assertEq(npm.ownerOf(TOKEN_ID), address(timelock));
    }

    /// @notice The promise itself: not one second early, not by anyone.
    function test_Withdraw_RevertsBeforeUnlock() public {
        // Cached deliberately: reading it after `vm.prank` would consume the prank on that external
        // call instead of on `withdraw`, and the test would pass on the wrong revert.
        uint256 unlockAt = timelock.unlockTime();
        vm.warp(unlockAt - 1);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(K613LpTimelock.StillLocked.selector, unlockAt));
        timelock.withdraw(TOKEN_ID);

        assertEq(npm.ownerOf(TOKEN_ID), address(timelock), "NFT must not move");
    }

    function test_Withdraw_SucceedsExactlyAtUnlock() public {
        vm.warp(timelock.unlockTime());
        vm.prank(beneficiary);
        timelock.withdraw(TOKEN_ID);
        assertEq(npm.ownerOf(TOKEN_ID), beneficiary);
    }

    function test_Withdraw_OnlyBeneficiaryEvenAfterUnlock() public {
        vm.warp(timelock.unlockTime());
        vm.prank(stranger);
        vm.expectRevert(K613LpTimelock.NotBeneficiary.selector);
        timelock.withdraw(TOKEN_ID);
    }

    function test_CollectFees_OnlyBeneficiary() public {
        vm.prank(stranger);
        vm.expectRevert(K613LpTimelock.NotBeneficiary.selector);
        timelock.collectFees(TOKEN_ID);
    }

    /// @notice Fees must be reachable during the lock — otherwise a year of trading revenue is
    ///         frozen along with the principal.
    function test_CollectFees_WorksWhileLockedAndPaysBeneficiary() public {
        npm.setFeesOwed(111, 222);

        vm.warp(timelock.unlockTime() - 1);
        vm.prank(beneficiary);
        (uint256 a0, uint256 a1) = timelock.collectFees(TOKEN_ID);

        assertEq(a0, 111);
        assertEq(a1, 222);
        assertEq(npm.lastCollectRecipient(), beneficiary, "fees go straight to the Safe");
        assertEq(npm.ownerOf(TOKEN_ID), address(timelock), "collecting must not move the NFT");
    }

    /// @notice The structural guarantee, stated as a test: the contract's whole ABI is three
    ///         functions, none of which can reduce liquidity. A future edit that adds a
    ///         `decreaseLiquidity` passthrough breaks this.
    function test_NoLiquidityWithdrawalPathExists() public {
        vm.warp(timelock.unlockTime() - 1);
        vm.prank(beneficiary);
        (bool ok,) = address(timelock).call(abi.encodeWithSignature("decreaseLiquidity(uint256,uint128)", TOKEN_ID, 1));
        assertFalse(ok, "timelock must expose no liquidity-reducing entrypoint");
    }

    /// @notice The timelock must not become a parking lot for arbitrary NFTs: only the configured
    ///         position manager may deposit.
    function test_OnERC721Received_RejectsForeignCollections() public {
        MockPositionManager other = new MockPositionManager();
        other.mint(address(this), 1);
        vm.expectRevert();
        other.safeTransferFrom(address(this), address(timelock), 1);
    }

    /// @notice Multiple positions share the one `unlockTime`, as documented.
    function test_SecondPosition_SharesTheSameUnlock() public {
        npm.mint(address(this), 99);
        npm.safeTransferFrom(address(this), address(timelock), 99);

        uint256 unlockAt = timelock.unlockTime();
        vm.warp(unlockAt - 1);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(K613LpTimelock.StillLocked.selector, unlockAt));
        timelock.withdraw(99);

        vm.warp(unlockAt);
        vm.startPrank(beneficiary);
        timelock.withdraw(99);
        timelock.withdraw(TOKEN_ID);
        vm.stopPrank();

        assertEq(npm.ownerOf(99), beneficiary);
        assertEq(npm.ownerOf(TOKEN_ID), beneficiary);
    }
}
