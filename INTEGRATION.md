# Integration Guide: TreasuryIntegration with Bonding Curve Markets

This guide demonstrates how to integrate the TreasuryIntegration contract with your Bonding Curve Market contracts to enable automated fee routing to the NullPriest DAO Treasury.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Contract Integration](#contract-integration)
3. [Market Authorization](#market-authorization)
4. [Fee Collection Patterns](#fee-collection-patterns)
5. [Testing Integration](#testing-integration)
6. [Production Deployment](#production-deployment)

---

## Quick Start

### Prerequisites

```bash
# Install dependencies
npm install @openzeppelin/contracts-upgradeable @openzeppelin/contracts

# Set environment variables
export TREASURY_INTEGRATION_ADDRESS="0x..." # Deployed proxy address
export PRIVATE_KEY="your_private_key"
export BASE_MAINNET_RPC_URL="https://mainnet.base.org"
```

### Basic Integration (5 Minutes)

```solidity
// 1. Import interface
import "./interfaces/ITreasuryIntegration.sol";

// 2. Add treasury integration reference
ITreasuryIntegration public treasuryIntegration;

// 3. Initialize in constructor
constructor(address _treasuryIntegration) {
    treasuryIntegration = ITreasuryIntegration(_treasuryIntegration);
}

// 4. Collect fees after trades
function _collectProtocolFee(address token, uint256 amount) internal {
    treasuryIntegration.collectFee(token, amount);
}
```

---

## Contract Integration

### Step 1: Create ITreasuryIntegration Interface

Create `contracts/interfaces/ITreasuryIntegration.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITreasuryIntegration {
    function collectFee(address token, uint256 amount) external payable;
    function collectAndForward(address token, uint256 amount) external payable;
    function batchCollectFees(address[] calldata tokens, uint256[] calldata amounts) external payable;
    function getPendingFees(address token) external view returns (uint256);
    function shouldAutoForward(address token) external view returns (bool);
}
```

### Step 2: Update Your Market Contract

#### Example 1: Simple Bonding Curve Market

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ITreasuryIntegration.sol";

contract BondingCurveMarket {
    ITreasuryIntegration public immutable treasuryIntegration;
    uint256 public constant PROTOCOL_FEE_BPS = 1000; // 10%
    
    constructor(address _treasuryIntegration) {
        require(_treasuryIntegration != address(0), "Invalid treasury");
        treasuryIntegration = ITreasuryIntegration(_treasuryIntegration);
    }
    
    function buy(uint256 amount) external payable {
        uint256 cost = calculateCost(amount);
        require(msg.value >= cost, "Insufficient payment");
        
        // Calculate protocol fee
        uint256 protocolFee = (cost * PROTOCOL_FEE_BPS) / 10000;
        uint256 netAmount = cost - protocolFee;
        
        // Execute trade logic
        _executeTrade(msg.sender, amount, netAmount);
        
        // Route protocol fee to treasury integration
        if (protocolFee > 0) {
            treasuryIntegration.collectFee{value: protocolFee}(address(0), protocolFee);
        }
        
        // Refund excess
        if (msg.value > cost) {
            payable(msg.sender).transfer(msg.value - cost);
        }
    }
    
    function sell(uint256 amount) external {
        uint256 proceeds = calculateProceeds(amount);
        
        // Calculate protocol fee
        uint256 protocolFee = (proceeds * PROTOCOL_FEE_BPS) / 10000;
        uint256 netProceeds = proceeds - protocolFee;
        
        // Execute trade logic
        _executeTrade(msg.sender, amount, netProceeds);
        
        // Route protocol fee
        if (protocolFee > 0) {
            treasuryIntegration.collectFee{value: protocolFee}(address(0), protocolFee);
        }
        
        // Send proceeds to seller
        payable(msg.sender).transfer(netProceeds);
    }
    
    function _executeTrade(address trader, uint256 amount, uint256 value) internal {
        // Your bonding curve logic here
    }
    
    function calculateCost(uint256 amount) public view returns (uint256) {
        // Your pricing logic here
    }
    
    function calculateProceeds(uint256 amount) public view returns (uint256) {
        // Your pricing logic here
    }
}
```

#### Example 2: Multi-Token Market with ERC20

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ITreasuryIntegration.sol";

contract MultiTokenMarket {
    using SafeERC20 for IERC20;
    
    ITreasuryIntegration public immutable treasuryIntegration;
    uint256 public constant PROTOCOL_FEE_BPS = 1000;
    
    mapping(address => bool) public supportedTokens;
    
    constructor(address _treasuryIntegration) {
        treasuryIntegration = ITreasuryIntegration(_treasuryIntegration);
    }
    
    function buyWithToken(address token, uint256 amount) external {
        require(supportedTokens[token], "Token not supported");
        
        uint256 cost = calculateTokenCost(token, amount);
        uint256 protocolFee = (cost * PROTOCOL_FEE_BPS) / 10000;
        uint256 netAmount = cost - protocolFee;
        
        // Transfer tokens from buyer
        IERC20(token).safeTransferFrom(msg.sender, address(this), cost);
        
        // Execute trade
        _executeTrade(msg.sender, amount, netAmount);
        
        // Route protocol fee
        if (protocolFee > 0) {
            IERC20(token).safeTransfer(address(treasuryIntegration), protocolFee);
            treasuryIntegration.collectFee(token, protocolFee);
        }
    }
    
    function calculateTokenCost(address token, uint256 amount) public view returns (uint256) {
        // Your pricing logic here
    }
    
    function _executeTrade(address trader, uint256 amount, uint256 value) internal {
        // Your bonding curve logic
    }
}
```

#### Example 3: Batch Fee Collection (Gas Optimized)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract OptimizedMultiMarket {
    ITreasuryIntegration public immutable treasuryIntegration;
    
    // Accumulate fees before forwarding
    mapping(address => uint256) private pendingFees;
    uint256 private pendingETHFees;
    
    uint256 public constant BATCH_THRESHOLD = 5; // Forward after 5 trades
    uint256 private tradeCount;
    
    function buy(uint256 amount) external payable {
        uint256 protocolFee = (msg.value * PROTOCOL_FEE_BPS) / 10000;
        
        // Accumulate fee
        pendingETHFees += protocolFee;
        tradeCount++;
        
        // Execute trade
        _executeTrade(msg.sender, amount, msg.value - protocolFee);
        
        // Batch forward when threshold reached
        if (tradeCount >= BATCH_THRESHOLD) {
            _forwardAccumulatedFees();
            tradeCount = 0;
        }
    }
    
    function buyWithToken(address token, uint256 amount) external {
        uint256 cost = calculateCost(token, amount);
        uint256 protocolFee = (cost * PROTOCOL_FEE_BPS) / 10000;
        
        IERC20(token).transferFrom(msg.sender, address(this), cost);
        
        // Accumulate fee
        pendingFees[token] += protocolFee;
        tradeCount++;
        
        _executeTrade(msg.sender, amount, cost - protocolFee);
        
        if (tradeCount >= BATCH_THRESHOLD) {
            _forwardAccumulatedFees();
            tradeCount = 0;
        }
    }
    
    function _forwardAccumulatedFees() internal {
        // Prepare batch arrays
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        
        tokens[0] = address(0); // ETH
        amounts[0] = pendingETHFees;
        
        tokens[1] = address(usdc); // Example: USDC
        amounts[1] = pendingFees[address(usdc)];
        
        // Transfer ERC20 fees to treasury integration
        if (amounts[1] > 0) {
            IERC20(usdc).transfer(address(treasuryIntegration), amounts[1]);
        }
        
        // Batch collect
        treasuryIntegration.batchCollectFees{value: amounts[0]}(tokens, amounts);
        
        // Reset accumulators
        pendingETHFees = 0;
        pendingFees[address(usdc)] = 0;
    }
    
    // Manual trigger for fee forwarding
    function forwardFees() external {
        _forwardAccumulatedFees();
        tradeCount = 0;
    }
}
```

---

## Market Authorization

### Authorize Your Market Contract

After deploying your market, it must be authorized to call `collectFee()`.

#### Using Hardhat Script

```javascript
// scripts/authorize-market.js
const hre = require("hardhat");

async function main() {
    const treasuryIntegrationAddress = process.env.TREASURY_INTEGRATION_ADDRESS;
    const marketAddress = process.env.MARKET_ADDRESS;
    
    const TreasuryIntegration = await hre.ethers.getContractAt(
        "TreasuryIntegration",
        treasuryIntegrationAddress
    );
    
    console.log("Authorizing market:", marketAddress);
    
    const tx = await TreasuryIntegration.setMarketAuthorization(marketAddress, true);
    await tx.wait();
    
    console.log("Market authorized! Transaction:", tx.hash);
    
    // Verify authorization
    const isAuthorized = await TreasuryIntegration.authorizedMarkets(marketAddress);
    console.log("Authorization status:", isAuthorized);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
```

Run: `npx hardhat run scripts/authorize-market.js --network base`

#### Batch Authorization (Multiple Markets)

```javascript
// scripts/batch-authorize-markets.js
async function main() {
    const markets = [
        "0x1234...", // Market 1
        "0x5678...", // Market 2
        "0x9abc...", // Market 3
    ];
    
    const authorizations = [true, true, true];
    
    const TreasuryIntegration = await hre.ethers.getContractAt(
        "TreasuryIntegration",
        process.env.TREASURY_INTEGRATION_ADDRESS
    );
    
    const tx = await TreasuryIntegration.batchSetMarketAuthorization(
        markets,
        authorizations
    );
    await tx.wait();
    
    console.log("Batch authorization complete!");
}
```

---

## Fee Collection Patterns

### Pattern 1: Immediate Collection (Simplest)

```solidity
function trade() external payable {
    uint256 fee = calculateFee(msg.value);
    treasuryIntegration.collectFee{value: fee}(address(0), fee);
}
```

**Pros:** Simple, immediate routing  
**Cons:** Higher gas per trade

### Pattern 2: Batch Collection (Gas Efficient)

```solidity
function trade() external payable {
    uint256 fee = calculateFee(msg.value);
    accumulatedFees += fee;
    
    if (accumulatedFees >= threshold) {
        treasuryIntegration.collectFee{value: accumulatedFees}(address(0), accumulatedFees);
        accumulatedFees = 0;
    }
}
```

**Pros:** Lower gas cost per trade  
**Cons:** Requires threshold management

### Pattern 3: Atomic Collect + Forward

```solidity
function trade() external payable {
    uint256 fee = calculateFee(msg.value);
    // Directly forward to treasury (skips pending accumulation)
    treasuryIntegration.collectAndForward{value: fee}(address(0), fee);
}
```

**Pros:** Direct routing, minimal state  
**Cons:** Slightly higher gas

---

## Testing Integration

### Local Testing with Hardhat

```javascript
// test/market-integration.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("Market Integration with TreasuryIntegration", function() {
    let treasuryIntegration, market;
    let admin, operator, treasury;
    
    beforeEach(async function() {
        [admin, operator, treasury] = await ethers.getSigners();
        
        // Deploy TreasuryIntegration
        const TreasuryIntegration = await ethers.getContractFactory("TreasuryIntegration");
        treasuryIntegration = await upgrades.deployProxy(
            TreasuryIntegration,
            [admin.address],
            { kind: "uups" }
        );
        
        // Deploy Market
        const Market = await ethers.getContractFactory("BondingCurveMarket");
        market = await Market.deploy(await treasuryIntegration.getAddress());
        
        // Authorize market
        await treasuryIntegration.setMarketAuthorization(await market.getAddress(), true);
    });
    
    it("Should collect fees on buy", async function() {
        const buyAmount = ethers.parseEther("1.0");
        
        await market.buy(100, { value: buyAmount });
        
        const pendingFees = await treasuryIntegration.getPendingFees(ethers.ZeroAddress);
        expect(pendingFees).to.be.gt(0);
    });
    
    it("Should auto-forward when threshold met", async function() {
        const threshold = ethers.parseEther("0.1");
        await treasuryIntegration.setForwardingThreshold(ethers.ZeroAddress, threshold);
        
        const treasuryBalanceBefore = await ethers.provider.getBalance(treasury.address);
        
        // Large trade that exceeds threshold
        await market.buy(1000, { value: ethers.parseEther("2.0") });
        
        const treasuryBalanceAfter = await ethers.provider.getBalance(treasury.address);
        expect(treasuryBalanceAfter).to.be.gt(treasuryBalanceBefore);
    });
});
```

### Foundry Integration Tests

```solidity
// test/MarketIntegration.t.sol
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/BondingCurveMarket.sol";
import "../contracts/TreasuryIntegration.sol";

contract MarketIntegrationTest is Test {
    TreasuryIntegration treasury;
    BondingCurveMarket market;
    
    function setUp() public {
        treasury = new TreasuryIntegration();
        market = new BondingCurveMarket(address(treasury));
        treasury.setMarketAuthorization(address(market), true);
    }
    
    function testFeeCollection() public {
        vm.deal(address(this), 10 ether);
        market.buy{value: 1 ether}(100);
        
        uint256 pending = treasury.getPendingFees(address(0));
        assertGt(pending, 0);
    }
}
```

---

## Production Deployment

### Deployment Checklist

#### Pre-Deployment

- [ ] TreasuryIntegration deployed and verified on Base
- [ ] Admin multisig configured
- [ ] Treasury address confirmed: `0x0E050877dd25D67681fF2DA7eF75369c966288EC`
- [ ] Market contracts audited
- [ ] Integration tests passing

#### Deployment Steps

1. **Deploy Market Contract**

```bash
npx hardhat run scripts/deploy-market.js --network base
```

2. **Authorize Market**

```bash
export MARKET_ADDRESS="0x..."
npx hardhat run scripts/authorize-market.js --network base
```

3. **Verify Contract**

```bash
npx hardhat verify --network base $MARKET_ADDRESS $TREASURY_INTEGRATION_ADDRESS
```

4. **Test on Testnet First**

```bash
# Deploy to Base Sepolia
npx hardhat run scripts/deploy-market.js --network base-sepolia

# Test with small trades
npx hardhat run scripts/test-integration.js --network base-sepolia
```

#### Post-Deployment

- [ ] Verify market authorization: `authorizedMarkets(marketAddress)`
- [ ] Test small trade (0.01 ETH)
- [ ] Monitor first fee collection event
- [ ] Verify fees forward to treasury
- [ ] Set up monitoring dashboard
- [ ] Document deployed addresses

### Monitoring Integration

```javascript
// scripts/monitor-fees.js
async function monitorFees() {
    const treasuryIntegration = await ethers.getContractAt(
        "TreasuryIntegration",
        process.env.TREASURY_INTEGRATION_ADDRESS
    );
    
    // Monitor FeeCollected events
    treasuryIntegration.on("FeeCollected", (token, market, amount, event) => {
        console.log("Fee collected:");
        console.log("  Token:", token);
        console.log("  Market:", market);
        console.log("  Amount:", ethers.formatEther(amount));
    });
    
    // Monitor FeeForwarded events
    treasuryIntegration.on("FeeForwarded", (token, amount, recipient, event) => {
        console.log("Fee forwarded:");
        console.log("  Token:", token);
        console.log("  Amount:", ethers.formatEther(amount));
        console.log("  Recipient:", recipient);
    });
}

monitorFees();
```

---

## Common Integration Issues

### Issue 1: "Not authorized market"

**Cause:** Market not authorized in TreasuryIntegration  
**Solution:** Call `setMarketAuthorization(marketAddress, true)` as admin

### Issue 2: Insufficient gas for collectFee

**Cause:** Gas limit too low for fee forwarding  
**Solution:** Increase gas limit or use batch collection pattern

### Issue 3: Auto-forward not triggering

**Cause:** Threshold not set or not reached  
**Solution:** Check `forwardingThresholds(token)` and `getPendingFees(token)`

### Issue 4: ERC20 transfer fails

**Cause:** Token not approved or insufficient balance  
**Solution:** Ensure `transfer()` before `collectFee()`, verify balances

---

## Support

- **Documentation:** [README.md](./README.md)
- **Issues:** GitHub Issues
- **Discord:** NullPriest Community

---

**Last Updated:** 2024-02-11
