// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613} from "src/token/K613.sol";
import {xK613} from "src/token/xK613.sol";
import {Staking} from "src/staking/Staking.sol";
import {RewardsDistributor} from "src/staking/RewardsDistributor.sol";
import {Treasury} from "src/treasury/Treasury.sol";

/// @title DeployK613
/// @notice Deploys K613 staking stack on Monad mainnet (chainId 143).
/// @dev Production parameters per gitbook tokenomics:
///        LOCK_DURATION = 90 days  (xK613 standard exit queue)
///        EPOCH_DURATION = 7 days  (RewardsDistributor weekly flush cadence)
///        INSTANT_EXIT_PENALTY_BPS = 5000  (50% — penalty redistributed to remaining holders)
///      The script reverts if not run on Monad mainnet to prevent accidental cross-network deploys.
contract DeployK613 is Script {
    uint256 private constant LOCK_DURATION = 90 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant INSTANT_EXIT_PENALTY_BPS = 5000;
    uint256 private constant MAX_EXIT_REQUESTS = 100;

    uint256 private constant MONAD_MAINNET = 143;

    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        // 1. K613
        K613 k613 = new K613(deployer);
        console.log("K613:", address(k613));

        // 2. xK613 minter = deployer
        xK613 xk613 = new xK613(deployer);
        console.log("xK613:", address(xk613));

        // 4. Staking (before RD so RD can reference it for penalty stake)
        Staking staking = new Staking(address(k613), address(xk613), LOCK_DURATION, INSTANT_EXIT_PENALTY_BPS);
        console.log("Staking:", address(staking));

        // 3. RewardsDistributor (stakingToken = xK613, rewardToken = xK613; penalties staked to get xK613)
        RewardsDistributor distributor =
            new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);
        console.log("RewardsDistributor:", address(distributor));

        // 5. Treasury (stakes K613→xK613, sends xK613 to RD for rewards)
        Treasury treasury = new Treasury(address(k613), address(xk613), address(staking), address(distributor));
        console.log("Treasury:", address(treasury));

        // xK613: only Staking as minter
        xk613.setMinter(address(staking));

        // xK613: whitelist RewardsDistributor and Staking
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(staking), true);
        // xK613: whitelist Treasury so it can send xK613 to RD (after staking K613)
        xk613.setTransferWhitelist(address(treasury), true);

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

        console.log("--- Deployment complete ---");
        _logSummary(address(k613), address(xk613), address(staking), address(distributor), address(treasury));
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

    function _logSummary(address k613_, address xk613_, address staking_, address distributor_, address treasury_)
        internal
        pure
    {
        console.log("");
        console.log("Deployed addresses:");
        console.log("  K613:              ", k613_);
        console.log("  xK613:             ", xk613_);
        console.log("  Staking:           ", staking_);
        console.log("  RewardsDistributor:", distributor_);
        console.log("  Treasury:          ", treasury_);
    }
}
