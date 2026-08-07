// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {xK613} from "src/token/xK613.sol";
import {StakingV2} from "src/staking/StakingV2.sol";
import {RewardsDistributor} from "src/staking/RewardsDistributor.sol";
import {TreasuryV2} from "src/treasury/TreasuryV2.sol";
import {K613TreasuryOperatorV2} from "src/treasury/K613TreasuryOperatorV2.sol";

/// @title DeployK613V2Mainnet
/// @notice Deploys StakingV2 + TreasuryV2 + K613TreasuryOperatorV2 on Monad mainnet (143) and hands
///         every role to the governance Safe. Deploy-only: this script sends no transaction that
///         touches the live V1 stack.
///
/// @dev WHY THIS IS NOT A PORT OF DeployK613V2.s.sol
///      The Sepolia script does `xK613.setMinter(newStaking)`, mints 50M K613 and wires the
///      RewardsDistributor — none of which is reproducible here:
///
///      1. `setMinter` REVOKES the outgoing minter atomically. On Sepolia that was safe because the
///         contract being replaced held zero backing. StakingV1 on mainnet holds ~311,600 K613 of
///         real backing, and without MINTER_ROLE its `burnFrom` reverts — every `exit()` and every
///         `redeemRewards()` would revert and that backing would be stranded permanently. The
///         mainnet cutover deliberately accepts that stranding: the Safe seeds StakingV2 with K613
///         equal to `xK613.totalSupply()` and then calls `setMinter` in the same batch, so legacy
///         xK613 redeems against V2 and no window with two minters ever exists. That is a Safe
///         batch, not a script transaction — this script only deploys and hands over roles.
///      2. The deployer EOA holds no admin role anywhere on mainnet — verified on-chain: xK613,
///         K613, StakingV1, RewardsDistributor and TreasuryV1 all have DEFAULT_ADMIN_ROLE on the
///         Gov Safe only, after the 2026-07-31 handover. Any admin call from a forge broadcast
///         reverts.
///      3. K613 is capped at 100,000,000 and fully distributed. There is no reward-stock mint to
///         reproduce; TreasuryV2 is funded by moving TreasuryV1's existing balance.
///
///      What this script CAN do without the Safe is exactly what it does: deploy the three
///      contracts (the deployer is their own initial admin), configure them, then hand admin and
///      pauser to the Safe and renounce. The remaining steps are printed as a Safe batch.
///
/// @dev Env: PRIVATE_KEY only — the deployer needs gas and nothing else. It holds no role on the
///      live stack and ends the run holding none on the new one either. Every address this script
///      touches is a constant below.
///      Monad underestimates gas — broadcast with `-g 200`.
contract DeployK613V2Mainnet is Script {
    uint256 private constant MONAD_MAINNET = 143;

    /// @notice Production lock. The 20-second value in the Sepolia script exists so a tester can
    ///         walk the queue in under a minute; shipping it here would let anyone bypass the
    ///         instant-exit penalty by waiting one block.
    uint256 private constant LOCK_DURATION = 90 days;
    /// @notice Matches StakingV1's live value (read on-chain: 5000).
    uint256 private constant INSTANT_EXIT_PENALTY_BPS = 5000;
    uint256 private constant MAX_EXIT_REQUESTS = 100;

    // Live mainnet stack — docs/OPERATIONS_SOP.md D.1, cross-checked on-chain.
    address private constant K613 = 0xb09582631336068d4B0089d943f40CbF46dE5189;
    xK613 private constant XK613 = xK613(0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5);
    RewardsDistributor private constant REWARDS_DISTRIBUTOR =
        RewardsDistributor(0xE3E8925E8554464611c86419B9e99AD7Cd47428f);
    address private constant STAKING_V1 = 0x36451F6b4c06916aafd16359CCf99eB1f584DB0b;
    address private constant TREASURY_V1 = 0x3377BAB9A510A586627D2f9013e132d269Eb9871;
    address private constant GOV_SAFE = 0x7D5cF07621228a3D622b4695A1e28991E4620eBB;

    /// @notice Uniswap v3 SwapRouter02 — the only router TreasuryV2 needs whitelisted for buybacks.
    address private constant SWAP_ROUTER_02 = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;
    /// @notice K613/USD TWAP feed guarding operator buybacks. Same feed the live V1 operator uses.
    address private constant PRICE_FEED = 0x83002Fe57364Def515B5bbA326484bE2e220255E;

    /// @notice EOA that runs `script/ops/weekly.sh`, granted OPERATOR_ROLE on the new operator.
    ///         Same key that holds it on the live V1 operator, and the same key that holds
    ///         FUNDS_ADMIN on the Collector — which is why the weekly script gets by with one key.
    /// @dev A constant rather than an env var: it is a known mainnet address like every other one
    ///      here, and reading it from the environment only creates a way to deploy with the wrong
    ///      one. The Safe can move the role afterwards with grantRole/revokeRole at any time.
    address private constant OPERATOR = 0xF18Fcc2dCDCdc197B036b290BEcBeD692B9d2678;

    // Operator budgets carried over verbatim from the live V1 operator (0xEf22fb7C…), read on-chain.
    uint256 private constant TRANCHE_CAP = 600_000e18;
    uint256 private constant BUYBACK_CAP = 1_000e6;
    /// @notice Initial slippage tolerance, not a ceiling — the ceiling is the operator's own
    ///         `MAX_SLIPPAGE_BPS` (1000). Named apart so the two are not read as the same thing.
    uint256 private constant INITIAL_SLIPPAGE_BPS = 300;

    error WrongNetwork(uint256 chainId);
    /// @notice The whole point of the deployment: V1 must still be able to burn while it drains.
    error V1MinterRoleAlreadyLost();

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // If this ever fails, the cutover already went wrong and V1's backing is stranded — stop
        // rather than deploy a V2 that would look like the fix while the money is gone.
        if (!XK613.hasRole(XK613.MINTER_ROLE(), STAKING_V1)) revert V1MinterRoleAlreadyLost();

        uint256 v1Backing = StakingV2(STAKING_V1).totalBacking();
        uint256 v1TreasuryK613 = IERC20(K613).balanceOf(TREASURY_V1);
        uint256 v1TreasuryXk613 = IERC20(address(XK613)).balanceOf(TREASURY_V1);

        vm.startBroadcast(pk);

        StakingV2 staking = new StakingV2(K613, address(XK613), LOCK_DURATION, INSTANT_EXIT_PENALTY_BPS);
        TreasuryV2 treasury = new TreasuryV2(K613, address(XK613), address(staking), address(REWARDS_DISTRIBUTOR));
        K613TreasuryOperatorV2 operatorContract = new K613TreasuryOperatorV2(
            GOV_SAFE, OPERATOR, address(treasury), TRANCHE_CAP, BUYBACK_CAP, PRICE_FEED, INITIAL_SLIPPAGE_BPS
        );

        // Configuration the deployer can still do, because it is the initial admin of these three.
        staking.setRewardsDistributor(address(REWARDS_DISTRIBUTOR));
        staking.setMaxExitRequests(MAX_EXIT_REQUESTS);
        treasury.setRouterWhitelist(SWAP_ROUTER_02, true);

        // Operator needs Treasury admin to run the weekly tranche and buyback. Kill switch stays
        // with the Safe: TreasuryV2.revokeRole(0x00, operatorContract).
        treasury.grantRole(treasury.DEFAULT_ADMIN_ROLE(), address(operatorContract));

        // Handover, then renounce. Grant before renounce or the contracts end up unowned.
        staking.grantRole(staking.DEFAULT_ADMIN_ROLE(), GOV_SAFE);
        staking.grantRole(staking.PAUSER_ROLE(), GOV_SAFE);
        treasury.grantRole(treasury.DEFAULT_ADMIN_ROLE(), GOV_SAFE);
        treasury.grantRole(treasury.PAUSER_ROLE(), GOV_SAFE);

        staking.renounceRole(staking.PAUSER_ROLE(), deployer);
        staking.renounceRole(staking.DEFAULT_ADMIN_ROLE(), deployer);
        treasury.renounceRole(treasury.PAUSER_ROLE(), deployer);
        treasury.renounceRole(treasury.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        require(address(staking.k613()) == K613, "staking wired to wrong K613");
        require(address(staking.xk613()) == address(XK613), "staking wired to wrong xK613");
        require(staking.lockDuration() == LOCK_DURATION, "lock duration not 90 days");
        require(address(staking.rewardsDistributor()) == address(REWARDS_DISTRIBUTOR), "RD not wired");
        require(address(treasury.staking()) == address(staking), "treasury wired to wrong staking");
        require(address(operatorContract.TREASURY()) == address(treasury), "operator wired to wrong treasury");
        require(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), GOV_SAFE), "safe not staking admin");
        require(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), GOV_SAFE), "safe not treasury admin");
        require(!staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), deployer), "deployer still staking admin");
        require(!treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), deployer), "deployer still treasury admin");
        // Nothing above may have touched V1.
        require(StakingV2(STAKING_V1).totalBacking() == v1Backing, "V1 backing moved");
        require(XK613.minter() == STAKING_V1, "V1 minter changed");

        console.log("--- K613 V2 deployed (Monad mainnet 143), roles on Gov Safe ---");
        console.log("  StakingV2 :", address(staking));
        console.log("  TreasuryV2:", address(treasury));
        console.log("  OperatorV2:", address(operatorContract));
        console.log("");
        console.log("V1 state at deploy time (for the migration batch):");
        console.log("  StakingV1.totalBacking      :", v1Backing);
        console.log("  TreasuryV1 K613 (to move)   :", v1TreasuryK613);
        console.log("  TreasuryV1 xK613 (to redeem):", v1TreasuryXk613);
        console.log("");
        console.log("NOTHING IS LIVE YET. StakingV2 cannot mint until the Safe grants MINTER_ROLE.");
        console.log("Next: build the Safe batch - see docs/safe-batches/README.md, section 'V2 cutover'.");
    }
}
