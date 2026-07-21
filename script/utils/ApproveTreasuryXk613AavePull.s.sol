// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {IPool} from "lib/K613-Protocol/src/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "lib/K613-Protocol/src/contracts/interfaces/IPoolAddressesProvider.sol";
import {IRewardsController} from "lib/K613-Protocol/src/contracts/rewards/interfaces/IRewardsController.sol";

/// @title ApproveTreasuryXk613AavePull
/// @notice One-shot approve after the initial incentives install (SOP 6.3): looks up the current
///         xK613 transfer strategy in the RewardsController and grants it an unlimited allowance
///         on the Treasury's xK613 via `approveXk613PullRewards`. Without this allowance every
///         lending-rewards claim reverts (the strategy pays users via `transferFrom(Treasury, ...)`).
/// @dev Env: PRIVATE_KEY only (must hold DEFAULT_ADMIN_ROLE on the Treasury). Monad mainnet
///      addresses are hardcoded constants below (docs/OPERATIONS_SOP.md D.1/D.2).
contract ApproveTreasuryXk613AavePull is Script {
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

        address ap = address(IPool(POOL_MONAD).ADDRESSES_PROVIDER());
        address rc = IPoolAddressesProvider(ap).getAddress(INCENTIVES_CONTROLLER_ID);
        address strategy = IRewardsController(rc).getTransferStrategy(XK613_MONAD);
        require(strategy != address(0), "getTransferStrategy zero");

        vm.startBroadcast(pk);
        Treasury(TREASURY_MONAD).approveXk613PullRewards(strategy, type(uint256).max);
        vm.stopBroadcast();

        console.log("Treasury:", TREASURY_MONAD);
        console.log("xK613 reward token:", XK613_MONAD);
        console.log("Pull strategy:", strategy);
        console.log("allowance set: type(uint256).max");
    }
}
