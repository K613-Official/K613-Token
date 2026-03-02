// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal interface for Aave Collector (L2-Protocol). Only transfer used here
interface ICollectorTransfer {
    function transfer(IERC20 token, address recipient, uint256 amount) external;
}

/// @title TransferFromCollectorToTreasury
/// @notice Transfers ERC20 from Aave Collector to K613 Treasury
contract TransferFromCollectorToTreasury is Script {
    function run() external {
        address collectorProxy = vm.envAddress("COLLECTOR_PROXY_ADDRESS");
        address treasury = vm.envAddress("K613_TREASURY_ADDRESS");
        address token = vm.envAddress("TOKEN_ADDRESS");
        uint256 amount = vm.envOr("AMOUNT", type(uint256).max);

        if (amount == type(uint256).max) {
            amount = IERC20(token).balanceOf(collectorProxy);
            console.log("Using full Collector balance:", amount);
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(amount != 0, "TransferFromCollectorToTreasury: zero amount");

        vm.startBroadcast(pk);
        ICollectorTransfer(collectorProxy).transfer(IERC20(token), treasury, amount);
        vm.stopBroadcast();

        console.log("Transferred", amount, "to Treasury");
        console.log("Treasury:", treasury);
        console.log("Token:", token);
    }
}
