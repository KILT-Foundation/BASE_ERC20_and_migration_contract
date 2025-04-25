// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title KILTMigration
/// @notice Facilitates migration from an old KILT token to a new KILT token at a 1.75:1 ratio.
/// @dev Inherits from OpenZeppelin's Ownable, Pausable, and ReentrancyGuard for secure management.
contract KILTMigration is Ownable, Pausable, ReentrancyGuard {
    /// @notice The old KILT token contract (ERC-20).
    IERC20 public immutable oldToken;
    
    /// @notice The new KILT token contract (ERC-20).
    IERC20 public newToken;
    
    /// @notice Numerator for the exchange rate (175/100 = 1.75 new tokens per old token).
    uint256 public constant EXCHANGE_RATE_NUMERATOR = 175;
    
    /// @notice Denominator for the exchange rate.
    uint256 public constant EXCHANGE_RATE_DENOMINATOR = 100;
    
    /// @notice Indicates whether migration is active for non-whitelisted users.
    bool public isMigrationActive = true;
    
    /// @notice Timestamp after which remaining tokens can be swept to the treasury.
    uint256 public withdrawalAllowedAfter;
    
    /// @notice Treasury address to receive remaining tokens after the migration period.
    address public destinationAddress;
    
    /// @notice Mapping of addresses allowed to migrate when isMigrationActive is false.
    mapping(address => bool) public whitelist;
    
    /// @notice Standard burn address for old tokens.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Emitted when migration is toggled on or off.
    /// @param active Whether migration is active.
    event MigrationToggled(bool active);
    
    /// @notice Emitted when an address is added to or removed from the whitelist.
    /// @param account The address affected.
    /// @param status The new whitelist status (true = whitelisted, false = not whitelisted).
    event Whitelisted(address indexed account, bool status);
    
    /// @notice Emitted when the new token address is set.
    /// @param newToken The address of the new KILT token contract.
    event NewTokenUpdated(address newToken);
    
    /// @notice Emitted when the withdrawal delay is extended.
    /// @param newTimestamp The new timestamp for withdrawal allowance.
    event WithdrawalDelayExtended(uint256 newTimestamp);
    
    /// @notice Emitted when unrelated ERC-20 tokens are recovered.
    /// @param token The token contract address.
    /// @param amount The amount recovered.
    event TokensRecovered(address indexed token, uint256 amount);
    
    /// @notice Emitted when a user migrates tokens.
    /// @param user The address of the user migrating tokens.
    /// @param oldAmount The amount of old tokens burned.
    /// @param newAmount The amount of new tokens received.
    event TokensMigrated(address indexed user, uint256 oldAmount, uint256 newAmount);
    
    /// @notice Emitted when the contract is paused.
    /// @param owner The address of the owner who paused the contract.
    event ContractPaused(address indexed owner);
    
    /// @notice Emitted when the contract is unpaused.
    /// @param owner The address of the owner who unpaused the contract.
    event ContractUnpaused(address indexed owner);
    
    /// @notice Emitted when the treasury address is updated.
    /// @param destination The new treasury address.
    event DestinationAddressSet(address indexed destination);
    
    /// @notice Emitted when remaining tokens are swept to the treasury.
    /// @param treasury The treasury address receiving the tokens.
    /// @param amount The amount of tokens swept.
    event RemainingTokensSwept(address indexed treasury, uint256 amount);

    /// @notice Initializes the migration contract with old token, delay, and treasury.
    /// @param _oldToken Address of the old KILT token contract.
    /// @param delayInSeconds Seconds until sweeping/recovery is allowed.
    /// @param _treasuryAddress Address of the treasury for remaining tokens.
    constructor(address _oldToken, uint256 delayInSeconds, address _treasuryAddress) Ownable(msg.sender) {
        oldToken = IERC20(_oldToken);
        withdrawalAllowedAfter = block.timestamp + delayInSeconds;
        destinationAddress = _treasuryAddress;
        require(_treasuryAddress != address(0), "Invalid treasury address");
    }

    /// @notice Sets the new KILT token address (can only be set once).
    /// @param _newToken Address of the new KILT token contract.
    /// @dev Only callable by the owner; requires a valid ERC-20 token.
    function setNewToken(address _newToken) external onlyOwner {
        require(address(newToken) == address(0), "New token already set");
        require(_newToken != address(0), "Invalid token address");
        require(IERC20(_newToken).totalSupply() > 0, "Not a valid ERC-20 token");
        newToken = IERC20(_newToken);
        emit NewTokenUpdated(_newToken);
    }

    /// @notice Updates the treasury address.
    /// @param _treasuryAddress New treasury address.
    /// @dev Only callable by the owner; cannot be zero address.
    function setDestinationAddress(address _treasuryAddress) external onlyOwner {
        require(_treasuryAddress != address(0), "Invalid treasury address");
        destinationAddress = _treasuryAddress;
        emit DestinationAddressSet(_treasuryAddress);
    }

    /// @notice Toggles migration on or off for non-whitelisted users.
    /// @param active True to enable migration, false to disable.
    /// @dev Only callable by the owner.
    function toggleMigration(bool active) external onlyOwner {
        isMigrationActive = active;
        emit MigrationToggled(active);
    }

    /// @notice Adds or removes an address from the whitelist.
    /// @param account The address to update.
    /// @param status True to whitelist, false to remove.
    /// @dev Only callable by the owner.
    function setWhitelist(address account, bool status) external onlyOwner {
        whitelist[account] = status;
        emit Whitelisted(account, status);
    }

    /// @notice Pauses the contract, disabling migration and sweeping.
    /// @dev Only callable by the owner; emits ContractPaused.
    function pause() external onlyOwner {
        _pause();
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpauses the contract, enabling migration and sweeping.
    /// @dev Only callable by the owner; emits ContractUnpaused.
    function unpause() external onlyOwner {
        _unpause();
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Migrates old tokens to new tokens at a 1.75:1 ratio.
    /// @param amount The amount of old tokens to migrate.
    /// @dev Burns old tokens and transfers new tokens; requires approval and sufficient contract balance.
    function migrate(uint256 amount) external whenNotPaused nonReentrant {
        require(isMigrationActive || whitelist[msg.sender], "Migration off and not whitelisted");
        require(amount > 0, "Amount must be greater than 0");
        uint256 newTokenAmount = (amount * EXCHANGE_RATE_NUMERATOR) / EXCHANGE_RATE_DENOMINATOR;
        require(newTokenAmount > 0, "New token amount too small after conversion");
        require(newToken.balanceOf(address(this)) >= newTokenAmount, "Insufficient new token balance in contract");
        require(oldToken.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance for old tokens");

        require(oldToken.transferFrom(msg.sender, BURN_ADDRESS, amount), "Failed to burn old tokens from sender");
        require(newToken.transfer(msg.sender, newTokenAmount), "Failed to transfer new tokens to sender");
        emit TokensMigrated(msg.sender, amount, newTokenAmount);
    }

    /// @notice Sweeps remaining new tokens to the treasury after the delay.
    /// @dev Callable by anyone after withdrawalAllowedAfter; requires sufficient balance.
    function sweepToTreasury() external whenNotPaused {
        require(block.timestamp >= withdrawalAllowedAfter, "Sweep not yet allowed");
        uint256 remainingBalance = newToken.balanceOf(address(this));
        require(remainingBalance > 0, "No tokens to sweep");
        require(newToken.transfer(destinationAddress, remainingBalance), "Sweep to Treasury failed");
        emit RemainingTokensSwept(destinationAddress, remainingBalance);
    }

    /// @notice Extends the delay before sweeping or recovery is allowed.
    /// @param additionalSeconds Seconds to add to the current delay.
    /// @dev Only callable by the owner; cannot shorten the delay.
    function extendWithdrawalDelay(uint256 additionalSeconds) external onlyOwner {
        uint256 newTimestamp = withdrawalAllowedAfter + additionalSeconds;
        require(newTimestamp > withdrawalAllowedAfter, "Cannot shorten delay");
        withdrawalAllowedAfter = newTimestamp;
        emit WithdrawalDelayExtended(newTimestamp);
    }

    /// @notice Recovers unrelated ERC-20 tokens sent to the contract.
    /// @param token The token contract address to recover.
    /// @param amount The amount to recover.
    /// @dev Only callable by the owner after the delay; cannot recover newToken.
    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(block.timestamp >= withdrawalAllowedAfter, "Recovery not yet allowed");
        require(token != address(newToken), "Cannot recover newToken");
        require(IERC20(token).transfer(msg.sender, amount), "Token recovery failed");
        emit TokensRecovered(token, amount);
    }

    /// @notice Returns the exchange rate for migration.
    /// @return numerator The exchange rate numerator (175).
    /// @return denominator The exchange rate denominator (100).
    function getExchangeRate() external pure returns (uint256 numerator, uint256 denominator) {
        return (EXCHANGE_RATE_NUMERATOR, EXCHANGE_RATE_DENOMINATOR);
    }

    /// @notice Returns the current migration status and key parameters.
    /// @return active Whether migration is active for non-whitelisted users.
    /// @return paused Whether the contract is paused.
    /// @return withdrawalDelay Timestamp when sweeping/recovery is allowed.
    /// @return treasury The current treasury address.
    /// @return newTokenBalance The contract's balance of new tokens.
    function getMigrationStatus() external view returns (
        bool active,
        bool paused,
        uint256 withdrawalDelay,
        address treasury,
        uint256 newTokenBalance
    ) {
        return (
            isMigrationActive,
            paused(),
            withdrawalAllowedAfter,
            destinationAddress,
            newToken.balanceOf(address(this))
        );
    }

    /// @notice Reverts if ETH is sent directly to the contract.
    /// @dev Ensures the contract does not hold ETH unintentionally.
    receive() external payable {
        revert("Contract does not accept ETH");
    }

    /// @notice Reverts for unknown function calls.
    /// @dev Fallback for safety against unintended interactions.
    fallback() external payable {
        revert("Contract does not accept ETH");
    }
}
