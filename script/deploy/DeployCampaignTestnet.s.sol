// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613S1} from "src/token/K613S1.sol";
import {K613S1Distributor} from "src/campaign/K613S1Distributor.sol";

/// @title DeployCampaignTestnet
/// @notice Testnet-only deploy of the Season 1 points campaign (K613S1 + K613S1Distributor) on
///         Arbitrum Sepolia (chainId 421614).
/// @dev Deploys both contracts in one run and grants `K613S1.MINTER_ROLE` to the distributor. All
///      roles (K613S1 admin/pauser, Distributor admin/pauser/operator) intentionally remain on the
///      deployer EOA - the operator key posts weekly Merkle roots on testnet; on mainnet role
///      handover to a Safe is a separate step (see HandoverRoles).
contract DeployCampaignTestnet is Script {
    /// @notice Reverts if invoked on a chain other than Arbitrum Sepolia.
    error WrongNetwork(uint256 chainId);

    uint256 private constant ARBITRUM_SEPOLIA = 421614;

    /// @notice Starting `weeklyMintCap` for the distributor: 5M K613S1 per root update.
    uint256 private constant INITIAL_WEEKLY_MINT_CAP = 5_000_000e18;

    /// @notice Deployed K613S1 address. Set by `runWith` so tests can assert without log parsing.
    address public k613s1Addr;
    /// @notice Deployed K613S1Distributor address. Set by `runWith` so tests can assert without log parsing.
    address public distributorAddr;

    /// @notice Entrypoint for `forge script`. Reads the deployer key from the environment.
    function run() external {
        runWith(vm.envUint("PRIVATE_KEY"));
    }

    /// @notice Deploys K613S1 and K613S1Distributor and wires `MINTER_ROLE`. Used by `run()` and tests.
    /// @param deployerPrivateKey Deployer EOA key; receives all admin/pauser/operator roles.
    function runWith(uint256 deployerPrivateKey) public {
        if (block.chainid != ARBITRUM_SEPOLIA) revert WrongNetwork(block.chainid);

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        K613S1 k613s1 = new K613S1();
        console.log("K613S1:", address(k613s1));

        K613S1Distributor distributor = new K613S1Distributor(address(k613s1), INITIAL_WEEKLY_MINT_CAP);
        console.log("K613S1Distributor:", address(distributor));

        k613s1.grantRole(k613s1.MINTER_ROLE(), address(distributor));

        vm.stopBroadcast();

        k613s1Addr = address(k613s1);
        distributorAddr = address(distributor);

        _logSummary(address(k613s1), address(distributor), deployer);
    }

    function _logSummary(address k613s1_, address distributor_, address deployer_) internal pure {
        console.log("");
        console.log("--- Campaign TESTNET deployment complete (Arbitrum Sepolia 421614) ---");
        console.log("  K613S1:", k613s1_);
        console.log("  K613S1Distributor:", distributor_);
        console.log("");
        console.log("Roles:");
        console.log("  K613S1.MINTER_ROLE -> K613S1Distributor (granted in this run)");
        console.log("  K613S1.DEFAULT_ADMIN_ROLE / PAUSER_ROLE ->", deployer_);
        console.log("  Distributor.DEFAULT_ADMIN_ROLE / PAUSER_ROLE / OPERATOR_ROLE ->", deployer_);
        console.log("");
        console.log("NEXT STEP: operator posts the week-1 Merkle root via setMerkleRoot.");
    }
}
