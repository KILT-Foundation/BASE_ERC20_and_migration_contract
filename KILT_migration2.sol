// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract KILTMigration is Ownable, Pausable, ReentrancyGuard {
    IERC20 public immutable oldToken; // Old KILT token
    IERC20 public newToken; // New KILT token
    uint256 public constant EXCHANGE_RATE_NUMERATOR = 175; // 1.75 ratio
    uint256 public constant EXCHANGE_RATE_DENOMINATOR = 100;
    bool public isMigrationActive = true; // Starts active
    uint256 public withdrawalAllowedAfter; // Timestamp for withdrawal
    mapping(address => bool) public whitelist; // Dynamic whitelist
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD; // Common burn address

    event MigrationToggled(bool active);
    event Whitelisted(address indexed account, bool status);
    event NewTokenUpdated(address newToken);
    event WithdrawalDelayExtended(uint256 newTimestamp);
    event TokensRecovered(address indexed token, uint256 amount);
    event ETHRecovered(uint256 amount);
    event TokensMigrated(address indexed user, uint256 oldAmount, uint256 newAmount);
    event ContractPaused(address indexed owner);
    event ContractUnpaused(address indexed owner);

    constructor(address _oldToken, uint256 delayInSeconds) Ownable(msg.sender) {
        oldToken = IERC20(_oldToken);
        withdrawalAllowedAfter = block.timestamp + delayInSeconds;
    }

    // Validate newToken address
    function setNewToken(address _newToken) external onlyOwner {
        require(address(newToken) == address(0), "New token already set");
        require(_newToken != address(0), "Invalid token address");
        require(IERC20(_newToken).totalSupply() > 0, "Not a valid ERC-20 token"); // Basic validation
        newToken = IERC20(_newToken);
        emit NewTokenUpdated(_newToken);
    }

    // Toggle migration on/off (owner only)
    function toggleMigration(bool active) external onlyOwner {
        isMigrationActive = active;
        emit MigrationToggled(active);
    }

    // Add/remove from whitelist (owner only)
    function setWhitelist(address account, bool status) external onlyOwner {
        whitelist[account] = status;
        emit Whitelisted(account, status);
    }

    // Pause with event
    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender);
    }

    // Unpause with event
    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender);
    }

    // Prevent overflows and clearer error messages in migrate
    function migrate(uint256 amount) external whenNotPaused nonReentrant {
        require(isMigrationActive || whitelist[msg.sender], "Migration off and not whitelisted");
        require(amount > 0, "Amount must be greater than 0");
        uint256 newTokenAmount = (amount * EXCHANGE_RATE_NUMERATOR) / EXCHANGE_RATE_DENOMINATOR;
        require(newTokenAmount > 0, "New token amount too small after conversion");
        require(newToken.balanceOf(address(this)) >= newTokenAmount, "Insufficient new token balance in contract");
        require(oldToken.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance for old tokens");

        // Burn old tokens first (external call to oldToken)
        require(oldToken.transferFrom(msg.sender, BURN_ADDRESS, amount), "Failed to burn old tokens from sender");
        // Then transfer new tokens (external call to newToken)
        require(newToken.transfer(msg.sender, newTokenAmount), "Failed to transfer new tokens to sender");
        emit TokensMigrated(msg.sender, amount, newTokenAmount);
    }

    // Withdraw newKILT (owner only, after delay)
    function withdrawNewTokens(uint256 amount) external onlyOwner whenNotPaused {
        require(block.timestamp >= withdrawalAllowedAfter, "Withdrawal not yet allowed");
        require(amount > 0, "Amount must be greater than 0");
        require(newToken.transfer(msg.sender, amount), "Withdrawal failed");
    }

    // Extend withdrawal delay (owner only, cannot shorten)
    function extendWithdrawalDelay(uint256 additionalSeconds) external onlyOwner {
        uint256 newTimestamp = withdrawalAllowedAfter + additionalSeconds;
        require(newTimestamp > withdrawalAllowedAfter, "Cannot shorten delay");
        withdrawalAllowedAfter = newTimestamp;
        emit WithdrawalDelayExtended(newTimestamp);
    }

    // Recover unrelated ERC-20 tokens (owner only, after delay)
    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(block.timestamp >= withdrawalAllowedAfter, "Recovery not yet allowed");
        require(token != address(newToken), "Cannot recover newToken");
        require(IERC20(token).transfer(msg.sender, amount), "Token recovery failed");
        emit TokensRecovered(token, amount);
    }

    // Recover ETH (owner only, after delay)
    function recoverETH() external onlyOwner {
        require(block.timestamp >= withdrawalAllowedAfter, "Recovery not yet allowed");
        uint256 balance = address(this).balance;
        (bool sent, ) = msg.sender.call{value: balance}("");
        require(sent, "ETH recovery failed");
        emit ETHRecovered(balance);
    }

    // Make exchange rate publicly verifiable
    function getExchangeRate() external pure returns (uint256 numerator, uint256 denominator) {
        return (EXCHANGE_RATE_NUMERATOR, EXCHANGE_RATE_DENOMINATOR);
    }

    // Migration status view
    function getMigrationStatus() external view returns (
        bool active,
        bool paused,
        uint256 withdrawalDelay,
        uint256 newTokenBalance
    ) {
        return (
            isMigrationActive,
            paused,
            withdrawalAllowedAfter,
            newToken.balanceOf(address(this))
        );
    }

    // Prevent ETH from being sent to the contract
    receive() external payable {
        revert("Contract does not accept ETH");
    }

    // Fallback function for safety
    fallback() external payable {
        revert("Contract does not accept ETH");
    }
}
