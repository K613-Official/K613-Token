// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

interface IRewardsDistributor {
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external;
}

/// @title xK613
/// @notice Staking receipt token. Rewards accrue to holders (Aave-style). Calls handleAction on transfer/mint/burn.
/// @dev Transfers restricted to whitelist. Minting/burning by MINTER_ROLE. Calls RewardsDistributor.handleAction.
contract xK613 is ERC20, AccessControl, Pausable {
    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when a non-minter attempts to mint or burn tokens.
    error OnlyMinter();
    /// @notice Thrown when a transfer involves addresses not in the whitelist.
    error TransfersDisabled();

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Current address authorized to mint and burn tokens.
    address public minter;
    /// @notice RewardsDistributor address. If set, calls handleAction on every transfer/mint/burn.
    address public rewardsDistributor;
    /// @notice Mapping of addresses allowed to send and receive xK613.
    mapping(address => bool) public transferWhitelist;

    /// @notice Emitted when the minter address is updated.
    /// @param previousMinter The previous minter address.
    /// @param newMinter The new minter address.
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);
    /// @notice Emitted when an address is added to or removed from the transfer whitelist.
    /// @param account The address whose whitelist status changed.
    /// @param allowed Whether the address is now whitelisted.
    event TransferWhitelistUpdated(address indexed account, bool allowed);

    /// @notice Deploys the xK613 token with the initial minter.
    /// @param initialMinter Address that will be granted MINTER_ROLE for minting and burning.
    constructor(address initialMinter) ERC20("xK613", "xK613") {
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

    /// @notice Sets the RewardsDistributor. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param distributor_ RewardsDistributor address. Set to address(0) to disable.
    function setRewardsDistributor(address distributor_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardsDistributor = distributor_;
    }

    /// @notice Adds or removes an address from the transfer whitelist.
    /// @param account Address to update.
    /// @param allowed True to allow transfers, false to disallow.
    function setTransferWhitelist(address account, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        transferWhitelist[account] = allowed;
        emit TransferWhitelistUpdated(account, allowed);
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

    /// @notice Burns tokens from the specified address. Caller must have MINTER_ROLE.
    /// @param from Address to burn tokens from.
    /// @param amount Amount of tokens to burn.
    function burnFrom(address from, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
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

    /// @dev Overrides _update: enforce whitelist, pause, then call RewardsDistributor.handleAction on from/to.
    function _update(address from, address to, uint256 value) internal override {
        _requireNotPaused();
        if (from != address(0) && to != address(0)) {
            if (!transferWhitelist[from] && !transferWhitelist[to]) {
                revert TransfersDisabled();
            }
        }
        super._update(from, to, value);

        if (rewardsDistributor != address(0)) {
            uint256 supply = totalSupply();
            if (from != address(0) && from != rewardsDistributor) {
                IRewardsDistributor(rewardsDistributor).handleAction(from, supply, balanceOf(from));
            }
            if (to != address(0) && to != rewardsDistributor && from != rewardsDistributor) {
                IRewardsDistributor(rewardsDistributor).handleAction(to, supply, balanceOf(to));
            }
        }
    }
}
