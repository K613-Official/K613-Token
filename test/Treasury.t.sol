// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Staking} from "../src/staking/Staking.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {IV3SwapRouter} from "swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "M") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockV3Router02 {
    K613 public k613;
    IERC20 public tokenInErc;
    bool public shouldFail;
    uint256 public outAmount;

    constructor(address _k613, address _tokenIn) {
        k613 = K613(_k613);
        tokenInErc = IERC20(_tokenIn);
        outAmount = 1e18;
    }

    function setShouldFail(bool v) external {
        shouldFail = v;
    }

    function setOutAmount(uint256 v) external {
        outAmount = v;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        if (shouldFail) revert("v3 swap failed");
        tokenInErc.transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = outAmount;
        k613.transfer(p.recipient, amountOut);
    }
}

contract TreasuryTest is Test {
    uint256 private constant ONE = 1e18;
    uint256 private constant EPOCH = 7 days;

    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;
    Treasury private treasury;

    address private alice = address(0xA11CE);
    uint24 private constant POOL_FEE = 3000;

    function setUp() public {
        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new Staking(address(k613), address(xk613), 7 days, 0);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH);
        treasury = new Treasury(address(k613), address(xk613), address(staking), address(distributor));

        xk613.setMinter(address(staking));
        xk613.grantRole(xk613.MINTER_ROLE(), address(this));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(treasury), true);
        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));
        k613.mint(address(treasury), 1000 * ONE);
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury));
    }

    /// @notice testDepositRewards_OnlyAdmin: depositRewards from non-admin reverts.
    function testDepositRewards_OnlyAdmin() public {
        k613.mint(alice, 100 * ONE);
        vm.prank(alice);
        k613.approve(address(treasury), 100 * ONE);
        vm.prank(alice);
        vm.expectRevert();
        treasury.depositRewards(100 * ONE);
    }

    /// @notice Only DEFAULT_ADMIN_ROLE can call buybackV3; non-admin call reverts.
    function testBuybackV3_OnlyAdmin() public {
        MockToken other = new MockToken();
        other.mint(address(treasury), ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        k613.mint(address(router), 100 * ONE);
        treasury.setRouterWhitelist(address(router), true);
        vm.prank(alice);
        vm.expectRevert();
        treasury.buybackV3ExactInputSingle(address(other), address(router), 1, 0, POOL_FEE, false);
    }

    /// @notice testDepositRewards_ZeroNoop: depositRewards(0) is a no-op; accRewardPerShare unchanged.
    function testDepositRewards_ZeroNoop() public {
        uint256 rdBefore = distributor.accRewardPerShare();
        treasury.depositRewards(0);
        assertEq(distributor.accRewardPerShare(), rdBefore);
    }

    /// @notice testDepositRewards_Success: depositRewards stakes K613 and sends xK613 to RD; distributor balance increases.
    function testDepositRewards_Success() public {
        k613.mint(address(this), 100 * ONE);
        k613.approve(address(treasury), 100 * ONE);
        treasury.depositRewards(100 * ONE);
        assertEq(xk613.balanceOf(address(distributor)), 100 * ONE);
    }

    /// @notice testWithdraw_OnlyAdmin: withdraw from non-admin reverts.
    function testWithdraw_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.withdraw(address(k613), alice, 100 * ONE);
    }

    /// @notice testApproveXk613PullRewards_OnlyAdmin: only admin can set xK613 pull allowance.
    function testApproveXk613PullRewards_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.approveXk613PullRewards(address(0xBEEF), type(uint256).max);
    }

    /// @notice testApproveXk613PullRewards_ZeroSpenderReverts: zero spender reverts with ZeroAddress.
    function testApproveXk613PullRewards_ZeroSpenderReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.approveXk613PullRewards(address(0), 1);
    }

    /// @notice testApproveXk613PullRewards_SuccessAndRevoke: allowance can be set to max and then revoked to zero.
    function testApproveXk613PullRewards_SuccessAndRevoke() public {
        address spender = address(0xBEEF);
        xk613.mint(address(treasury), 10 * ONE);
        vm.expectEmit(true, false, false, true);
        emit Treasury.Xk613PullAllowanceSet(spender, type(uint256).max);
        treasury.approveXk613PullRewards(spender, type(uint256).max);
        assertEq(xk613.allowance(address(treasury), spender), type(uint256).max);
        treasury.approveXk613PullRewards(spender, 0);
        assertEq(xk613.allowance(address(treasury), spender), 0);
    }

    /// @notice testWithdraw_ZeroAddressReverts: withdraw with token or to address zero reverts with ZeroAddress.
    function testWithdraw_ZeroAddressReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.withdraw(address(0), alice, 100 * ONE);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.withdraw(address(k613), address(0), 100 * ONE);
    }

    /// @notice testWithdraw_ZeroAmountReverts: withdraw(amount 0) reverts with ZeroAmount.
    function testWithdraw_ZeroAmountReverts() public {
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.withdraw(address(k613), alice, 0);
    }

    /// @notice testWithdraw_Success: Admin withdraw transfers token to recipient; balance updates.
    function testWithdraw_Success() public {
        uint256 bal = k613.balanceOf(address(treasury));
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.withdraw(address(k613), alice, 0);
        treasury.withdraw(address(k613), alice, bal);
        assertEq(k613.balanceOf(alice), bal);
    }

    /// @notice testBuybackV3_ZeroTokenInReverts: buyback reverts when tokenIn is zero.
    function testBuybackV3_ZeroTokenInReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.buybackV3ExactInputSingle(address(0), address(0x1), 1, 0, POOL_FEE, false);
    }

    /// @notice testBuybackV3_ZeroRouterReverts: buyback reverts when router is zero.
    function testBuybackV3_ZeroRouterReverts() public {
        MockToken other = new MockToken();
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.buybackV3ExactInputSingle(address(other), address(0), 1, 0, POOL_FEE, false);
    }

    /// @notice testBuybackV3_ZeroAmountReverts: buyback reverts when amountIn is zero.
    function testBuybackV3_ZeroAmountReverts() public {
        MockToken other = new MockToken();
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.buybackV3ExactInputSingle(address(other), address(0x1), 0, 0, POOL_FEE, false);
    }

    /// @notice testBuybackV3_TokenInIsK613Reverts: buyback rejects k613 as tokenIn.
    function testBuybackV3_TokenInIsK613Reverts() public {
        MockToken dummy = new MockToken();
        MockV3Router02 router = new MockV3Router02(address(k613), address(dummy));
        treasury.setRouterWhitelist(address(router), true);
        vm.expectRevert(Treasury.InsufficientOutput.selector);
        treasury.buybackV3ExactInputSingle(address(k613), address(router), 1, 1, POOL_FEE, false);
    }

    /// @notice testSetRouterWhitelist_OnlyAdmin: setRouterWhitelist from non-admin reverts.
    function testSetRouterWhitelist_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.setRouterWhitelist(address(0x1), true);
    }

    /// @notice testSetRouterWhitelist_ZeroAddressReverts: setRouterWhitelist(0) reverts with ZeroAddress.
    function testSetRouterWhitelist_ZeroAddressReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.setRouterWhitelist(address(0), true);
    }

    /// @notice testSetRouterWhitelist_SuccessAndBuybackV3: whitelisted router can execute buyback, removed router cannot.
    function testSetRouterWhitelist_SuccessAndBuybackV3() public {
        MockToken other = new MockToken();
        other.mint(address(treasury), 100 * ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        k613.mint(address(router), 100 * ONE);
        assertFalse(treasury.routerWhitelist(address(router)));
        vm.expectEmit(true, true, false, true);
        emit Treasury.RouterWhitelistUpdated(address(router), true);
        treasury.setRouterWhitelist(address(router), true);
        assertTrue(treasury.routerWhitelist(address(router)));
        treasury.buybackV3ExactInputSingle(address(other), address(router), 1, 1e18, POOL_FEE, false);

        treasury.setRouterWhitelist(address(router), false);
        assertFalse(treasury.routerWhitelist(address(router)));
        vm.expectRevert(Treasury.RouterNotWhitelisted.selector);
        treasury.buybackV3ExactInputSingle(address(other), address(router), 1, 0, POOL_FEE, false);
    }

    /// @notice testGetWhitelistedRouters: getWhitelistedRouters returns added routers and length decreases when one is removed.
    function testGetWhitelistedRouters() public {
        MockToken t = new MockToken();
        MockV3Router02 r1 = new MockV3Router02(address(k613), address(t));
        MockV3Router02 r2 = new MockV3Router02(address(k613), address(t));
        address[] memory empty = treasury.getWhitelistedRouters();
        assertEq(empty.length, 0);

        treasury.setRouterWhitelist(address(r1), true);
        address[] memory one = treasury.getWhitelistedRouters();
        assertEq(one.length, 1);
        assertEq(one[0], address(r1));

        treasury.setRouterWhitelist(address(r2), true);
        address[] memory two = treasury.getWhitelistedRouters();
        assertEq(two.length, 2);
        assertEq(two[0], address(r1));
        assertEq(two[1], address(r2));

        treasury.setRouterWhitelist(address(r1), false);
        address[] memory afterRemove = treasury.getWhitelistedRouters();
        assertEq(afterRemove.length, 1);
        assertEq(afterRemove[0], address(r2));
    }

    /// @notice testBuybackV3_InsufficientOutputReverts: buyback reverts when realized output is below minK613Out.
    function testBuybackV3_InsufficientOutputReverts() public {
        MockToken other = new MockToken();
        other.mint(address(treasury), 500 * ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        router.setOutAmount(1);
        k613.mint(address(router), 50 * ONE);
        treasury.setRouterWhitelist(address(router), true);
        vm.expectRevert(Treasury.InsufficientOutput.selector);
        treasury.buybackV3ExactInputSingle(address(other), address(router), 100 * ONE, 1e18, POOL_FEE, false);
    }

    /// @notice testBuybackV3_DistributeRewardsFalse: with distributeRewards=false RD balance does not increase.
    function testBuybackV3_DistributeRewardsFalse() public {
        MockToken other = new MockToken();
        other.mint(address(treasury), 100 * ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        k613.mint(address(router), 100 * ONE);
        treasury.setRouterWhitelist(address(router), true);
        uint256 rdBalBefore = xk613.balanceOf(address(distributor));
        treasury.buybackV3ExactInputSingle(address(other), address(router), 1, 1e18, POOL_FEE, false);
        assertEq(xk613.balanceOf(address(distributor)), rdBalBefore);
    }

    /// @notice testDepositRewards_PauseReverts: When paused, depositRewards reverts.
    function testDepositRewards_PauseReverts() public {
        k613.mint(address(this), 100 * ONE);
        k613.approve(address(treasury), 100 * ONE);
        treasury.pause();
        vm.expectRevert();
        treasury.depositRewards(100 * ONE);
    }

    /// @notice testBuybackV3_PauseReverts: paused treasury blocks buyback.
    function testBuybackV3_PauseReverts() public {
        MockToken other = new MockToken();
        other.mint(address(treasury), ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        k613.mint(address(router), ONE);
        treasury.setRouterWhitelist(address(router), true);
        treasury.pause();
        vm.expectRevert();
        treasury.buybackV3ExactInputSingle(address(other), address(router), 1, 1e18, POOL_FEE, false);
    }

    /// @notice testBuybackV3_DistributeRewardsTrue: with distributeRewards=true buyback notifies rewards.
    function testBuybackV3_DistributeRewardsTrue() public {
        xk613.mint(alice, 1_000 * ONE);
        xk613.setTransferWhitelist(alice, true);
        vm.prank(alice);
        xk613.approve(address(distributor), 1_000 * ONE);
        vm.prank(alice);
        distributor.deposit(1_000 * ONE);

        MockToken other = new MockToken();
        other.mint(address(treasury), ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        k613.mint(address(router), 100 * ONE);
        treasury.setRouterWhitelist(address(router), true);
        uint256 rdBalBefore = xk613.balanceOf(address(distributor));
        treasury.buybackV3ExactInputSingle(address(other), address(router), 1, 1e18, POOL_FEE, true);
        assertEq(xk613.balanceOf(address(distributor)), rdBalBefore + 1e18);
        assertGt(distributor.pendingRewardsOf(alice), 0);
    }

    /// @notice testBuybackV3_DistributeRewardsTrue_TreasuryK613Zero: distribute flow works from fresh treasury with zero starting k613.
    function testBuybackV3_DistributeRewardsTrue_TreasuryK613Zero() public {
        Treasury freshTreasury = new Treasury(address(k613), address(xk613), address(staking), address(distributor));
        freshTreasury.grantRole(freshTreasury.DEFAULT_ADMIN_ROLE(), address(this));
        freshTreasury.grantRole(freshTreasury.PAUSER_ROLE(), address(this));
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(freshTreasury));
        xk613.setTransferWhitelist(address(freshTreasury), true);
        xk613.mint(alice, 1_000 * ONE);
        xk613.setTransferWhitelist(alice, true);
        vm.prank(alice);
        xk613.approve(address(distributor), 1_000 * ONE);
        vm.prank(alice);
        distributor.deposit(1_000 * ONE);

        MockToken other = new MockToken();
        other.mint(address(freshTreasury), ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        k613.mint(address(router), 100 * ONE);
        freshTreasury.setRouterWhitelist(address(router), true);
        assertEq(k613.balanceOf(address(freshTreasury)), 0);
        freshTreasury.buybackV3ExactInputSingle(address(other), address(router), 1, 1e18, POOL_FEE, true);
        assertEq(k613.balanceOf(address(freshTreasury)), 0);
    }

    /// @notice testBuybackV3_ApproveResetAfterCall: tokenIn approval to router is reset to zero after swap.
    function testBuybackV3_ApproveResetAfterCall() public {
        MockToken other = new MockToken();
        other.mint(address(treasury), ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        k613.mint(address(router), ONE);
        treasury.setRouterWhitelist(address(router), true);
        treasury.buybackV3ExactInputSingle(address(other), address(router), 1, 1e18, POOL_FEE, false);
        assertEq(other.allowance(address(treasury), address(router)), 0);
    }

    /// @notice testBuybackV3_MockRouter_Success: mock router buyback increases treasury k613 balance.
    function testBuybackV3_MockRouter_Success() public {
        MockToken otherToken = new MockToken();
        otherToken.mint(address(treasury), 1000 * ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(otherToken));
        k613.mint(address(router), 100 * ONE);
        treasury.setRouterWhitelist(address(router), true);
        uint256 amountIn = 50 * ONE;
        uint256 k613Before = k613.balanceOf(address(treasury));
        treasury.buybackV3ExactInputSingle(address(otherToken), address(router), amountIn, 1e18, POOL_FEE, false);
        assertEq(k613.balanceOf(address(treasury)), k613Before + 1e18);
        assertEq(otherToken.allowance(address(treasury), address(router)), 0);
    }

    /// @notice testBuybackV3_BuybackFailed: router failure is mapped to BuybackFailed.
    function testBuybackV3_BuybackFailed() public {
        MockToken other = new MockToken();
        other.mint(address(treasury), ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        router.setShouldFail(true);
        k613.mint(address(router), ONE);
        treasury.setRouterWhitelist(address(router), true);
        vm.expectRevert(Treasury.BuybackFailed.selector);
        treasury.buybackV3ExactInputSingle(address(other), address(router), 1, 0, POOL_FEE, false);
    }

    /// @notice test_Treasury_DepositRewards_ToRD_Claim: Treasury depositRewards stakes K613 and notifies RD; user with RD deposit can claim and receives expected xK613.
    function test_Treasury_DepositRewards_ToRD_Claim() public {
        xk613.mint(alice, 1_000 * ONE);
        xk613.setTransferWhitelist(alice, true);
        vm.prank(alice);
        xk613.approve(address(distributor), 1_000 * ONE);
        vm.prank(alice);
        distributor.deposit(1_000 * ONE);

        k613.mint(address(this), 100 * ONE);
        k613.approve(address(treasury), 100 * ONE);
        treasury.depositRewards(100 * ONE);

        assertGt(distributor.pendingRewardsOf(alice), 0);
        uint256 before = xk613.balanceOf(alice);
        vm.prank(alice);
        distributor.claim();
        assertEq(xk613.balanceOf(alice), before + 100 * ONE);
    }

    /// @notice test_BuybackV3_DistributeRewards_ConservationOfK613: distributed flow preserves global k613 accounting.
    function test_BuybackV3_DistributeRewards_ConservationOfK613() public {
        xk613.mint(alice, 1_000 * ONE);
        xk613.setTransferWhitelist(alice, true);
        vm.prank(alice);
        xk613.approve(address(distributor), 1_000 * ONE);
        vm.prank(alice);
        distributor.deposit(1_000 * ONE);

        MockToken other = new MockToken();
        other.mint(address(treasury), ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(other));
        treasury.setRouterWhitelist(address(router), true);
        k613.mint(address(router), 100 * ONE);

        uint256 totalBefore = k613.balanceOf(address(treasury)) + k613.balanceOf(address(staking))
            + k613.balanceOf(address(distributor)) + k613.balanceOf(alice);

        treasury.buybackV3ExactInputSingle(address(other), address(router), ONE, 1e18, POOL_FEE, true);

        uint256 totalAfter = k613.balanceOf(address(treasury)) + k613.balanceOf(address(staking))
            + k613.balanceOf(address(distributor)) + k613.balanceOf(alice);

        assertEq(totalAfter - totalBefore, 1e18);
    }

    /// @notice testBuybackV3_RouterNotWhitelistedReverts: buyback reverts for non-whitelisted router.
    function testBuybackV3_RouterNotWhitelistedReverts() public {
        MockToken otherToken = new MockToken();
        otherToken.mint(address(treasury), 100 * ONE);
        MockV3Router02 router = new MockV3Router02(address(k613), address(otherToken));
        vm.expectRevert(Treasury.RouterNotWhitelisted.selector);
        treasury.buybackV3ExactInputSingle(address(otherToken), address(router), 10 * ONE, 1, POOL_FEE, false);
    }

    /// @notice testConstructorZeroAddressReverts: constructor rejects zero addresses for dependencies.
    function testConstructorZeroAddressReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(0), address(xk613), address(staking), address(distributor));

        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(k613), address(0), address(staking), address(distributor));

        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(k613), address(xk613), address(0), address(distributor));

        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(k613), address(xk613), address(staking), address(0));
    }

    /// @notice testPauseUnpauseOnlyPauser: pause and unpause are restricted to PAUSER_ROLE.
    function testPauseUnpauseOnlyPauser() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.pause();

        treasury.pause();

        vm.prank(alice);
        vm.expectRevert();
        treasury.unpause();
    }

    /// @notice testSetRouterWhitelistIdempotent: repeated add/remove does not duplicate entries or fail.
    function testSetRouterWhitelistIdempotent() public {
        MockToken t = new MockToken();
        MockV3Router02 r = new MockV3Router02(address(k613), address(t));

        treasury.setRouterWhitelist(address(r), true);
        treasury.setRouterWhitelist(address(r), true);
        address[] memory listAfterDoubleAdd = treasury.getWhitelistedRouters();
        assertEq(listAfterDoubleAdd.length, 1);
        assertEq(listAfterDoubleAdd[0], address(r));

        treasury.setRouterWhitelist(address(r), false);
        treasury.setRouterWhitelist(address(r), false);
        address[] memory listAfterDoubleRemove = treasury.getWhitelistedRouters();
        assertEq(listAfterDoubleRemove.length, 0);
    }
}
