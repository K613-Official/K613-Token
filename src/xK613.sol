// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract xK613 is ERC20, Ownable {
    address public minter;

    event MinterUpdated(address indexed previousMinter, address indexed newMinter);

    constructor(address initialMinter) ERC20("xK613", "xK613") Ownable(msg.sender) {
        minter = initialMinter;
        emit MinterUpdated(address(0), initialMinter);
    }

    function setMinter(address newMinter) external onlyOwner {
        require(newMinter != address(0), "ZERO_ADDRESS");
        emit MinterUpdated(minter, newMinter);
        minter = newMinter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "ONLY_MINTER");
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(msg.sender == minter, "ONLY_MINTER");
        _burn(from, amount);
    }
}
