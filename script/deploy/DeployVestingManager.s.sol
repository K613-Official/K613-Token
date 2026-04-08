// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613VestingManager} from "src/vesting/K613VestingManager.sol";

contract DeployVestingManager is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("VESTING_OWNER_ADDRESS");
        address token = vm.envAddress("K613_ADDRESS");

        vm.startBroadcast(pk);
        K613VestingManager manager = new K613VestingManager(owner, token);
        vm.stopBroadcast();

        console.log("K613VestingManager:", address(manager));
        console.log("Owner:", owner);
        console.log("Token:", token);
    }
}
