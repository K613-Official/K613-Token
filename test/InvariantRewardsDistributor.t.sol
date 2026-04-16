// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";

contract RewardsDistributorHandler is Test {
    uint256 private constant MAX_AMOUNT = 1_000_000 ether;

    K613 public k613;
    xK613 public xk613;
    Staking public staking;
    RewardsDistributor public distributor;
    address[] public actors;

    constructor(K613 k613_, xK613 xk613_, Staking staking_, RewardsDistributor distributor_, address[] memory actors_) {
        k613 = k613_;
        xk613 = xk613_;
        staking = staking_;
        distributor = distributor_;
        actors = actors_;
    }

    function seedAndDeposit(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 minDeposit = distributor.totalDeposits() == 0 ? distributor.MIN_INITIAL_DEPOSIT() : 1;
        uint256 amount = bound(rawAmount, minDeposit, MAX_AMOUNT);

        k613.mint(actor, amount);
        vm.startPrank(actor);
        k613.approve(address(staking), amount);
        staking.stake(amount);
        xk613.approve(address(distributor), amount);
        distributor.deposit(amount);
        vm.stopPrank();
    }

    function withdraw(uint256 rawAmount, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = distributor.balanceOf(actor);
        if (bal == 0) return;
        uint256 amount = bound(rawAmount, 1, bal);
        vm.prank(actor);
        distributor.withdraw(amount);
    }

    function notify(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, distributor.MIN_NOTIFY(), MAX_AMOUNT);
        k613.mint(address(this), amount);
        k613.approve(address(staking), amount);
        staking.stake(amount);
        xk613.transfer(address(distributor), amount);
        distributor.notifyReward(amount);
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 pending = distributor.pendingRewardsOf(actor);
        if (pending == 0) return;
        vm.prank(actor);
        distributor.claim();
    }

    function advanceEpoch() external {
        uint256 next = distributor.nextEpochAt();
        if (block.timestamp < next) vm.warp(next);
        distributor.advanceEpoch();
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}

contract InvariantRewardsDistributorTest is StdInvariant, Test {
    uint256 private constant LOCK_DURATION = 7 days;
    uint256 private constant EPOCH_DURATION = 7 days;

    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;
    RewardsDistributorHandler private handler;
    address[] private actors;

    function setUp() public {
        actors.push(vm.addr(11));
        actors.push(vm.addr(12));
        actors.push(vm.addr(13));
        actors.push(vm.addr(14));

        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new Staking(address(k613), address(xk613), LOCK_DURATION, 5_000);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);

        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(staking), true);
        xk613.setTransferWhitelist(address(distributor), true);

        handler = new RewardsDistributorHandler(k613, xk613, staking, distributor, actors);
        k613.setMinter(address(handler));
        xk613.setTransferWhitelist(address(handler), true);
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(handler));

        targetContract(address(handler));
    }

    /// @notice invariant_totalDepositsMatchesSumBalances: totalDeposits equals sum of tracked actor balances.
    function invariant_totalDepositsMatchesSumBalances() public view {
        uint256 sum = 0;
        uint256 len = handler.actorsLength();
        for (uint256 i = 0; i < len; i++) {
            sum += distributor.balanceOf(handler.actorAt(i));
        }
        assertEq(distributor.totalDeposits(), sum);
    }

    /// @notice invariant_pendingBoundedByAssets: aggregate pending rewards stay bounded by RD-held assets.
    function invariant_pendingBoundedByAssets() public view {
        uint256 pending = 0;
        uint256 len = handler.actorsLength();
        for (uint256 i = 0; i < len; i++) {
            pending += distributor.pendingRewardsOf(handler.actorAt(i));
        }
        uint256 xBal = xk613.balanceOf(address(distributor));
        uint256 kBal = k613.balanceOf(address(distributor));
        assertLe(pending, xBal + kBal + len * 1e9);
    }
}
