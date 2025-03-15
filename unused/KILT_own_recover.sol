// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract KILTToken is ERC20, Ownable {
    // Constants for token amounts (with 18 decimals)
    uint256 public constant TOTAL_SUPPLY = 290_560_000 * 10**18; // 290,560,000 tokens
    uint256 public constant OWNER_AMOUNT = 50_000_000 * 10**18;  // 50,000,000 tokens
    uint256 public constant MIGRATION_AMOUNT = TOTAL_SUPPLY - OWNER_AMOUNT; // 240,560,000 tokens

    // Migration contract address
    address public migrationContract;

    constructor(address _migrationContract) 
        ERC20("KILT Protocol", "KILT")
        Ownable(msg.sender)
    {
        require(_migrationContract != address(0), "Migration contract cannot be zero address");
        
        migrationContract = _migrationContract;

        // Mint tokens
        _mint(msg.sender, OWNER_AMOUNT);
        _mint(_migrationContract, MIGRATION_AMOUNT);
    }

    // Recovery function for tokens sent to contract by mistake
    function recoverTokens(address tokenAddress, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).transfer(owner(), amount);
    }

    // Recovery function for ETH sent to contract by mistake
    function recoverETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
