// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/// @title K613
/// @notice ERC20 governance token with mint/burn capabilities and role-based access control.
/// @dev Extends ERC20 with MINTER_ROLE and PAUSER_ROLE. Supply is hard-capped at MAX_SUPPLY. All transfers are blocked when paused.
contract K613 is ERC20Capped, AccessControl, Pausable {
    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when a non-minter attempts to mint or burn tokens.
    error OnlyMinter();
    /// @notice Thrown when the burn amount exceeds the allowance.
    error BurnAmountExceedsAllowance();

    /// @notice Hard cap on total supply, enforced by ERC20Capped at every mint. 100,000,000 K613.
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Current address authorized to mint and burn tokens.
    address public minter;

    /// @notice Emitted when the minter address is updated.
    /// @param previousMinter The previous minter address.
    /// @param newMinter The new minter address.
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);

    /// @notice Deploys the K613 token with the initial minter.
    /// @param initialMinter Address that will be granted MINTER_ROLE for minting and burning.
    constructor(address initialMinter) ERC20("K613", "K613") ERC20Capped(MAX_SUPPLY) {
        if (initialMinter == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        minter = initialMinter;
        _grantRole(MINTER_ROLE, initialMinter);
        emit MinterUpdated(address(0), initialMinter);
    }

    /// @notice Updates the minter address. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param newMinter The new address to grant MINTER_ROLE.
    function setMinter(address newMinter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinter == address(0)) {
            revert ZeroAddress();
        }
        _revokeRole(MINTER_ROLE, minter);
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
        _grantRole(MINTER_ROLE, newMinter);
    }

    /// @notice Mints new tokens to the specified address.
    /// @param to Recipient of the minted tokens.
    /// @param amount Amount of tokens to mint.
    function mint(address to, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        _mint(to, amount);
    }

    /// @notice Burns tokens from the specified address.
    /// @dev Caller must have MINTER_ROLE and allowance from the token holder, mirroring standard ERC20 burnFrom semantics.
    /// @param from Address to burn tokens from.
    /// @param amount Amount of tokens to burn.
    function burnFrom(address from, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        uint256 currentAllowance = allowance(from, msg.sender);
        if (currentAllowance < amount) {
            revert BurnAmountExceedsAllowance();
        }
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    /// @notice Pauses all token transfers. Only callable by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes token transfers. Only callable by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev Overrides _update to enforce pause state and supply cap. All transfers revert when paused; mints above MAX_SUPPLY revert via ERC20Capped.
    function _update(address from, address to, uint256 value) internal override(ERC20Capped) {
        _requireNotPaused();
        super._update(from, to, value);
    }
}
