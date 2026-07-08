// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613} from "src/token/K613.sol";
import {xK613} from "src/token/xK613.sol";

/// @title DeployTokensOnly
/// @notice Deploys only the two tokens (K613, xK613) on Monad mainnet (chainId 143) — the minimal
///         prerequisite for the public sale. Staking/RewardsDistributor/Treasury are NOT deployed.
/// @dev Both tokens get the deployer EOA as initial minter and DEFAULT_ADMIN/PAUSER. When the staking
///      stack is deployed later, re-wire with `xK613.setMinter(staking)` and hand roles to the Safe
///      (see HandoverRoles.s.sol). The script reverts off Monad mainnet to prevent cross-network deploys.
contract DeployTokensOnly is Script {
    uint256 private constant MONAD_MAINNET = 143;

    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        K613 k613 = new K613(deployer);
        xK613 xk613 = new xK613(deployer);

        vm.stopBroadcast();

        console.log("--- Token deployment complete (Monad mainnet 143) ---");
        console.log("  K613: ", address(k613));
        console.log("  xK613:", address(xk613));
        console.log("");
        console.log("Roles on both tokens (deployer EOA):");
        console.log("  DEFAULT_ADMIN_ROLE / PAUSER_ROLE / MINTER_ROLE ->", deployer);
        console.log("");
        console.log("Next steps for the sale:");
        console.log("  1. K613.mint(deployer, premint) or PremintK613.s.sol");
        console.log("  2. DeployPublicSale.s.sol (USDC_ADDRESS, K613_ADDRESS, SALE_START, SALE_END)");
        console.log("  3. K613.transfer(sale, saleAllocation) BEFORE saleStart");
        console.log("Later, with the staking stack: xK613.setMinter(staking) + HandoverRoles.s.sol");
    }
}
