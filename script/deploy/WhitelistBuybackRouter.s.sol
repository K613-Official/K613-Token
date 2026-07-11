// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "src/treasury/Treasury.sol";

/// @title WhitelistBuybackRouter
/// @notice Adds Uniswap V3 SwapRouter02 (Monad mainnet) to the Treasury buyback router whitelist.
///         Without this, `Treasury.buybackV3ExactInputSingle` reverts with `RouterNotWhitelisted`.
///         Can be run at any time after the Treasury is deployed; must be run before the first buyback.
/// @dev Env interface: PRIVATE_KEY (must hold DEFAULT_ADMIN_ROLE on the Treasury).
///      The router and Treasury are hardcoded constants below. Idempotent: re-running is a no-op on-chain state.
contract WhitelistBuybackRouter is Script {
    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);
    /// @notice Reverts if the broadcaster lacks DEFAULT_ADMIN_ROLE on the Treasury.
    error BroadcasterNotTreasuryAdmin(address broadcaster);

    uint256 private constant MONAD_MAINNET = 143;

    /// @notice Uniswap V3 SwapRouter02 on Monad mainnet (see docs/OPERATIONS_SOP.md D.3).
    address private constant SWAP_ROUTER_02 = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;
    /// @notice Treasury on Monad mainnet, deployed 2026-07-11 (see docs/OPERATIONS_SOP.md D.1).
    address private constant TREASURY_MONAD = 0x3377BAB9A510A586627D2f9013e132d269Eb9871;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        Treasury treasury = Treasury(TREASURY_MONAD);

        if (!treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), broadcaster)) {
            revert BroadcasterNotTreasuryAdmin(broadcaster);
        }

        vm.startBroadcast(pk);
        treasury.setRouterWhitelist(SWAP_ROUTER_02, true);
        vm.stopBroadcast();

        require(treasury.routerWhitelist(SWAP_ROUTER_02), "router not whitelisted after call");

        console.log("Treasury:            ", address(treasury));
        console.log("Whitelisted router:  ", SWAP_ROUTER_02);
    }
}
