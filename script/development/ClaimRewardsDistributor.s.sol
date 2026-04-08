// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {RewardsDistributor} from "src/staking/RewardsDistributor.sol";

contract ClaimRewardsDistributor is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address claimer = vm.addr(pk);
        RewardsDistributor rd = RewardsDistributor(vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS"));

        uint256 pendingBefore = rd.pendingRewardsOf(claimer);
        console.log("Claimer:", claimer);
        console.log("RewardsDistributor:", address(rd));
        console.log("Pending xK613 rewards (view):", pendingBefore);

        vm.startBroadcast(pk);
        rd.claim();
        vm.stopBroadcast();

        uint256 pendingAfter = rd.pendingRewardsOf(claimer);
        console.log("Pending after claim:", pendingAfter);
    }
}
