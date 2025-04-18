// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Token is ERC20Upgradeable, OwnableUpgradeable {
    function initialize(
        string memory _name,
        string memory _symbol
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __Ownable_init(msg.sender);
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function burn(address to, uint256 amount) public onlyOwner {
        _burn(to, amount);
    }
}
