// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613} from "../src/token/K613.sol";

/// @title MintInitialK613
/// @notice Mints initial K613 supply to deployer
contract MintInitialK613 is Script {
    uint256 private constant INITIAL_SUPPLY = 1_000_000 * 1e18;

    function run() external {
        address k613Addr = vm.envAddress("K613_ADDRESS");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address recipient = vm.addr(pk);

        vm.startBroadcast(pk);

        K613 k613 = K613(k613Addr);
        k613.mint(recipient, INITIAL_SUPPLY);
        console.log("Minted", INITIAL_SUPPLY / 1e18, "K613 to", recipient);

        vm.stopBroadcast();
    }
}
