// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {
    PullRewardsTransferStrategy
} from "lib/K613-Protocol/src/contracts/rewards/transfer-strategies/PullRewardsTransferStrategy.sol";
import {ITransferStrategyBase} from "lib/K613-Protocol/src/contracts/rewards/interfaces/ITransferStrategyBase.sol";
import {
    IPullRewardsTransferStrategy
} from "lib/K613-Protocol/src/contracts/rewards/interfaces/IPullRewardsTransferStrategy.sol";
import {IPool} from "lib/K613-Protocol/src/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "lib/K613-Protocol/src/contracts/interfaces/IPoolAddressesProvider.sol";
import {IRewardsController} from "lib/K613-Protocol/src/contracts/rewards/interfaces/IRewardsController.sol";

/// @title DeployXk613PullStrategyV2
/// @notice Deploys the xK613 `PullRewardsTransferStrategy` that pulls from TreasuryV2. Deploy-only:
///         it wires nothing, so it can be run before the Safe cutover and its address pasted into
///         v2-cutover-2-switch.json.
///
/// @dev WHY NOT `InstallXk613PullStrategy.s.sol`
///      That script reads `rewardsVault` off the CURRENT strategy, which is TreasuryV1 — so it would
///      faithfully deploy another strategy pointing at the treasury being retired. It also calls
///      `approveXk613PullRewards` on the Treasury, which needs an admin role the deployer does not
///      have since the 2026-07-31 handover. Here the vault is stated explicitly and the approval is
///      left to the Safe batch.
///
/// @dev SEQUENCE — the order is the whole point:
///        1. this script            → new strategy exists, wired to nothing, harmless
///        2. Safe batch 2           → TreasuryV2 funded and `approveXk613PullRewards(newStrategy)`
///        3. setTransferStrategy    → emissions switch over, from the emission-admin key
///      Doing 3 before 2 points live emissions at a treasury that holds no xK613 and has granted no
///      allowance: every lender claim reverts until the batch lands.
///
/// @dev Env: PRIVATE_KEY (gas only — this script grants and needs no role).
///      `REWARDS_VAULT` defaults to the canonical TreasuryV2 and can be overridden for a rehearsal.
contract DeployXk613PullStrategyV2 is Script {
    error WrongNetwork(uint256 chainId);
    error NoExistingStrategy();

    bytes32 private constant INCENTIVES_CONTROLLER_ID = keccak256("INCENTIVES_CONTROLLER");
    uint256 private constant MONAD_MAINNET = 143;

    address private constant XK613 = 0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5;
    address private constant POOL = 0x4Ba3856a4d851d39C27e2E866daB7A95eF6e0113;
    /// @notice TreasuryV2, deployed 2026-08-07. The `REWARDS_VAULT` of the new strategy — immutable
    ///         once constructed, which is exactly why the old strategy cannot simply be repointed.
    address private constant TREASURY_V2 = 0x10aCE88f2F2c361218615F5dcA8987DD16C54282;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vault = vm.envOr("REWARDS_VAULT", TREASURY_V2);

        address ap = address(IPool(POOL).ADDRESSES_PROVIDER());
        address rc = IPoolAddressesProvider(ap).getAddress(INCENTIVES_CONTROLLER_ID);
        require(rc != address(0), "rewards controller zero");

        // Carry the rewards admin over from the live strategy rather than inventing one: whoever
        // can perform emergency withdrawals today should still be able to tomorrow.
        address oldStrategy = IRewardsController(rc).getTransferStrategy(XK613);
        if (oldStrategy == address(0)) revert NoExistingStrategy();
        address rewardsAdmin = ITransferStrategyBase(oldStrategy).getRewardsAdmin();
        address oldVault = IPullRewardsTransferStrategy(oldStrategy).getRewardsVault();

        vm.startBroadcast(pk);
        PullRewardsTransferStrategy strat = new PullRewardsTransferStrategy(rc, rewardsAdmin, vault);
        vm.stopBroadcast();

        require(IPullRewardsTransferStrategy(address(strat)).getRewardsVault() == vault, "vault mismatch");
        require(ITransferStrategyBase(address(strat)).getRewardsAdmin() == rewardsAdmin, "admin mismatch");
        // Nothing may have switched over yet.
        require(IRewardsController(rc).getTransferStrategy(XK613) == oldStrategy, "strategy switched too early");

        console.log("--- xK613 PullRewardsTransferStrategy V2 ---");
        console.log("  RewardsController:", rc);
        console.log("  rewardsAdmin     :", rewardsAdmin);
        console.log("  OLD strategy     :", oldStrategy);
        console.log("  OLD vault        :", oldVault);
        console.log("  NEW strategy     :", address(strat));
        console.log("  NEW vault        :", vault);
        console.log("");
        console.log("NOT LIVE. Paste the NEW strategy into <NEW_PULL_STRATEGY> in");
        console.log("docs/safe-batches/v2-cutover-2-switch.json, execute that batch, and only THEN run");
        console.log("EmissionManager.setTransferStrategy(xK613, newStrategy) from the emission admin key.");
    }
}
