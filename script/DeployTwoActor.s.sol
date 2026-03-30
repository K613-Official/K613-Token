// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

contract DeployTwoActor is Script {
    function run() external {
        step1FundBob();
    }

    function step1FundBob() public {
        address k613Addr = vm.envAddress("K613_ADDRESS");
        address bob = vm.addr(vm.envUint("BOB_PRIVATE_KEY"));
        uint256 adminPk = vm.envUint("ADMIN_PRIVATE_KEY");
        uint256 fund = vm.envOr("VERIFY_BOB_FUND", uint256(2_000 ether));
        vm.startBroadcast(adminPk);
        K613(k613Addr).transfer(bob, fund);
        vm.stopBroadcast();
        console.log("TwoActor step1: ADMIN sent K613 to BOB", fund);
    }

    function step2AliceStakeAndRD() public {
        address alice = vm.addr(vm.envUint("ALICE_PRIVATE_KEY"));
        K613 k613 = K613(vm.envAddress("K613_ADDRESS"));
        xK613 xk = xK613(vm.envAddress("XK613_ADDRESS"));
        Staking staking = Staking(vm.envAddress("STAKING_ADDRESS"));
        RewardsDistributor rd = RewardsDistributor(vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS"));
        uint256 stakeAmt = vm.envOr("VERIFY_ALICE_STAKE", uint256(1_000 ether));
        uint256 rdAmt = vm.envOr("VERIFY_ALICE_RD", uint256(500 ether));
        require(k613.balanceOf(alice) >= stakeAmt, "TwoActor: alice K613");
        require(rdAmt <= stakeAmt, "TwoActor: RD > stake");

        vm.startBroadcast(vm.envUint("ALICE_PRIVATE_KEY"));
        k613.approve(address(staking), stakeAmt);
        staking.stake(stakeAmt);
        IERC20(address(xk)).approve(address(rd), rdAmt);
        rd.deposit(rdAmt);
        vm.stopBroadcast();
        console.log("TwoActor step2: alice stake + RD deposit");
    }

    function step3AdminDepositRewards() public {
        address admin = vm.addr(vm.envUint("ADMIN_PRIVATE_KEY"));
        K613 k613 = K613(vm.envAddress("K613_ADDRESS"));
        Treasury treasury = Treasury(vm.envAddress("TREASURY_ADDRESS"));
        uint256 rewardAmt = vm.envOr("VERIFY_TREASURY_REWARD", uint256(100 ether));
        require(k613.balanceOf(admin) >= rewardAmt, "TwoActor: admin K613 for treasury");

        vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));
        k613.approve(address(treasury), rewardAmt);
        treasury.depositRewards(rewardAmt);
        vm.stopBroadcast();
        console.log("TwoActor step3: treasury depositRewards from ADMIN");
    }

    function step4BobPenalty() public {
        address bob = vm.addr(vm.envUint("BOB_PRIVATE_KEY"));
        K613 k613 = K613(vm.envAddress("K613_ADDRESS"));
        xK613 xk = xK613(vm.envAddress("XK613_ADDRESS"));
        Staking staking = Staking(vm.envAddress("STAKING_ADDRESS"));
        uint256 bobStake = vm.envOr("VERIFY_BOB_STAKE", uint256(500 ether));
        uint256 exitAmt = vm.envOr("VERIFY_BOB_INSTANT_EXIT", uint256(100 ether));
        require(bobStake >= exitAmt, "TwoActor: bob stake < exit");
        require(k613.balanceOf(bob) >= bobStake, "TwoActor: bob K613");

        vm.startBroadcast(vm.envUint("BOB_PRIVATE_KEY"));
        k613.approve(address(staking), bobStake);
        staking.stake(bobStake);
        IERC20(address(xk)).approve(address(staking), exitAmt);
        staking.initiateExit(exitAmt);
        staking.instantExit(0);
        vm.stopBroadcast();
        console.log("TwoActor step4: bob penalty to RD via instant exit");
    }

    function step5AliceEpochAndClaim() public {
        RewardsDistributor rd = RewardsDistributor(vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS"));
        uint256 nextAt = rd.nextEpochAt();
        require(block.timestamp >= nextAt, "TwoActor: wait nextEpochAt()");

        vm.startBroadcast(vm.envUint("ALICE_PRIVATE_KEY"));
        rd.advanceEpoch();
        rd.claim();
        vm.stopBroadcast();
        console.log("TwoActor step5: alice advanceEpoch + claim");
    }

    function step6AliceWithdrawRD() public {
        RewardsDistributor rd = RewardsDistributor(vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS"));
        uint256 rdAmt = vm.envOr("VERIFY_ALICE_RD", uint256(500 ether));

        vm.startBroadcast(vm.envUint("ALICE_PRIVATE_KEY"));
        rd.withdraw(rdAmt);
        vm.stopBroadcast();
        console.log("TwoActor step6: alice withdraw RD principal");
    }
}
