// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613} from "src/token/K613.sol";

/// @title PremintK613
/// @notice TGE one-shot: mints the entire MAX_SUPPLY (100M) to MINT_RECIPIENT in a single transaction.
///         Typically MINT_RECIPIENT == deployer EOA — the raw token has no value yet, so a Safe is not required
///         until distribution. After this runs, totalSupply() == cap(); further mint is permanently blocked by ERC20Capped.
/// @dev Caller (PRIVATE_KEY) must hold MINTER_ROLE on K613 at the time of broadcast. Intended to run exactly once.
contract PremintK613 is Script {
    error AlreadyMinted(uint256 currentSupply);
    error CallerLacksMinterRole(address caller);
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;

    /// @notice K613 on Monad mainnet, deployed 2026-07-10 (see docs/OPERATIONS_SOP.md D.1).
    address private constant K613_MONAD = 0xb09582631336068d4B0089d943f40CbF46dE5189;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);
        uint256 pk = vm.envUint("PRIVATE_KEY");
        // MINT_RECIPIENT is optional: defaults to the broadcaster EOA (the usual TGE flow).
        runWith(K613_MONAD, vm.envOr("MINT_RECIPIENT", vm.addr(pk)), pk);
    }

    /// @notice Direct entrypoint without env vars. Used by tests to avoid env-race conditions; production uses `run()`.
    function runWith(address k613Addr, address mintRecipient, uint256 pk) public {
        address caller = vm.addr(pk);

        K613 token = K613(k613Addr);
        uint256 amount = token.MAX_SUPPLY();

        if (token.totalSupply() != 0) {
            revert AlreadyMinted(token.totalSupply());
        }
        if (!token.hasRole(token.MINTER_ROLE(), caller)) {
            revert CallerLacksMinterRole(caller);
        }

        vm.startBroadcast(pk);
        token.mint(mintRecipient, amount);
        vm.stopBroadcast();

        console.log("=== K613 TGE Premint ===");
        console.log("Token:           ", k613Addr);
        console.log("Recipient:       ", mintRecipient);
        console.log("Caller (minter): ", caller);
        console.log("Minted (wei):    ", amount);
        console.log("Minted (K613):   ", amount / 1e18);
        console.log("Cap reached. Further mint is permanently blocked by ERC20Capped.");
    }
}
