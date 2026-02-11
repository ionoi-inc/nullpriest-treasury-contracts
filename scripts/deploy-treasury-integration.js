// SPDX-License-Identifier: MIT
/**
 * Deployment Script for TreasuryIntegration Contract
 * Network: Base Mainnet (Chain ID: 8453)
 * 
 * Prerequisites:
 * - Hardhat or Foundry configured for Base Mainnet
 * - Private key with ETH for gas fees
 * - OpenZeppelin contracts installed
 * 
 * Usage (Hardhat):
 *   npx hardhat run scripts/deploy-treasury-integration.js --network base
 * 
 * Usage (Foundry):
 *   forge script scripts/deploy-treasury-integration.js:DeployTreasuryIntegration --rpc-url base --broadcast --verify
 */

const { ethers, upgrades } = require("hardhat");

// Base Mainnet Configuration
const BASE_MAINNET = {
  chainId: 8453,
  rpcUrl: "https://mainnet.base.org",
  explorer: "https://basescan.org"
};

// NullPriest Contract Addresses (Base Mainnet)
const NULLPRIEST_ADDRESSES = {
  treasury: "0x0E050877dd25D67681fF2DA7eF75369c966288EC",
  daoCollective: "0x4601CC3262Eb011F0845e857363471906E687EF2",
  nulpToken: "0xE9859D90Ac8C026A759D9D0E6338AE7F9f66467F"
};

// Base Mainnet Token Addresses
const BASE_TOKENS = {
  USDC: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  WETH: "0x4200000000000000000000000000000000000006",
  DAI: "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb"
};

