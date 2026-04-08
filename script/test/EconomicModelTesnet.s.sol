// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {K613} from "src/token/K613.sol";
import {xK613} from "src/token/xK613.sol";
import {Staking} from "src/staking/Staking.sol";
import {RewardsDistributor} from "src/staking/RewardsDistributor.sol";
import {Treasury} from "src/treasury/Treasury.sol";

contract EconomicModelTesnet is Script {
    struct FlowParams {
        address actor;
        K613 k613;
        xK613 xk613;
        Staking staking;
        RewardsDistributor distributor;
        Treasury treasury;
        uint256 stakeAmt;
        uint256 rdAmt;
        uint256 rewardAmt;
        uint256 instantExitAmt;
    }

    function run() external {
        step1StakeTreasuryInstantExit();
    }

    function step1StakeTreasuryInstantExit() public {
        FlowParams memory p = _loadParams();
        require(p.k613.balanceOf(p.actor) >= p.stakeAmt + p.rewardAmt, "LIVE: insufficient K613");
        require(p.rdAmt <= p.stakeAmt, "LIVE: RD deposit exceeds stake");
        require(p.instantExitAmt <= p.stakeAmt - p.rdAmt, "LIVE: instant exit exceeds free xK613");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        p.k613.approve(address(p.staking), p.stakeAmt);
        p.staking.stake(p.stakeAmt);

        IERC20(address(p.xk613)).approve(address(p.distributor), p.rdAmt);
        p.distributor.deposit(p.rdAmt);

        p.k613.approve(address(p.treasury), p.rewardAmt);
        p.treasury.depositRewards(p.rewardAmt);

        IERC20(address(p.xk613)).approve(address(p.staking), p.instantExitAmt);
        p.staking.initiateExit(p.instantExitAmt);
        p.staking.instantExit(0);

        vm.stopBroadcast();

        console.log("LIVE step1 done: stake, RD, treasury, instant exit");
        console.log(
            "LIVE next: wait until block.timestamp >= RewardsDistributor.nextEpochAt(), then step2EpochClaimWithdraw"
        );
    }

    function step2EpochClaimWithdraw() public {
        FlowParams memory p = _loadParams();
        RewardsDistributor d = p.distributor;
        uint256 t = block.timestamp;
        uint256 nextAt = d.nextEpochAt();
        require(t >= nextAt, "LIVE: epoch not ready; wait until nextEpochAt() wall-clock time");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        d.advanceEpoch();
        d.claim();
        d.withdraw(p.rdAmt);

        vm.stopBroadcast();

        console.log("LIVE step2 done: advanceEpoch, claim, withdraw RD principal");
        console.log("LIVE next: step3InitiateExitRemainder");
    }

    function step3InitiateExitRemainder() public {
        FlowParams memory p = _loadParams();
        (uint256 staked,) = p.staking.deposits(p.actor);
        require(staked > 0, "LIVE: nothing staked");
        require(IERC20(address(p.xk613)).balanceOf(p.actor) >= staked, "LIVE: need xK613 wallet >= staked");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        IERC20(address(p.xk613)).approve(address(p.staking), staked);
        p.staking.initiateExit(staked);

        vm.stopBroadcast();

        console.log("LIVE step3 done: full remainder in exit queue index 0");
        console.log("LIVE next: wait lockDuration wall-clock, then step4ExitAfterLock");
    }

    function step4ExitAfterLock() public {
        FlowParams memory p = _loadParams();
        require(p.staking.exitQueueLength(p.actor) > 0, "LIVE: no exit request");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        p.staking.exit(0);

        vm.stopBroadcast();

        console.log("LIVE step4 done: normal exit, K613 to wallet");
    }

    function _loadParams() internal view returns (FlowParams memory p) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        p.actor = vm.addr(pk);
        p.k613 = K613(vm.envAddress("K613_ADDRESS"));
        p.xk613 = xK613(vm.envAddress("XK613_ADDRESS"));
        p.staking = Staking(vm.envAddress("STAKING_ADDRESS"));
        p.distributor = RewardsDistributor(vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS"));
        p.treasury = Treasury(vm.envAddress("TREASURY_ADDRESS"));
        p.stakeAmt = vm.envOr("VERIFY_STAKE_AMOUNT", uint256(1_000 ether));
        p.rdAmt = vm.envOr("VERIFY_RD_DEPOSIT", uint256(500 ether));
        p.rewardAmt = vm.envOr("VERIFY_TREASURY_REWARD", uint256(100 ether));
        p.instantExitAmt = vm.envOr("VERIFY_INSTANT_EXIT", uint256(100 ether));
    }
}
