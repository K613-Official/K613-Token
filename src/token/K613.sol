// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

contract K613 is ERC20, AccessControl, Pausable {
    error ZeroAddress();
    error OnlyMinter();

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address public minter;

    event MinterUpdated(address indexed previousMinter, address indexed newMinter);

    constructor(address initialMinter) ERC20("K613", "K613") {
        if (initialMinter == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        minter = initialMinter;
        _grantRole(MINTER_ROLE, initialMinter);
        emit MinterUpdated(address(0), initialMinter);
    }

    function setMinter(address newMinter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinter == address(0)) {
            revert ZeroAddress();
        }
        _revokeRole(MINTER_ROLE, minter);
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
        _grantRole(MINTER_ROLE, newMinter);
    }

    function mint(address to, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            revert OnlyMinter();
        }
        _burn(from, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _update(address from, address to, uint256 value) internal override {
        _requireNotPaused();
        super._update(from, to, value);
    }
}
