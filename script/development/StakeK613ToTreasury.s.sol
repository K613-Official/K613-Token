// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {K613} from "src/token/K613.sol";
import {xK613} from "src/token/xK613.sol";
import {Staking} from "src/staking/Staking.sol";

contract StakeK613ToTreasury is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address actor = vm.addr(pk);
        K613 k613 = K613(vm.envAddress("K613_ADDRESS"));
        xK613 xk = xK613(vm.envAddress("XK613_ADDRESS"));
        Staking staking = Staking(vm.envAddress("STAKING_ADDRESS"));
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 amount = vm.envUint("AMOUNT");

        require(amount > 0, "AMOUNT");

        vm.startBroadcast(pk);

        k613.approve(address(staking), amount);
        staking.stake(amount);
        IERC20(address(xk)).transfer(treasury, amount);

        vm.stopBroadcast();

        console.log("Actor:", actor);
        console.log("Staked K613 (wei):", amount);
        console.log("Sent xK613 to Treasury (wei):", amount);
        console.log("Actor K613 bal:", k613.balanceOf(actor));
        console.log("Actor xK613 bal:", IERC20(address(xk)).balanceOf(actor));
        console.log("Treasury xK613 bal:", IERC20(address(xk)).balanceOf(treasury));
    }
}
