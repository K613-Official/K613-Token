// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Staking} from "../src/staking/Staking.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

contract MockRouter {
    K613 public k613;
    bool public shouldFail;
    bool public shouldReturnInsufficient;

    constructor(address _k613) {
        k613 = K613(_k613);
    }

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function setShouldReturnInsufficient(bool _insufficient) external {
        shouldReturnInsufficient = _insufficient;
    }

    function swapExactTokensForTokens() external {
        if (shouldFail) revert("swap failed");
        if (shouldReturnInsufficient) {
            k613.transfer(msg.sender, 1);
        } else {
            k613.transfer(msg.sender, 1e18);
        }
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

    /// @notice testBuyback_ZeroTokenInReverts: buyback with tokenIn zero reverts with ZeroAddress.
    function testBuyback_ZeroTokenInReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.buyback(address(0), address(0x1), 1, "", 0, false);
    }

    /// @notice testBuyback_ZeroRouterReverts: buyback with router zero reverts with ZeroAddress.
    function testBuyback_ZeroRouterReverts() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.buyback(address(k613), address(0), 1, "", 0, false);
    }

    /// @notice testBuyback_ZeroAmountReverts: buyback with amountIn zero reverts with ZeroAmount.
    function testBuyback_ZeroAmountReverts() public {
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.buyback(address(k613), address(0x1), 0, "", 0, false);
    }

    /// @notice testBuyback_RouterNotWhitelistedReverts: buyback with non-whitelisted router reverts with RouterNotWhitelisted.
    function testBuyback_RouterNotWhitelistedReverts() public {
        MockRouter router = new MockRouter(address(k613));
        k613.mint(address(router), 100 * ONE);
        bytes memory data = abi.encodeWithSelector(MockRouter.swapExactTokensForTokens.selector);
        vm.expectRevert(Treasury.RouterNotWhitelisted.selector);
        treasury.buyback(address(k613), address(router), 1, data, 0, false);
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

    /// @notice testSetRouterWhitelist_SuccessAndBuyback: setRouterWhitelist enables buyback; removing router disables and buyback reverts.
    function testSetRouterWhitelist_SuccessAndBuyback() public {
        MockRouter router = new MockRouter(address(k613));
        assertFalse(treasury.routerWhitelist(address(router)));
        vm.expectEmit(true, true, false, true);
        emit Treasury.RouterWhitelistUpdated(address(router), true);
        treasury.setRouterWhitelist(address(router), true);
        assertTrue(treasury.routerWhitelist(address(router)));
        k613.mint(address(router), 100 * ONE);
        bytes memory data = abi.encodeWithSelector(MockRouter.swapExactTokensForTokens.selector);
        treasury.buyback(address(k613), address(router), 1, data, 1e18, false);

        treasury.setRouterWhitelist(address(router), false);
        assertFalse(treasury.routerWhitelist(address(router)));
        vm.expectRevert(Treasury.RouterNotWhitelisted.selector);
        treasury.buyback(address(k613), address(router), 1, data, 0, false);
    }

    /// @notice testGetWhitelistedRouters: getWhitelistedRouters returns added routers and length decreases when one is removed.
    function testGetWhitelistedRouters() public {
        address[] memory empty = treasury.getWhitelistedRouters();
        assertEq(empty.length, 0);

        MockRouter r1 = new MockRouter(address(k613));
        MockRouter r2 = new MockRouter(address(k613));
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

    /// @notice testBuyback_InsufficientOutputReverts: buyback when router returns less than minK613Out reverts with InsufficientOutput.
    function testBuyback_InsufficientOutputReverts() public {
        MockRouter router = new MockRouter(address(k613));
        treasury.setRouterWhitelist(address(router), true);
        router.setShouldReturnInsufficient(true);
        k613.mint(address(router), 100 * ONE);
        bytes memory data = abi.encodeWithSelector(MockRouter.swapExactTokensForTokens.selector);
        vm.expectRevert(Treasury.InsufficientOutput.selector);
        treasury.buyback(address(k613), address(router), 1, data, 1e18, false);
    }

    /// @notice testBuyback_DistributeRewardsFalse: buyback with distributeRewards false does not send xK613 to RD.
    function testBuyback_DistributeRewardsFalse() public {
        MockRouter router = new MockRouter(address(k613));
        treasury.setRouterWhitelist(address(router), true);
        k613.mint(address(router), 100 * ONE);
        uint256 rdBalBefore = xk613.balanceOf(address(distributor));
        bytes memory data = abi.encodeWithSelector(MockRouter.swapExactTokensForTokens.selector);
        treasury.buyback(address(k613), address(router), 1, data, 1e18, false);
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

    /// @notice testBuyback_PauseReverts: When paused, buyback reverts.
    function testBuyback_PauseReverts() public {
        MockRouter router = new MockRouter(address(k613));
        treasury.setRouterWhitelist(address(router), true);
        k613.mint(address(router), 100 * ONE);
        bytes memory data = abi.encodeWithSelector(MockRouter.swapExactTokensForTokens.selector);
        treasury.pause();
        vm.expectRevert();
        treasury.buyback(address(k613), address(router), 1, data, 1e18, false);
    }

    /// @notice testBuyback_DistributeRewardsTrue: buyback with distributeRewards true stakes K613 and notifies RD; user has pending rewards.
    function testBuyback_DistributeRewardsTrue() public {
        xk613.mint(alice, 1_000 * ONE);
        xk613.setTransferWhitelist(alice, true);
        vm.prank(alice);
        xk613.approve(address(distributor), 1_000 * ONE);
        vm.prank(alice);
        distributor.deposit(1_000 * ONE);

        MockRouter router = new MockRouter(address(k613));
        treasury.setRouterWhitelist(address(router), true);
        k613.mint(address(router), 100 * ONE);
        uint256 rdBalBefore = xk613.balanceOf(address(distributor));
        bytes memory data = abi.encodeWithSelector(MockRouter.swapExactTokensForTokens.selector);
        treasury.buyback(address(k613), address(router), 1, data, 1e18, true);
        assertEq(xk613.balanceOf(address(distributor)), rdBalBefore + 1e18);
        assertGt(distributor.pendingRewardsOf(alice), 0);
    }

    /// @notice testBuyback_BuybackFailed: buyback when router call fails reverts with BuybackFailed.
    function testBuyback_BuybackFailed() public {
        MockRouter router = new MockRouter(address(k613));
        treasury.setRouterWhitelist(address(router), true);
        router.setShouldFail(true);
        k613.mint(address(router), 100 * ONE);
        bytes memory data = abi.encodeWithSelector(MockRouter.swapExactTokensForTokens.selector);
        vm.expectRevert(Treasury.BuybackFailed.selector);
        treasury.buyback(address(k613), address(router), 1, data, 0, false);
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
}
