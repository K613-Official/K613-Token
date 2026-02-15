// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

/// @title DeployK613
/// @notice Deploys K613 staking stack to Arbitrum Sepolia testnet
contract DeployK613 is Script {
    uint256 private constant LOCK_DURATION = 90 days;
    uint256 private constant EPOCH_DURATION = 7 days;
    uint256 private constant INSTANT_EXIT_PENALTY_BPS = 5000;

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

        // 3. RewardsDistributor
        RewardsDistributor distributor = new RewardsDistributor(address(xk613), EPOCH_DURATION);
        console.log("RewardsDistributor:", address(distributor));

        // 4. Staking
        Staking staking = new Staking(address(k613), address(xk613), LOCK_DURATION, INSTANT_EXIT_PENALTY_BPS);
        console.log("Staking:", address(staking));

        // 5. Treasury
        Treasury treasury = new Treasury(address(k613), address(xk613), address(distributor));
        console.log("Treasury:", address(treasury));

        // xK613: Staking as minter, Treasury also needs mint
        xk613.setMinter(address(staking));
        xk613.grantRole(xk613.MINTER_ROLE(), address(treasury));

        // xK613: whitelist RewardsDistributor for deposit/withdraw/claim transfers
        xk613.setTransferWhitelist(address(distributor), true);

        // Staking -> RewardsDistributor
        staking.setRewardsDistributor(address(distributor));

        // RewardsDistributor: Staking gets REWARDS_NOTIFIER_ROLE (via setStaking)
        distributor.setStaking(address(staking));

        // RewardsDistributor: Treasury gets REWARDS_NOTIFIER_ROLE
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury));

        vm.stopBroadcast();

        console.log("--- Deployment complete ---");
        _logSummary(address(k613), address(xk613), address(staking), address(distributor), address(treasury));
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
