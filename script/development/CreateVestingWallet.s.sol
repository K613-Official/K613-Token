// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {K613VestingManager} from "src/vesting/K613VestingManager.sol";

contract CreateVestingWallet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address managerAddress = vm.envAddress("VESTING_MANAGER_ADDRESS");
        address beneficiary = vm.envAddress("VESTING_BENEFICIARY_ADDRESS");
        uint64 startTimestamp = uint64(vm.envUint("VESTING_START_TIMESTAMP"));
        uint64 durationSeconds = uint64(vm.envUint("VESTING_DURATION_SECONDS"));
        uint64 cliffSeconds = uint64(vm.envUint("VESTING_CLIFF_SECONDS"));
        uint256 amount = vm.envUint("VESTING_AMOUNT");

        K613VestingManager manager = K613VestingManager(managerAddress);
        IERC20 token = IERC20(address(manager.token()));

        vm.startBroadcast(pk);
        token.approve(managerAddress, amount);
        address wallet = manager.createVestingWallet(beneficiary, startTimestamp, durationSeconds, cliffSeconds, amount);
        vm.stopBroadcast();

        console.log("Vesting wallet:", wallet);
        console.log("Beneficiary:", beneficiary);
        console.log("Amount:", amount);
        console.log("Start:", uint256(startTimestamp));
        console.log("Duration:", uint256(durationSeconds));
        console.log("Cliff:", uint256(cliffSeconds));
    }
}
