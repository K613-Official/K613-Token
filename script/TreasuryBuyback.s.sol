// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

/// @title TreasuryBuyback
/// @notice Swaps token on Treasury for K613 via whitelisted router and distributes to stakers.
contract TreasuryBuyback is Script {
    function run() external {
        address treasuryAddr = vm.envAddress("K613_TREASURY_ADDRESS");
        address token = vm.envAddress("TOKEN_ADDRESS");
        address router = vm.envAddress("ROUTER_ADDRESS");
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        uint256 minK613Out = vm.envUint("MIN_K613_OUT");
        // SWAP_PATH is a comma-separated list of addresses, e.g. "0xToken,0xK613"
        string memory pathStr = vm.envString("SWAP_PATH");

        if (amount == 0) {
            amount = IERC20(token).balanceOf(treasuryAddr);
            console.log("Using full Treasury balance:", amount);
        }
        require(amount != 0, "TreasuryBuyback: zero amount");
        require(bytes(pathStr).length != 0, "TreasuryBuyback: SWAP_PATH required");

        uint256 pk = vm.envUint("PRIVATE_KEY");

        // Parse SWAP_PATH into address[]
        string[] memory parts = vm.split(pathStr, ",");
        address[] memory path = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            path[i] = vm.parseAddress(parts[i]);
        }

        vm.startBroadcast(pk);
        Treasury treasury = Treasury(treasuryAddr);
        uint256 k613Out = treasury.buyback(token, router, amount, minK613Out, path, true);
        vm.stopBroadcast();

        console.log("Buyback done: received", k613Out, "K613");
    }
}
