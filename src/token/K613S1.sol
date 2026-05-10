// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/// @title K613S1
/// @notice Non-transferable accounting token for the K613 Points Campaign Season 1.
/// @dev Minted by `K613S1Distributor` on Merkle claim and burned 1:1 by `K613SeasonClaim` when a holder converts allocation to K613 post-TGE. Holders cannot transfer or approve tokens; balances act as soulbound proof-of-participation until burn.
contract K613S1 is ERC20, AccessControl, Pausable {
    /// @notice Thrown when a non-minter calls mint.
    error OnlyMinter();
    /// @notice Thrown when a non-burner calls burnFrom.
    error OnlyBurner();
    /// @notice Thrown on any transfer or approve attempt; the token is non-transferable by design.
    error NonTransferable();

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Deploys K613S1 and grants `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` to the deployer.
    /// @dev Admin grants `MINTER_ROLE` to `K613S1Distributor` and `BURNER_ROLE` to `K613SeasonClaim` after their deployment.
    constructor() ERC20("K613 Season 1 Points", "K613S1") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    /// @notice Mints `amount` K613S1 to `to`. Restricted to `MINTER_ROLE`.
    function mint(address to, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        _mint(to, amount);
    }

    /// @notice Burns `amount` K613S1 from `from`. Restricted to `BURNER_ROLE`.
    /// @dev No allowance required - the burner is a trusted protocol contract (e.g. `K613SeasonClaim`) and the only path that consumes K613S1 balances.
    function burnFrom(address from, uint256 amount) external {
        if (!hasRole(BURNER_ROLE, msg.sender)) {
            revert OnlyBurner();
        }
        _burn(from, amount);
    }

    /// @notice Pauses all mint and burn operations. Only callable by `PAUSER_ROLE`.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes mint and burn operations. Only callable by `PAUSER_ROLE`.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Always reverts: K613S1 cannot be approved for transfer.
    function approve(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    /// @notice Always reverts: K613S1 cannot be transferred via `transferFrom`. Overridden ahead of the allowance check so callers see the semantic error rather than `ERC20InsufficientAllowance`.
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    /// @dev Allows only mints (from = address(0)) and burns (to = address(0)). Reverts on any transfer between non-zero addresses or while paused.
    function _update(address from, address to, uint256 value) internal override {
        _requireNotPaused();
        if (from != address(0) && to != address(0)) {
            revert NonTransferable();
        }
        super._update(from, to, value);
    }
}
