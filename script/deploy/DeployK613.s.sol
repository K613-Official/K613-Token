// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613} from "src/token/K613.sol";
import {xK613} from "src/token/xK613.sol";
import {Staking} from "src/staking/Staking.sol";
import {RewardsDistributor} from "src/staking/RewardsDistributor.sol";
import {Treasury} from "src/treasury/Treasury.sol";

/// @title DeployK613
/// @notice Deploys the K613 staking stack (Staking, RewardsDistributor, Treasury) on Monad mainnet
///         (chainId 143) against the ALREADY DEPLOYED tokens, and wires roles/whitelists between them.
///         K613 and xK613 were deployed 2026-07-08 via DeployTokensOnly.s.sol and are referenced as
///         constants below — this script does NOT deploy tokens.
/// @dev Production parameters per gitbook tokenomics:
///        LOCK_DURATION = 90 days  (xK613 standard exit queue)
///        EPOCH_DURATION = 7 days  (RewardsDistributor weekly flush cadence)
///        INSTANT_EXIT_PENALTY_BPS = 5000  (50% — penalty redistributed to remaining holders)
///      The broadcaster must hold DEFAULT_ADMIN_ROLE on xK613 (it calls setMinter/setTransferWhitelist).
///      The script reverts if not run on Monad mainnet to prevent accidental cross-network deploys.
contract DeployK613 is Script {
    uint256 private constant LOCK_DURATION = 90 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant INSTANT_EXIT_PENALTY_BPS = 5000;
    uint256 private constant MAX_EXIT_REQUESTS = 100;

    uint256 private constant MONAD_MAINNET = 143;

    // Monad mainnet tokens, deployed 2026-07-08 (DeployTokensOnly.s.sol), see docs/OPERATIONS_SOP.md D.1
    K613 private constant K613_TOKEN = K613(0x708dC7ec281015f32f4778CCFad3450e168bCBC1);
    xK613 private constant XK613_TOKEN = xK613(0xED484CD4DF921deBfff9Da755b9E65f2a10C6a09);

    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);
    /// @notice Reverts if the broadcaster cannot wire the tokens (missing DEFAULT_ADMIN_ROLE on xK613).
    error BroadcasterNotTokenAdmin(address broadcaster);

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);
        console.log("K613 (existing): ", address(K613_TOKEN));
        console.log("xK613 (existing):", address(XK613_TOKEN));

        // Wiring below calls xK613.setMinter / setTransferWhitelist — admin only.
        if (!XK613_TOKEN.hasRole(XK613_TOKEN.DEFAULT_ADMIN_ROLE(), deployer)) {
            revert BroadcasterNotTokenAdmin(deployer);
        }

        vm.startBroadcast(deployerPrivateKey);

        // 1. Staking (before RD so RD can reference it for penalty stake)
        Staking staking =
            new Staking(address(K613_TOKEN), address(XK613_TOKEN), LOCK_DURATION, INSTANT_EXIT_PENALTY_BPS);
        console.log("Staking:", address(staking));

        // 2. RewardsDistributor (stakingToken = xK613, rewardToken = xK613; penalties staked to get xK613)
        RewardsDistributor distributor =
            new RewardsDistributor(address(XK613_TOKEN), address(XK613_TOKEN), address(K613_TOKEN), EPOCH_DURATION);
        console.log("RewardsDistributor:", address(distributor));

        // 3. Treasury (stakes K613→xK613, sends xK613 to RD for rewards)
        Treasury treasury =
            new Treasury(address(K613_TOKEN), address(XK613_TOKEN), address(staking), address(distributor));
        console.log("Treasury:", address(treasury));

        // xK613: only Staking as minter (replaces the deployer EOA left by DeployTokensOnly)
        XK613_TOKEN.setMinter(address(staking));

        // xK613: whitelist RewardsDistributor and Staking
        XK613_TOKEN.setTransferWhitelist(address(distributor), true);
        XK613_TOKEN.setTransferWhitelist(address(staking), true);
        // xK613: whitelist Treasury so it can send xK613 to RD (after staking K613)
        XK613_TOKEN.setTransferWhitelist(address(treasury), true);

        // Staking -> RewardsDistributor
        staking.setRewardsDistributor(address(distributor));
        staking.setMaxExitRequests(MAX_EXIT_REQUESTS);

        // System stakers: RD + Treasury back reward xK613 so users can redeemRewards
        staking.addSystemStaker(address(distributor));
        staking.addSystemStaker(address(treasury));

        // RewardsDistributor: Staking gets REWARDS_NOTIFIER_ROLE (via setStaking)
        distributor.setStaking(address(staking));

        // RewardsDistributor: Treasury gets REWARDS_NOTIFIER_ROLE
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury));

        _logTreasuryBuybackRouterNotice();

        vm.stopBroadcast();

        // Post-deploy validation against chain state.
        require(XK613_TOKEN.minter() == address(staking), "xK613 minter not Staking");
        require(XK613_TOKEN.transferWhitelist(address(distributor)), "RD not whitelisted");
        require(XK613_TOKEN.transferWhitelist(address(staking)), "Staking not whitelisted");
        require(XK613_TOKEN.transferWhitelist(address(treasury)), "Treasury not whitelisted");
        require(address(staking.rewardsDistributor()) == address(distributor), "Staking->RD link missing");
        require(distributor.hasRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury)), "Treasury not notifier");

        console.log("--- Deployment complete ---");
        _logSummary(address(staking), address(distributor), address(treasury));
    }

    function _logTreasuryBuybackRouterNotice() internal pure {
        console.log("Treasury.buybackV3ExactInputSingle calls exactInputSingle on Uniswap V3 SwapRouter02 (Monad).");
        console.log(
            "Monad mainnet SwapRouter02: 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900 (whitelist via Treasury.setRouterWhitelist)."
        );
        console.log(
            "Verified V3 contracts: Factory 0x204FAca1764B154221e35c0d20aBb3c525710498, NPM 0x7197E214c0b767cFB76Fb734ab638E2c192F4E53, QuoterV2 0x661E93cca42AfacB172121EF892830cA3b70F08d."
        );
    }

    function _logSummary(address staking_, address distributor_, address treasury_) internal pure {
        console.log("");
        console.log("Deployed addresses:");
        console.log("  K613 (existing):   ", address(K613_TOKEN));
        console.log("  xK613 (existing):  ", address(XK613_TOKEN));
        console.log("  Staking:           ", staking_);
        console.log("  RewardsDistributor:", distributor_);
        console.log("  Treasury:          ", treasury_);
        console.log("");
        console.log("Reminder: K613.minter is still the deployer EOA (needed for PremintK613).");
        console.log("Hand over roles to the Governance Safe via HandoverRoles.s.sol after TGE steps.");
    }
}
