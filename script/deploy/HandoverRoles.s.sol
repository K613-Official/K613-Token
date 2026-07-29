// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {K613} from "src/token/K613.sol";
import {xK613} from "src/token/xK613.sol";
import {Staking} from "src/staking/Staking.sol";
import {RewardsDistributor} from "src/staking/RewardsDistributor.sol";
import {Treasury} from "src/treasury/Treasury.sol";

/// @title HandoverRoles
/// @notice Phase 2.1 of TGE — atomically grants admin/pauser roles on the 5 K613 contracts to the
///         Governance Safe, then revokes the same roles from the original deployer EOA.
///         For K613 the MINTER_ROLE is rotated via `K613.setMinter(safe)` (atomic revoke+grant).
///         For xK613 the `minter` is intentionally NOT touched (it must stay on Staking).
/// @dev    Caller (PRIVATE_KEY) must currently hold DEFAULT_ADMIN_ROLE on all 5 contracts.
contract HandoverRoles is Script {
    error WrongNetwork(uint256 chainId);
    error ZeroAddress();
    error CallerLacksAdmin(address contract_, address caller);

    uint256 private constant MONAD_MAINNET = 143;

    // Monad mainnet, see docs/OPERATIONS_SOP.md D.1
    address private constant K613_MONAD = 0xb09582631336068d4B0089d943f40CbF46dE5189;
    address private constant XK613_MONAD = 0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5;
    address private constant STAKING_MONAD = 0x36451F6b4c06916aafd16359CCf99eB1f584DB0b;
    address private constant RD_MONAD = 0xE3E8925E8554464611c86419B9e99AD7Cd47428f;
    address private constant TREASURY_MONAD = 0x3377BAB9A510A586627D2f9013e132d269Eb9871;
    /// @notice Governance Safe (2-of-3).
    address private constant GOVERNANCE_SAFE = 0x7D5cF07621228a3D622b4695A1e28991E4620eBB;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);
        runWith(
            K613_MONAD, XK613_MONAD, STAKING_MONAD, RD_MONAD, TREASURY_MONAD, GOVERNANCE_SAFE, vm.envUint("PRIVATE_KEY")
        );
    }

    /// @notice Direct entrypoint without env vars. Used by tests; production uses `run()`.
    function runWith(
        address k613Addr,
        address xk613Addr,
        address stakingAddr,
        address rdAddr,
        address treasuryAddr,
        address govSafe,
        uint256 pk
    ) public {
        if (
            k613Addr == address(0) || xk613Addr == address(0) || stakingAddr == address(0) || rdAddr == address(0)
                || treasuryAddr == address(0) || govSafe == address(0)
        ) {
            revert ZeroAddress();
        }
        address deployer = vm.addr(pk);
        _assertAdmin(k613Addr, deployer);
        _assertAdmin(xk613Addr, deployer);
        _assertAdmin(stakingAddr, deployer);
        _assertAdmin(rdAddr, deployer);
        _assertAdmin(treasuryAddr, deployer);

        console.log("=== HandoverRoles ===");
        console.log("Deployer (caller):", deployer);
        console.log("Governance Safe:  ", govSafe);

        vm.startBroadcast(pk);

        // K613 — also rotate MINTER_ROLE via setMinter (atomic).
        _grantStandardRoles(k613Addr, govSafe);
        K613(k613Addr).setMinter(govSafe);
        _revokeStandardRoles(k613Addr, deployer);

        // xK613 — DO NOT touch setMinter (it must stay on Staking).
        _grantStandardRoles(xk613Addr, govSafe);
        _revokeStandardRoles(xk613Addr, deployer);

        // Staking
        _grantStandardRoles(stakingAddr, govSafe);
        _revokeStandardRoles(stakingAddr, deployer);

        // RewardsDistributor
        _grantStandardRoles(rdAddr, govSafe);
        _revokeStandardRoles(rdAddr, deployer);

        // Treasury
        _grantStandardRoles(treasuryAddr, govSafe);
        _revokeStandardRoles(treasuryAddr, deployer);

        vm.stopBroadcast();

        console.log("=== Handover complete ===");
        console.log("Verify on-chain that hasRole(DEFAULT_ADMIN_ROLE, deployer) == false on all 5 contracts.");
    }

    /// @dev Grants DEFAULT_ADMIN_ROLE and PAUSER_ROLE on `target` to `to`.
    function _grantStandardRoles(address target, address to) internal {
        IAccessControl(target).grantRole(0x00, to); // DEFAULT_ADMIN_ROLE
        IAccessControl(target).grantRole(_PAUSER_ROLE(), to);
    }

    /// @dev Revokes PAUSER_ROLE first then DEFAULT_ADMIN_ROLE — order matters: cannot revoke admin from self before other roles.
    function _revokeStandardRoles(address target, address from) internal {
        IAccessControl(target).revokeRole(_PAUSER_ROLE(), from);
        IAccessControl(target).revokeRole(0x00, from); // DEFAULT_ADMIN_ROLE
    }

    function _assertAdmin(address target, address account) internal view {
        if (!IAccessControl(target).hasRole(0x00, account)) {
            revert CallerLacksAdmin(target, account);
        }
    }

    function _PAUSER_ROLE() internal pure returns (bytes32) {
        return keccak256("PAUSER_ROLE");
    }
}
