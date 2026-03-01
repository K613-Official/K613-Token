// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

/// @title DeployK613
/// @notice Deploys K613 staking stack on Arbitrum Sepolia testnet. Whitelists Uniswap SwapRouter02 + UniversalRouter.
contract DeployK613 is Script {
    uint256 private constant LOCK_DURATION = 90 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant INSTANT_EXIT_PENALTY_BPS = 5000;

    uint256 private constant ARBITRUM_SEPOLIA = 421_614;

    // Uniswap on Arbitrum Sepolia (https://docs.uniswap.org/contracts/v3/reference/deployments/arbitrum-deployments)
    address private constant UNISWAP_SWAPROUTER02_ARB_SEPOLIA = 0x101F443B4d1b059569D643917553c771E1b9663E;
    address private constant UNISWAP_UNIVERSAL_ROUTER_ARB_SEPOLIA = 0x4A7b5Da61326A6379179b40d00F57E5bbDC962c2;

    function run() external {
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

        // RewardsDistributor: Staking gets REWARDS_NOTIFIER_ROLE (via setStaking)
        distributor.setStaking(address(staking));

        // RewardsDistributor: Treasury gets REWARDS_NOTIFIER_ROLE
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury));

        // Treasury: whitelist Uniswap routers for buyback (by chain)
        _whitelistRouters(treasury);

        vm.stopBroadcast();

        console.log("--- Deployment complete ---");
        _logSummary(address(k613), address(xk613), address(staking), address(distributor), address(treasury));
    }

    /// @notice Whitelists Uniswap SwapRouter02 and UniversalRouter for Arbitrum Sepolia
    function _whitelistRouters(Treasury treasury) internal {
        require(block.chainid == ARBITRUM_SEPOLIA, "DeployK613: Arbitrum Sepolia only");
        treasury.setRouterWhitelist(UNISWAP_SWAPROUTER02_ARB_SEPOLIA, true);
        treasury.setRouterWhitelist(UNISWAP_UNIVERSAL_ROUTER_ARB_SEPOLIA, true);
        console.log("  Treasury: whitelisted SwapRouter02 + UniversalRouter (Arbitrum Sepolia)");
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
