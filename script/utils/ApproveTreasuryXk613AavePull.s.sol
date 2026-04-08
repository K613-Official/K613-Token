// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "src/treasury/Treasury.sol";

interface IPoolLite {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IPoolAddressesProviderLite {
    function getAddress(bytes32 id) external view returns (address);
}

interface IRewardsControllerLite {
    function getTransferStrategy(address reward) external view returns (address);
}

contract ApproveTreasuryXk613AavePull is Script {
    bytes32 private constant INCENTIVES_CONTROLLER_ID = keccak256("INCENTIVES_CONTROLLER");

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasuryAddr = vm.envAddress("TREASURY_ADDRESS");
        address xk613Addr = vm.envAddress("XK613_ADDRESS");
        address poolAddr = vm.envAddress("AAVE_POOL_ADDRESS");

        address ap = IPoolLite(poolAddr).ADDRESSES_PROVIDER();
        address rc = IPoolAddressesProviderLite(ap).getAddress(INCENTIVES_CONTROLLER_ID);
        address strategy = IRewardsControllerLite(rc).getTransferStrategy(xk613Addr);
        require(strategy != address(0), "getTransferStrategy zero");

        vm.startBroadcast(pk);
        Treasury(treasuryAddr).approveXk613PullRewards(strategy, type(uint256).max);
        vm.stopBroadcast();

        console.log("Treasury:", treasuryAddr);
        console.log("xK613 reward token:", xk613Addr);
        console.log("Pull strategy:", strategy);
        console.log("allowance set: type(uint256).max");
    }
}
