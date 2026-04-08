// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {
    PullRewardsTransferStrategy
} from "lib/L2-Protocol/src/contracts/rewards/transfer-strategies/PullRewardsTransferStrategy.sol";
import {IEmissionManager} from "lib/L2-Protocol/src/contracts/rewards/interfaces/IEmissionManager.sol";
import {ITransferStrategyBase} from "lib/L2-Protocol/src/contracts/rewards/interfaces/ITransferStrategyBase.sol";

interface IPoolLite {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IPoolAddressesProviderLite {
    function getAddress(bytes32 id) external view returns (address);
}

interface IRewardsControllerLite {
    function getTransferStrategy(address reward) external view returns (address);
    function getEmissionManager() external view returns (address);
}

interface IPullStrategyView {
    function getRewardsAdmin() external view returns (address);
    function getRewardsVault() external view returns (address);
}

contract InstallXk613PullStrategy is Script {
    bytes32 private constant INCENTIVES_CONTROLLER_ID = keccak256("INCENTIVES_CONTROLLER");

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasuryAddr = vm.envAddress("TREASURY_ADDRESS");
        address xk613 = vm.envAddress("XK613_ADDRESS");
        address poolAddr = vm.envAddress("AAVE_POOL_ADDRESS");

        address ap = IPoolLite(poolAddr).ADDRESSES_PROVIDER();
        address rcAddr = IPoolAddressesProviderLite(ap).getAddress(INCENTIVES_CONTROLLER_ID);
        require(rcAddr != address(0), "rewards controller zero");

        address oldStrategy = IRewardsControllerLite(rcAddr).getTransferStrategy(xk613);
        require(oldStrategy != address(0), "old strategy zero");

        address rewardsAdmin = IPullStrategyView(oldStrategy).getRewardsAdmin();
        address rewardsVault = IPullStrategyView(oldStrategy).getRewardsVault();
        address emissionManager = IRewardsControllerLite(rcAddr).getEmissionManager();

        address broadcaster = vm.addr(pk);
        address emissionAdmin = IEmissionManager(emissionManager).getEmissionAdmin(xk613);
        require(emissionAdmin == broadcaster, "PRIVATE_KEY must be xK613 emission admin");

        vm.startBroadcast(pk);
        PullRewardsTransferStrategy strat = new PullRewardsTransferStrategy(rcAddr, rewardsAdmin, rewardsVault);
        IEmissionManager(emissionManager).setTransferStrategy(xk613, ITransferStrategyBase(address(strat)));
        Treasury(treasuryAddr).approveXk613PullRewards(address(strat), type(uint256).max);
        vm.stopBroadcast();

        console.log("RewardsController:", rcAddr);
        console.log("EmissionManager:", emissionManager);
        console.log("Old strategy:", oldStrategy);
        console.log("New strategy:", address(strat));
    }
}
