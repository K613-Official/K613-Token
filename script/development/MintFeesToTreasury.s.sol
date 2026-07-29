// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IPool} from "lib/K613-Protocol/src/contracts/interfaces/IPool.sol";

/// @title MintFeesToTreasury
/// @notice Step 0 of the monthly fee cycle: materializes `accruedToTreasury` of all 11 reserves as
///         aTokens on the Aave Collector (permissionless `Pool.mintToTreasury`). Run this FIRST and
///         ALONE — CollectProtocolFees computes its transfer amounts from live Collector balances,
///         so the mint must be mined before the collect run is simulated.
/// @dev Env: PRIVATE_KEY. Run with -g 300 — Monad underestimates this call's gas.
contract MintFeesToTreasury is Script {
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;
    IPool private constant POOL = IPool(0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113);

    function _feeAssets() internal pure returns (address[] memory assets) {
        assets = new address[](11);
        assets[0] = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603; // USDC
        assets[1] = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a; // AUSD
        assets[2] = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D; // USDT0
        assets[3] = 0x4809010926aec940b550D34a46A52739f996D75D; // wsrUSD
        assets[4] = 0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242; // WETH
        assets[5] = 0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417; // wstETH
        assets[6] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c; // WBTC
        assets[7] = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A; // WMON
        assets[8] = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c; // shMON
        assets[9] = 0xA3227C5969757783154C60bF0bC1944180ed81B9; // sMON
        assets[10] = 0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081; // gMON
    }

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        POOL.mintToTreasury(_feeAssets());
        vm.stopBroadcast();

        console.log("mintToTreasury done for 11 assets. Now run CollectProtocolFees.s.sol.");
    }
}
