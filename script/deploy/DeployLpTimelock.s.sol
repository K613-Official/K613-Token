// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {K613LpTimelock} from "src/pol/K613LpTimelock.sol";

/// @title DeployLpTimelock
/// @notice Deploys the 365-day LP NFT timelock on Monad mainnet (chainId 143). Beneficiary is the
///         governance Safe: it can collect trading fees at any time and withdraw the position only
///         after the year is up. After deploy, lock the LP NFT with:
///           NPM.safeTransferFrom(<current owner>, <timelock>, <tokenId>)
/// @dev Env interface: PRIVATE_KEY only. NPM, Safe and the duration are hardcoded constants below.
contract DeployLpTimelock is Script {
    /// @notice Reverts if invoked on a chain other than Monad mainnet.
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;

    /// @notice Uniswap V3 NonfungiblePositionManager on Monad mainnet (docs/OPERATIONS_SOP.md D.3).
    address private constant NPM_MONAD = 0x7197E214c0b767cFB76Fb734ab638E2c192F4E53;
    /// @notice Governance Safe (2-of-3) — fee recipient and post-unlock owner.
    address private constant GOVERNANCE_SAFE = 0x7D5cF07621228a3D622b4695A1e28991E4620eBB;
    /// @notice Lock length per tokenomics: LP locked for one year.
    uint256 private constant LOCK_DURATION = 365 days;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        K613LpTimelock timelock = new K613LpTimelock(NPM_MONAD, GOVERNANCE_SAFE, LOCK_DURATION);
        vm.stopBroadcast();

        // Post-deploy validation against chain state.
        require(timelock.npm() == NPM_MONAD, "npm mismatch");
        require(timelock.beneficiary() == GOVERNANCE_SAFE, "beneficiary mismatch");
        require(timelock.unlockTime() > block.timestamp, "unlock in past");

        console.log("--- K613LpTimelock deployment complete (Monad mainnet 143) ---");
        console.log("  Timelock:   ", address(timelock));
        console.log("  Beneficiary:", GOVERNANCE_SAFE);
        console.log("  Unlock time:", timelock.unlockTime());
        console.log("");
        console.log("REMAINING MANUAL STEP - lock the LP NFT:");
        console.log("  cast send", NPM_MONAD);
        console.log("    \"safeTransferFrom(address,address,uint256)\" <owner> <timelock> <tokenId>");
    }
}
