// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

interface IPoolAddressesProviderLike {
    function setPriceOracleSentinel(address newPriceOracleSentinel) external;
}

interface IPoolLike {
    function ADDRESSES_PROVIDER() external view returns (address);
}

contract DisableAavePriceOracleSentinel is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address pool = vm.envAddress("AAVE_POOL_ADDRESS");
        address provider = IPoolLike(pool).ADDRESSES_PROVIDER();

        vm.startBroadcast(pk);
        IPoolAddressesProviderLike(provider).setPriceOracleSentinel(address(0));
        vm.stopBroadcast();

        console.log("PriceOracleSentinel set to zero for provider:", provider);
    }
}
