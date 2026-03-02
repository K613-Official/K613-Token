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
        bytes memory swapCalldata = vm.parseBytes(vm.envString("SWAP_CALLDATA_HEX"));

        if (amount == 0) {
            amount = IERC20(token).balanceOf(treasuryAddr);
            console.log("Using full Treasury balance:", amount);
        }
        require(amount != 0, "TreasuryBuyback: zero amount");
        require(swapCalldata.length != 0, "TreasuryBuyback: SWAP_CALLDATA_HEX required");

        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        Treasury treasury = Treasury(treasuryAddr);
        uint256 k613Out = treasury.buyback(token, router, amount, swapCalldata, minK613Out, true);
        vm.stopBroadcast();

        console.log("Buyback done: received", k613Out, "K613");
    }
}
