// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {
    PullRewardsTransferStrategy
} from "lib/K613-Protocol/src/contracts/rewards/transfer-strategies/PullRewardsTransferStrategy.sol";
import {IEmissionManager} from "lib/K613-Protocol/src/contracts/rewards/interfaces/IEmissionManager.sol";
import {ITransferStrategyBase} from "lib/K613-Protocol/src/contracts/rewards/interfaces/ITransferStrategyBase.sol";
import {
    IPullRewardsTransferStrategy
} from "lib/K613-Protocol/src/contracts/rewards/interfaces/IPullRewardsTransferStrategy.sol";
import {IPool} from "lib/K613-Protocol/src/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "lib/K613-Protocol/src/contracts/interfaces/IPoolAddressesProvider.sol";
import {IRewardsController} from "lib/K613-Protocol/src/contracts/rewards/interfaces/IRewardsController.sol";

/// @title InstallXk613PullStrategy
/// @notice RECOVERY TOOL — replaces an EXISTING xK613 transfer strategy on a live market:
///         deploys a fresh `PullRewardsTransferStrategy` (same rewardsAdmin/rewardsVault as the old
///         one), points the EmissionManager at it, and re-approves it on the Treasury — atomically.
///         Use when the current strategy is misconfigured or its rewardsAdmin key is compromised.
///         For the INITIAL mainnet install use `ConfigureSupplyIncentives.s.sol` (k613-markets-config)
///         followed by `ApproveTreasuryXk613AavePull.s.sol` — this script reverts if no strategy
///         is set yet ("old strategy zero").
/// @dev Env: PRIVATE_KEY only (must be the xK613 emission admin AND hold DEFAULT_ADMIN_ROLE on
///      the Treasury). Monad mainnet addresses are hardcoded constants below.
contract InstallXk613PullStrategy is Script {
    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);

    bytes32 private constant INCENTIVES_CONTROLLER_ID = keccak256("INCENTIVES_CONTROLLER");
    uint256 private constant MONAD_MAINNET = 143;

    address private constant TREASURY_MONAD = 0x3377BAB9A510A586627D2f9013e132d269Eb9871;
    address private constant XK613_MONAD = 0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5;
    address private constant POOL_MONAD = 0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasuryAddr = TREASURY_MONAD;
        address xk613 = XK613_MONAD;

        address ap = address(IPool(POOL_MONAD).ADDRESSES_PROVIDER());
        address rcAddr = IPoolAddressesProvider(ap).getAddress(INCENTIVES_CONTROLLER_ID);
        require(rcAddr != address(0), "rewards controller zero");

        address oldStrategy = IRewardsController(rcAddr).getTransferStrategy(xk613);
        require(oldStrategy != address(0), "old strategy zero");

        address rewardsAdmin = ITransferStrategyBase(oldStrategy).getRewardsAdmin();
        address rewardsVault = IPullRewardsTransferStrategy(oldStrategy).getRewardsVault();
        address emissionManager = IRewardsController(rcAddr).getEmissionManager();

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
