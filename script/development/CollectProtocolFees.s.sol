// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IPool} from "lib/K613-Protocol/src/contracts/interfaces/IPool.sol";
import {IPoolDataProvider} from "lib/K613-Protocol/src/contracts/interfaces/IPoolDataProvider.sol";
import {ICollector} from "lib/K613-Protocol/src/contracts/treasury/ICollector.sol";

/// @title CollectProtocolFees
/// @notice One-shot fee collection for all reserves on Monad mainnet:
///         1. Pool.mintToTreasury(assets) — materializes accruedToTreasury as aTokens on the Collector;
///         2. Collector.transfer(aToken, FEE_RECIPIENT, full balance) for every asset with a non-zero balance;
///         3. optionally (DO_WITHDRAW=true, only when FEE_RECIPIENT is the broadcaster EOA)
///            Pool.withdraw(asset, max) — redeems aTokens into underlying on the recipient.
/// @dev Env:
///      FEE_RECIPIENT  where aTokens go (multisig or EOA)
///      DO_WITHDRAW    optional bool, default false
///      PRIVATE_KEY    must hold FUNDS_ADMIN on the Collector
contract CollectProtocolFees is Script {
    // Monad mainnet, see docs/OPERATIONS_SOP.md D.2/D.5
    ICollector internal constant COLLECTOR = ICollector(0xF689bB846eE7DD51947c3368cc3ee26713D3ED83);
    IPool internal constant POOL = IPool(0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113);
    IPoolDataProvider internal constant DATA_PROVIDER = IPoolDataProvider(0xfc87bE7f3657AAD69baDb6247A88E924D1F8bc53);

    address internal constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant USDT0 = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D;
    address internal constant WSRUSD = 0x4809010926aec940b550D34a46A52739f996D75D;
    address internal constant WETH = 0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;
    address internal constant WSTETH = 0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417;
    address internal constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address internal constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant SHMON = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
    address internal constant SMON = 0xA3227C5969757783154C60bF0bC1944180ed81B9;
    address internal constant GMON = 0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081;

    function _feeAssets() internal pure returns (address[] memory assets) {
        assets = new address[](11);
        assets[0] = USDC;
        assets[1] = AUSD;
        assets[2] = USDT0;
        assets[3] = WSRUSD;
        assets[4] = WETH;
        assets[5] = WSTETH;
        assets[6] = WBTC;
        assets[7] = WMON;
        assets[8] = SHMON;
        assets[9] = SMON;
        assets[10] = GMON;
    }

    function run() external {
        address recipient = vm.envAddress("FEE_RECIPIENT");
        bool doWithdraw = vm.envOr("DO_WITHDRAW", false);
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);

        if (doWithdraw && recipient != broadcaster) {
            revert("CollectProtocolFees: DO_WITHDRAW requires FEE_RECIPIENT == broadcaster (aToken holder redeems)");
        }

        address[] memory assets = _feeAssets();
        console.log("Recipient :", recipient);

        vm.startBroadcast(pk);

        POOL.mintToTreasury(assets);

        for (uint256 i = 0; i < assets.length; ++i) {
            (address aToken,,) = DATA_PROVIDER.getReserveTokensAddresses(assets[i]);
            uint256 bal = IERC20(aToken).balanceOf(address(COLLECTOR));
            if (bal == 0) {
                console.log("skip (zero):", assets[i]);
                continue;
            }
            COLLECTOR.transfer(IERC20(aToken), recipient, bal);
            console.log("transferred:", aToken, bal);

            if (doWithdraw) {
                uint256 out = POOL.withdraw(assets[i], type(uint256).max, recipient);
                console.log("withdrawn  :", assets[i], out);
            }
        }

        vm.stopBroadcast();
    }
}
