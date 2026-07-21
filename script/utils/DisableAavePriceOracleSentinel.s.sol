// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IPool} from "lib/K613-Protocol/src/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "lib/K613-Protocol/src/contracts/interfaces/IPoolAddressesProvider.sol";

contract DisableAavePriceOracleSentinel is Script {
    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;
    address private constant POOL_MONAD = 0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address provider = address(IPool(POOL_MONAD).ADDRESSES_PROVIDER());

        vm.startBroadcast(pk);
        IPoolAddressesProvider(provider).setPriceOracleSentinel(address(0));
        vm.stopBroadcast();

        console.log("PriceOracleSentinel set to zero for provider:", provider);
    }
}
