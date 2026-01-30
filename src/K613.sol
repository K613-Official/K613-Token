// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract K613 is ERC20, Ownable {
    error ZeroAddress();
    error OnlyMinter();

    address public minter;

    event MinterUpdated(address indexed previousMinter, address indexed newMinter);

    constructor(address initialMinter) ERC20("K613", "K613") Ownable(msg.sender) {
        minter = initialMinter;
        emit MinterUpdated(address(0), initialMinter);
    }

    function setMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) {
            revert ZeroAddress();
        }
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) {
            revert OnlyMinter();
        }
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != minter) {
            revert OnlyMinter();
        }
        _burn(from, amount);
    }
}
