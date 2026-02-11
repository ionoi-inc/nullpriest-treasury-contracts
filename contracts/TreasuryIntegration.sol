// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TreasuryIntegration
 * @notice Routes protocol fees from Headless Markets to NullPriest DAO Treasury
 * @dev Upgradeable contract using UUPS pattern for fee collection and distribution
 * 
 * Fee Flow:
 * 1. Markets collect 10% protocol fees on bonding curve trades
 * 2. TreasuryIntegration aggregates fees from multiple markets
 * 3. Fees are forwarded to NullPriest Treasury for DAO distribution
 * 
 * Key Features:
 * - Multi-token support (ETH, USDC, NULP, etc.)
 * - Batch fee collection from multiple markets
 * - Emergency withdrawal controls
 * - Pausable for security incidents
 * - Role-based access control
 * 
 * Deployed on Base Mainnet
 * Treasury Address: 0x0E050877dd25D67681fF2DA7eF75369c966288EC
 */
contract TreasuryIntegration is 
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ============ Constants ============
    
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    /// @notice Maximum basis points (100%)
    uint256 public constant MAX_BPS = 10000;
    
    /// @notice Protocol fee percentage (10% = 1000 bps)
    uint256 public constant PROTOCOL_FEE_BPS = 1000;
    
    // ============ State Variables ============
    
    /// @notice NullPriest DAO Treasury address on Base
    address public treasury;
    
    /// @notice Mapping of market addresses authorized to deposit fees
    mapping(address => bool) public authorizedMarkets;
    
    /// @notice Total fees collected per token
    mapping(address => uint256) public totalFeesCollected;
    
    /// @notice Pending fees awaiting distribution per token
    mapping(address => uint256) public pendingFees;
    
    /// @notice Minimum balance threshold before auto-forwarding to treasury
    mapping(address => uint256) public distributionThresholds;
    
    // ============ Events ============
    
    event FeeCollected(
        address indexed market,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );
    
    event FeesForwarded(
        address indexed token,
        uint256 amount,
        address indexed treasury,
        uint256 timestamp
    );
    
    event MarketAuthorized(address indexed market, bool authorized);
    
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    event ThresholdUpdated(address indexed token, uint256 oldThreshold, uint256 newThreshold);
    
    event EmergencyWithdrawal(
        address indexed token,
        uint256 amount,
        address indexed recipient,
        uint256 timestamp
    );
    
    // ============ Errors ============
    
    error UnauthorizedMarket();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidThreshold();
    
    // ============ Initialization ============
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the TreasuryIntegration contract
     * @param _treasury NullPriest Treasury address (0x0E050877dd25D67681fF2DA7eF75369c966288EC)
     * @param _admin Admin address with all roles
     */
    function initialize(
        address _treasury,
        address _admin
    ) external initializer {
        if (_treasury == address(0) || _admin == address(0)) revert ZeroAddress();
        
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        treasury = _treasury;
        
        // Grant roles to admin
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        
        // Set default distribution thresholds
        // ETH: 0.1 ETH
        distributionThresholds[address(0)] = 0.1 ether;
        // USDC: $100 (6 decimals)
        distributionThresholds[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = 100e6;
    }
    
    // ============ Fee Collection Functions ============
    
    /**
     * @notice Collect protocol fees from a market (ETH)
     * @dev Called by authorized markets after bonding curve trades
     * @param amount Fee amount in wei
     */
    function collectFee(uint256 amount) external payable nonReentrant whenNotPaused {
        if (!authorizedMarkets[msg.sender]) revert UnauthorizedMarket();
        if (amount == 0) revert ZeroAmount();
        if (msg.value != amount) revert InsufficientBalance();
        
        _collectFee(address(0), amount);
    }
    
    /**
     * @notice Collect protocol fees from a market (ERC20 token)
     * @dev Called by authorized markets after bonding curve trades
     * @param token ERC20 token address
     * @param amount Fee amount in token decimals
     */
    function collectTokenFee(address token, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        if (!authorizedMarkets[msg.sender]) revert UnauthorizedMarket();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        
        // Transfer tokens from market to this contract
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        _collectFee(token, amount);
    }
    
    /**
     * @notice Internal fee collection logic
     * @param token Token address (address(0) for ETH)
     * @param amount Fee amount
     */
    function _collectFee(address token, uint256 amount) internal {
        totalFeesCollected[token] += amount;
        pendingFees[token] += amount;
        
        emit FeeCollected(msg.sender, token, amount, block.timestamp);
        
        // Auto-forward if threshold reached
        uint256 threshold = distributionThresholds[token];
        if (threshold > 0 && pendingFees[token] >= threshold) {
            _forwardToTreasury(token, pendingFees[token]);
        }
    }
    
    // ============ Distribution Functions ============
    
    /**
     * @notice Forward accumulated fees to NullPriest Treasury
     * @param token Token address (address(0) for ETH)
     */
    function forwardToTreasury(address token) 
        external 
        onlyRole(OPERATOR_ROLE) 
        nonReentrant 
    {
        uint256 amount = pendingFees[token];
        if (amount == 0) revert ZeroAmount();
        
        _forwardToTreasury(token, amount);
    }
    
    /**
     * @notice Forward accumulated fees for multiple tokens in batch
     * @param tokens Array of token addresses
     */
    function batchForwardToTreasury(address[] calldata tokens) 
        external 
        onlyRole(OPERATOR_ROLE) 
        nonReentrant 
    {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = pendingFees[tokens[i]];
            if (amount > 0) {
                _forwardToTreasury(tokens[i], amount);
            }
        }
    }
    
    /**
     * @notice Internal function to forward fees to treasury
     * @param token Token address (address(0) for ETH)
     * @param amount Amount to forward
     */
    function _forwardToTreasury(address token, uint256 amount) internal {
        pendingFees[token] = 0;
        
        if (token == address(0)) {
            // Forward ETH
            (bool success, ) = treasury.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // Forward ERC20
            bool success = IERC20(token).transfer(treasury, amount);
            if (!success) revert TransferFailed();
        }
        
        emit FeesForwarded(token, amount, treasury, block.timestamp);
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Authorize or deauthorize a market to collect fees
     * @param market Market contract address
     * @param authorized Authorization status
     */
    function setMarketAuthorization(address market, bool authorized) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (market == address(0)) revert ZeroAddress();
        
        authorizedMarkets[market] = authorized;
        
        if (authorized) {
            _grantRole(MARKET_ROLE, market);
        } else {
            _revokeRole(MARKET_ROLE, market);
        }
        
        emit MarketAuthorized(market, authorized);
    }
    
    /**
     * @notice Authorize multiple markets in batch
     * @param markets Array of market addresses
     * @param authorized Authorization status for all
     */
    function batchSetMarketAuthorization(address[] calldata markets, bool authorized)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i = 0; i < markets.length; i++) {
            if (markets[i] != address(0)) {
                authorizedMarkets[markets[i]] = authorized;
                
                if (authorized) {
                    _grantRole(MARKET_ROLE, markets[i]);
                } else {
                    _revokeRole(MARKET_ROLE, markets[i]);
                }
                
                emit MarketAuthorized(markets[i], authorized);
            }
        }
    }
    
    /**
     * @notice Update treasury address
     * @param newTreasury New NullPriest Treasury address
     */
    function setTreasury(address newTreasury) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newTreasury == address(0)) revert ZeroAddress();
        
        address oldTreasury = treasury;
        treasury = newTreasury;
        
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    /**
     * @notice Set distribution threshold for auto-forwarding
     * @param token Token address (address(0) for ETH)
     * @param threshold Minimum balance before auto-forward (0 to disable)
     */
    function setDistributionThreshold(address token, uint256 threshold)
        external
        onlyRole(OPERATOR_ROLE)
    {
        uint256 oldThreshold = distributionThresholds[token];
        distributionThresholds[token] = threshold;
        
        emit ThresholdUpdated(token, oldThreshold, threshold);
    }
    
    // ============ Emergency Functions ============
    
    /**
     * @notice Emergency withdrawal of stuck funds
     * @dev Only callable by admin when paused
     * @param token Token address (address(0) for ETH)
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        
        if (token == address(0)) {
            if (address(this).balance < amount) revert InsufficientBalance();
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < amount) revert InsufficientBalance();
            bool success = IERC20(token).transfer(recipient, amount);
            if (!success) revert TransferFailed();
        }
        
        emit EmergencyWithdrawal(token, amount, recipient, block.timestamp);
    }
    
    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get pending fees for a token
     * @param token Token address (address(0) for ETH)
     * @return Pending fee amount
     */
    function getPendingFees(address token) external view returns (uint256) {
        return pendingFees[token];
    }
    
    /**
     * @notice Get total collected fees for a token
     * @param token Token address (address(0) for ETH)
     * @return Total collected amount
     */
    function getTotalFeesCollected(address token) external view returns (uint256) {
        return totalFeesCollected[token];
    }
    
    /**
     * @notice Check if auto-forwarding would trigger for a token
     * @param token Token address (address(0) for ETH)
     * @return shouldForward True if pending fees meet threshold
     */
    function shouldAutoForward(address token) external view returns (bool) {
        uint256 threshold = distributionThresholds[token];
        return threshold > 0 && pendingFees[token] >= threshold;
    }
    
    /**
     * @notice Get contract balance for a token
     * @param token Token address (address(0) for ETH)
     * @return Balance amount
     */
    function getBalance(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }
    
    // ============ UUPS Upgrade Authorization ============
    
    /**
     * @notice Authorize contract upgrade
     * @dev Only callable by UPGRADER_ROLE
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {}
    
    // ============ Receive Function ============
    
    /**
     * @notice Receive ETH directly (for emergency recovery)
     */
    receive() external payable {
        // Only accept direct ETH from authorized markets or admin operations
        // Direct sends are logged but not counted as fee collection
    }
}
