// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/TreasuryIntegration.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mock ERC20 token for testing
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockMarket
 * @notice Mock market contract for testing fee collection
 */
contract MockMarket {
    address public treasuryIntegration;
    
    constructor(address _treasuryIntegration) {
        treasuryIntegration = _treasuryIntegration;
    }
    
    function collectETHFee() external payable {
        ITreasuryIntegration(treasuryIntegration).collectFee{value: msg.value}(address(0), msg.value);
    }
    
    function collectERC20Fee(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(treasuryIntegration, amount);
        IERC20(token).transfer(treasuryIntegration, amount);
        ITreasuryIntegration(treasuryIntegration).collectFee(token, amount);
    }
}

/**
 * @title TreasuryIntegrationTest
 * @notice Foundry test suite for TreasuryIntegration contract
 */
contract TreasuryIntegrationTest is Test {
    TreasuryIntegration public implementation;
    TreasuryIntegration public treasuryIntegration;
    ERC1967Proxy public proxy;
    
    MockERC20 public usdc;
    MockERC20 public weth;
    MockMarket public market1;
    MockMarket public market2;
    
    address public admin = address(1);
    address public operator = address(2);
    address public pauser = address(3);
    address public upgrader = address(4);
    address public treasury = 0x0E050877dd25D67681fF2DA7eF75369c966288EC;
    address public unauthorized = address(5);
    
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    event FeeCollected(address indexed token, address indexed market, uint256 amount);
    event FeeForwarded(address indexed token, uint256 amount, address indexed recipient);
    event MarketAuthorizationUpdated(address indexed market, bool authorized);
    event ForwardingThresholdUpdated(address indexed token, uint256 threshold);
    
    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC");
        weth = new MockERC20("Wrapped Ether", "WETH");
        
        // Deploy implementation
        implementation = new TreasuryIntegration();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            TreasuryIntegration.initialize.selector,
            admin
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        treasuryIntegration = TreasuryIntegration(payable(address(proxy)));
        
        // Setup roles
        vm.startPrank(admin);
        treasuryIntegration.grantRole(OPERATOR_ROLE, operator);
        treasuryIntegration.grantRole(PAUSER_ROLE, pauser);
        treasuryIntegration.grantRole(UPGRADER_ROLE, upgrader);
        vm.stopPrank();
        
        // Deploy mock markets
        market1 = new MockMarket(address(treasuryIntegration));
        market2 = new MockMarket(address(treasuryIntegration));
        
        // Authorize markets
        vm.startPrank(admin);
        treasuryIntegration.setMarketAuthorization(address(market1), true);
        treasuryIntegration.setMarketAuthorization(address(market2), true);
        vm.stopPrank();
        
        // Fund test accounts
        vm.deal(admin, 100 ether);
        vm.deal(address(market1), 10 ether);
        vm.deal(address(market2), 10 ether);
    }
    
    // ============ Initialization Tests ============
    
    function testInitialization() public {
        assertEq(treasuryIntegration.hasRole(DEFAULT_ADMIN_ROLE, admin), true);
        assertEq(treasuryIntegration.TREASURY_ADDRESS(), treasury);
        assertEq(treasuryIntegration.paused(), false);
    }
    
    function testCannotInitializeTwice() public {
        vm.expectRevert();
        treasuryIntegration.initialize(admin);
    }
    
    // ============ Market Authorization Tests ============
    
    function testSetMarketAuthorization() public {
        address newMarket = address(0x999);
        
        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit MarketAuthorizationUpdated(newMarket, true);
        treasuryIntegration.setMarketAuthorization(newMarket, true);
        vm.stopPrank();
        
        assertEq(treasuryIntegration.authorizedMarkets(newMarket), true);
    }
    
    function testBatchSetMarketAuthorization() public {
        address[] memory markets = new address[](3);
        bool[] memory authorizations = new bool[](3);
        
        markets[0] = address(0x100);
        markets[1] = address(0x200);
        markets[2] = address(0x300);
        authorizations[0] = true;
        authorizations[1] = true;
        authorizations[2] = false;
        
        vm.prank(admin);
        treasuryIntegration.batchSetMarketAuthorization(markets, authorizations);
        
        assertEq(treasuryIntegration.authorizedMarkets(address(0x100)), true);
        assertEq(treasuryIntegration.authorizedMarkets(address(0x200)), true);
        assertEq(treasuryIntegration.authorizedMarkets(address(0x300)), false);
    }
    
    function testOnlyAdminCanAuthorizeMarkets() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        treasuryIntegration.setMarketAuthorization(address(0x999), true);
    }
    
    // ============ ETH Fee Collection Tests ============
    
    function testCollectETHFee() public {
        uint256 feeAmount = 0.5 ether;
        
        vm.startPrank(address(market1));
        vm.expectEmit(true, true, false, true);
        emit FeeCollected(address(0), address(market1), feeAmount);
        treasuryIntegration.collectFee{value: feeAmount}(address(0), feeAmount);
        vm.stopPrank();
        
        assertEq(treasuryIntegration.getPendingFees(address(0)), feeAmount);
        assertEq(treasuryIntegration.getTotalFeesCollected(address(0)), feeAmount);
    }
    
    function testCollectETHFeeAutoForward() public {
        uint256 threshold = 0.1 ether;
        uint256 feeAmount = 0.15 ether;
        
        vm.prank(admin);
        treasuryIntegration.setForwardingThreshold(address(0), threshold);
        
        uint256 treasuryBalanceBefore = treasury.balance;
        
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: feeAmount}(address(0), feeAmount);
        
        // Should auto-forward since amount >= threshold
        assertEq(treasuryIntegration.getPendingFees(address(0)), 0);
        assertEq(treasury.balance - treasuryBalanceBefore, feeAmount);
    }
    
    function testUnauthorizedMarketCannotCollectFee() public {
        vm.prank(unauthorized);
        vm.expectRevert("Not authorized market");
        treasuryIntegration.collectFee{value: 1 ether}(address(0), 1 ether);
    }
    
    // ============ ERC20 Fee Collection Tests ============
    
    function testCollectERC20Fee() public {
        uint256 feeAmount = 100 * 10**18;
        
        usdc.mint(address(market1), feeAmount);
        
        vm.startPrank(address(market1));
        usdc.approve(address(treasuryIntegration), feeAmount);
        usdc.transfer(address(treasuryIntegration), feeAmount);
        
        vm.expectEmit(true, true, false, true);
        emit FeeCollected(address(usdc), address(market1), feeAmount);
        treasuryIntegration.collectFee(address(usdc), feeAmount);
        vm.stopPrank();
        
        assertEq(treasuryIntegration.getPendingFees(address(usdc)), feeAmount);
    }
    
    function testCollectERC20FeeAutoForward() public {
        uint256 threshold = 50 * 10**18;
        uint256 feeAmount = 100 * 10**18;
        
        vm.prank(admin);
        treasuryIntegration.setForwardingThreshold(address(usdc), threshold);
        
        usdc.mint(address(market1), feeAmount);
        
        vm.startPrank(address(market1));
        usdc.approve(address(treasuryIntegration), feeAmount);
        usdc.transfer(address(treasuryIntegration), feeAmount);
        treasuryIntegration.collectFee(address(usdc), feeAmount);
        vm.stopPrank();
        
        assertEq(treasuryIntegration.getPendingFees(address(usdc)), 0);
        assertEq(usdc.balanceOf(treasury), feeAmount);
    }
    
    // ============ Manual Forwarding Tests ============
    
    function testForwardToTreasury() public {
        uint256 feeAmount = 1 ether;
        
        // Collect fee first
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: feeAmount}(address(0), feeAmount);
        
        uint256 treasuryBalanceBefore = treasury.balance;
        
        // Manual forward
        vm.prank(operator);
        vm.expectEmit(true, false, true, true);
        emit FeeForwarded(address(0), feeAmount, treasury);
        treasuryIntegration.forwardToTreasury(address(0));
        
        assertEq(treasuryIntegration.getPendingFees(address(0)), 0);
        assertEq(treasury.balance - treasuryBalanceBefore, feeAmount);
    }
    
    function testOnlyOperatorCanForward() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        treasuryIntegration.forwardToTreasury(address(0));
    }
    
    // ============ Batch Operations Tests ============
    
    function testBatchCollectFees() public {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        
        tokens[0] = address(0);
        tokens[1] = address(usdc);
        amounts[0] = 0.5 ether;
        amounts[1] = 50 * 10**18;
        
        usdc.mint(address(market1), amounts[1]);
        
        vm.startPrank(address(market1));
        usdc.approve(address(treasuryIntegration), amounts[1]);
        usdc.transfer(address(treasuryIntegration), amounts[1]);
        
        treasuryIntegration.batchCollectFees{value: amounts[0]}(tokens, amounts);
        vm.stopPrank();
        
        assertEq(treasuryIntegration.getPendingFees(address(0)), amounts[0]);
        assertEq(treasuryIntegration.getPendingFees(address(usdc)), amounts[1]);
    }
    
    function testBatchForwardToTreasury() public {
        // Setup fees
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: 1 ether}(address(0), 1 ether);
        
        usdc.mint(address(market1), 100 * 10**18);
        vm.startPrank(address(market1));
        usdc.approve(address(treasuryIntegration), 100 * 10**18);
        usdc.transfer(address(treasuryIntegration), 100 * 10**18);
        treasuryIntegration.collectFee(address(usdc), 100 * 10**18);
        vm.stopPrank();
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(usdc);
        
        vm.prank(operator);
        treasuryIntegration.batchForwardToTreasury(tokens);
        
        assertEq(treasuryIntegration.getPendingFees(address(0)), 0);
        assertEq(treasuryIntegration.getPendingFees(address(usdc)), 0);
    }
    
    // ============ Threshold Management Tests ============
    
    function testSetForwardingThreshold() public {
        uint256 newThreshold = 0.5 ether;
        
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ForwardingThresholdUpdated(address(0), newThreshold);
        treasuryIntegration.setForwardingThreshold(address(0), newThreshold);
        
        assertEq(treasuryIntegration.forwardingThresholds(address(0)), newThreshold);
    }
    
    function testShouldAutoForward() public {
        uint256 threshold = 0.1 ether;
        
        vm.prank(admin);
        treasuryIntegration.setForwardingThreshold(address(0), threshold);
        
        // Below threshold
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: 0.05 ether}(address(0), 0.05 ether);
        assertEq(treasuryIntegration.shouldAutoForward(address(0)), false);
        
        // At threshold
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: 0.05 ether}(address(0), 0.05 ether);
        assertEq(treasuryIntegration.shouldAutoForward(address(0)), true);
    }
    
    // ============ Pause Tests ============
    
    function testPause() public {
        vm.prank(pauser);
        treasuryIntegration.pause();
        
        assertEq(treasuryIntegration.paused(), true);
    }
    
    function testUnpause() public {
        vm.prank(pauser);
        treasuryIntegration.pause();
        
        vm.prank(admin);
        treasuryIntegration.unpause();
        
        assertEq(treasuryIntegration.paused(), false);
    }
    
    function testCannotCollectWhenPaused() public {
        vm.prank(pauser);
        treasuryIntegration.pause();
        
        vm.prank(address(market1));
        vm.expectRevert();
        treasuryIntegration.collectFee{value: 1 ether}(address(0), 1 ether);
    }
    
    // ============ Emergency Withdrawal Tests ============
    
    function testEmergencyWithdraw() public {
        uint256 feeAmount = 1 ether;
        
        // Collect fee
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: feeAmount}(address(0), feeAmount);
        
        // Pause contract
        vm.prank(pauser);
        treasuryIntegration.pause();
        
        // Emergency withdraw
        address recipient = address(0x777);
        uint256 balanceBefore = recipient.balance;
        
        vm.prank(admin);
        treasuryIntegration.emergencyWithdraw(address(0), recipient, feeAmount);
        
        assertEq(recipient.balance - balanceBefore, feeAmount);
    }
    
    function testCannotEmergencyWithdrawWhenNotPaused() public {
        vm.prank(admin);
        vm.expectRevert();
        treasuryIntegration.emergencyWithdraw(address(0), address(0x777), 1 ether);
    }
    
    // ============ View Function Tests ============
    
    function testGetPendingFees() public {
        uint256 feeAmount = 1 ether;
        
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: feeAmount}(address(0), feeAmount);
        
        assertEq(treasuryIntegration.getPendingFees(address(0)), feeAmount);
    }
    
    function testGetTotalFeesCollected() public {
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: 1 ether}(address(0), 1 ether);
        
        vm.prank(address(market2));
        treasuryIntegration.collectFee{value: 0.5 ether}(address(0), 0.5 ether);
        
        assertEq(treasuryIntegration.getTotalFeesCollected(address(0)), 1.5 ether);
    }
    
    // ============ Upgradeability Tests ============
    
    function testUpgrade() public {
        TreasuryIntegration newImplementation = new TreasuryIntegration();
        
        vm.prank(upgrader);
        treasuryIntegration.upgradeToAndCall(address(newImplementation), "");
        
        // Verify state is preserved
        assertEq(treasuryIntegration.TREASURY_ADDRESS(), treasury);
        assertEq(treasuryIntegration.hasRole(DEFAULT_ADMIN_ROLE, admin), true);
    }
    
    function testOnlyUpgraderCanUpgrade() public {
        TreasuryIntegration newImplementation = new TreasuryIntegration();
        
        vm.prank(unauthorized);
        vm.expectRevert();
        treasuryIntegration.upgradeToAndCall(address(newImplementation), "");
    }
    
    // ============ Gas Usage Tests ============
    
    function testGasCollectETHFee() public {
        uint256 gasBefore = gasleft();
        
        vm.prank(address(market1));
        treasuryIntegration.collectFee{value: 0.1 ether}(address(0), 0.1 ether);
        
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used for collectFee (ETH)", gasUsed);
    }
    
    function testGasCollectERC20Fee() public {
        usdc.mint(address(market1), 100 * 10**18);
        
        vm.startPrank(address(market1));
        usdc.approve(address(treasuryIntegration), 100 * 10**18);
        usdc.transfer(address(treasuryIntegration), 100 * 10**18);
        
        uint256 gasBefore = gasleft();
        treasuryIntegration.collectFee(address(usdc), 100 * 10**18);
        uint256 gasUsed = gasBefore - gasleft();
        
        vm.stopPrank();
        
        emit log_named_uint("Gas used for collectFee (ERC20)", gasUsed);
    }
}