async function main() {
  console.log("=".repeat(60));
  console.log("TreasuryIntegration Deployment Script");
  console.log("Network: Base Mainnet");
  console.log("=".repeat(60));
  
  // Get deployer account
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  
  console.log("\n📋 Deployment Configuration:");
  console.log(`Deployer: ${deployerAddress}`);
  console.log(`Treasury: ${NULLPRIEST_ADDRESSES.treasury}`);
  
  // Check deployer balance
  const balance = await ethers.provider.getBalance(deployerAddress);
  console.log(`Balance: ${ethers.formatEther(balance)} ETH`);
  
  if (balance < ethers.parseEther("0.01")) {
    throw new Error("❌ Insufficient balance for deployment (need at least 0.01 ETH)");
  }
  
  console.log("\n🚀 Step 1: Deploying TreasuryIntegration proxy...");
  
  // Get contract factory
  const TreasuryIntegration = await ethers.getContractFactory("TreasuryIntegration");
  
  // Deploy upgradeable proxy
  const treasuryIntegration = await upgrades.deployProxy(
    TreasuryIntegration,
    [
      NULLPRIEST_ADDRESSES.treasury,  // Treasury address
      deployerAddress                  // Admin address
    ],
    {
      initializer: "initialize",
      kind: "uups"
    }
  );
  
  await treasuryIntegration.waitForDeployment();
  const proxyAddress = await treasuryIntegration.getAddress();
  
  console.log(`✅ Proxy deployed at: ${proxyAddress}`);
  
  // Get implementation address
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  console.log(`📦 Implementation: ${implementationAddress}`);
  
  console.log("\n🔧 Step 2: Configuring distribution thresholds...");
  
  // Set distribution thresholds for common tokens
  const thresholds = [
    { token: ethers.ZeroAddress, amount: ethers.parseEther("0.1"), symbol: "ETH" },
    { token: BASE_TOKENS.USDC, amount: 100_000000, symbol: "USDC" }, // 100 USDC (6 decimals)
    { token: BASE_TOKENS.WETH, amount: ethers.parseEther("0.1"), symbol: "WETH" },
    { token: BASE_TOKENS.DAI, amount: ethers.parseEther("100"), symbol: "DAI" }
  ];
  
  for (const threshold of thresholds) {
    try {
      const tx = await treasuryIntegration.setDistributionThreshold(
        threshold.token,
        threshold.amount
      );
      await tx.wait();
      console.log(`✅ Set ${threshold.symbol} threshold: ${threshold.amount.toString()}`);
    } catch (error) {
      console.log(`⚠️  ${threshold.symbol} threshold already set or failed: ${error.message}`);
    }
  }
  
  console.log("\n📊 Step 3: Verifying deployment...");
  
  // Verify configuration
  const treasuryAddr = await treasuryIntegration.treasury();
  const hasAdminRole = await treasuryIntegration.hasRole(
    await treasuryIntegration.DEFAULT_ADMIN_ROLE(),
    deployerAddress
  );
  
  console.log(`Treasury address: ${treasuryAddr}`);
  console.log(`Admin role granted: ${hasAdminRole}`);
  console.log(`Contract paused: ${await treasuryIntegration.paused()}`);
  
  console.log("\n🎯 Deployment Summary:");
  console.log("=".repeat(60));
  console.log(`Proxy Address: ${proxyAddress}`);
  console.log(`Implementation: ${implementationAddress}`);
  console.log(`Treasury: ${treasuryAddr}`);
  console.log(`Admin: ${deployerAddress}`);
  console.log("=".repeat(60));
  
  console.log("\n📝 Next Steps:");
  console.log("1. Verify contracts on BaseScan:");
  console.log(`   ${BASE_MAINNET.explorer}/address/${proxyAddress}`);
  console.log("\n2. Authorize market contracts:");
  console.log(`   await treasuryIntegration.setMarketAuthorization(marketAddress, true)`);
  console.log("\n3. Update market contracts to use TreasuryIntegration:");
  console.log(`   Set treasuryIntegration address in MarketFactory/BondingCurveMarket`);
  console.log("\n4. Test fee collection:");
  console.log(`   Make a test trade and verify fees are collected`);
  console.log("\n5. Monitor fee distribution:");
  console.log(`   Check pendingFees and auto-forwarding triggers`);
  
  // Save deployment info to file
  const deploymentInfo = {
    network: "base-mainnet",
    chainId: BASE_MAINNET.chainId,
    timestamp: new Date().toISOString(),
    contracts: {
      treasuryIntegration: {
        proxy: proxyAddress,
        implementation: implementationAddress
      }
    },
    config: {
      treasury: treasuryAddr,
      admin: deployerAddress,
      thresholds: thresholds.map(t => ({
        token: t.token,
        symbol: t.symbol,
        amount: t.amount.toString()
      }))
    }
  };
  
  console.log("\n💾 Saving deployment info...");
  const fs = require("fs");
  const path = require("path");
  
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }
  
  const filename = `treasury-integration-${Date.now()}.json`;
  fs.writeFileSync(
    path.join(deploymentsDir, filename),
    JSON.stringify(deploymentInfo, null, 2)
  );
  
  console.log(`✅ Deployment info saved to: deployments/${filename}`);
  
  console.log("\n✨ Deployment Complete!");
  
  return {
    proxyAddress,
    implementationAddress,
    treasuryAddress: treasuryAddr
  };
}

// Foundry Script Alternative
async function foundryDeploy() {
  console.log("Note: For Foundry deployment, use the following script:");
  console.log(`
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TreasuryIntegration.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployTreasuryIntegration is Script {
    address constant TREASURY = 0x0E050877dd25D67681fF2DA7eF75369c966288EC;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy implementation
        TreasuryIntegration implementation = new TreasuryIntegration();
        
        // Encode initializer
        bytes memory initData = abi.encodeWithSelector(
            TreasuryIntegration.initialize.selector,
            TREASURY,
            deployer
        );
        
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        
        console.log("Proxy:", address(proxy));
        console.log("Implementation:", address(implementation));
        
        vm.stopBroadcast();
    }
}

// Run with:
// forge script scripts/DeployTreasuryIntegration.s.sol:DeployTreasuryIntegration \\
//   --rpc-url base \\
//   --broadcast \\
//   --verify \\
//   --etherscan-api-key $BASESCAN_API_KEY
  `);
}

// Execute deployment
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = { main, foundryDeploy };
