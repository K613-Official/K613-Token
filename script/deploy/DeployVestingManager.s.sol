// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613VestingManager} from "src/vesting/K613VestingManager.sol";

contract DeployVestingManager is Script {
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;

    /// @notice K613 on Monad mainnet, deployed 2026-07-10 (see docs/OPERATIONS_SOP.md D.1).
    address private constant K613_MONAD = 0xb09582631336068d4B0089d943f40CbF46dE5189;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        // VESTING_OWNER_ADDRESS is optional: defaults to the broadcaster EOA (it runs DistributeK613 later).
        address owner = vm.envOr("VESTING_OWNER_ADDRESS", vm.addr(pk));
        address token = K613_MONAD;

        vm.startBroadcast(pk);
        K613VestingManager manager = new K613VestingManager(owner, token);
        vm.stopBroadcast();

        console.log("K613VestingManager:", address(manager));
        console.log("Owner:", owner);
        console.log("Token:", token);
    }
}
