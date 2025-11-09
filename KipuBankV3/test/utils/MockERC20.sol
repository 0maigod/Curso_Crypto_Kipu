// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/// @title MockERC20 - Token ERC20 simple para pruebas

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is IERC20 {
    // Metadatos (opcionales para tests)
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    // Storage compatible con IERC20
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    // ================= IERC20 =================

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ERC20: allowance");
        unchecked { allowance[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    // ============== Helpers de test ==============

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "ERC20: balance");
        unchecked { balanceOf[from] = bal - amount; }
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ============== Internas ==============

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ERC20: to zero");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "ERC20: balance");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
