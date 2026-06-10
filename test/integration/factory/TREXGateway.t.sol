// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { ITREXGateway } from "contracts/factory/ITREXGateway.sol";
import { TREXGateway } from "contracts/factory/TREXGateway.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { InterfaceIdCalculator } from "contracts/utils/InterfaceIdCalculator.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { TestERC20 } from "test/integration/mocks/TestERC20.sol";

contract TREXGatewayTest is TREXSuiteTest {

    TREXGateway public gateway;
    address public tokenAgent = makeAddr("tokenAgent");

    /// @notice Helper to create empty token details
    function _createEmptyTokenDetails() internal view returns (ITREXFactory.TokenDetails memory) {
        return ITREXFactory.TokenDetails({
            owner: deployer,
            name: "Token name",
            symbol: "SYM",
            decimals: 8,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0)
        });
    }

    /// @notice Helper to create empty claim details
    function _createEmptyClaimDetails() internal pure returns (ITREXFactory.ClaimDetails memory) {
        return ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
    }

    /// @notice Helper to deploy gateway and transfer ownership to deployer
    function _deployGateway(address factory, bool publicDeploymentStatus) internal returns (TREXGateway) {
        TREXGateway gateway_ = new TREXGateway(factory, publicDeploymentStatus);
        // Transfer ownership to deployer
        // Test contract is the initial owner so we transfer ownershhip to deployer
        gateway_.transferOwnership(deployer);
        return gateway_;
    }

    // ============================================
    // .setFactory Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_setFactory_RevertWhen_NotOwner() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        gateway.setFactory(address(trexFactory));
    }

    /// @notice Should revert when factory address is zero
    function test_setFactory_RevertWhen_FactoryAddressIsZero() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        gateway.setFactory(address(0));
    }

    /// @notice Should set factory when called by owner
    function test_setFactory_Success() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        assertEq(gateway.getFactory(), address(0));

        vm.expectEmit(true, false, false, false, address(gateway));
        emit EventsLib.FactorySet(address(trexFactory));
        vm.prank(deployer);
        gateway.setFactory(address(trexFactory));

        assertEq(gateway.getFactory(), address(trexFactory));
    }

    // ============================================
    // .setPublicDeploymentStatus Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_setPublicDeploymentStatus_RevertWhen_NotOwner() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        gateway.setPublicDeploymentStatus(true);
    }

    /// @notice Should revert when status doesn't change
    function test_setPublicDeploymentStatus_RevertWhen_StatusDoesntChange() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.PublicDeploymentAlreadyDisabled.selector);
        gateway.setPublicDeploymentStatus(false);

        vm.prank(deployer);
        gateway.setPublicDeploymentStatus(true);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.PublicDeploymentAlreadyEnabled.selector);
        gateway.setPublicDeploymentStatus(true);
    }

    /// @notice Should set new status when called by owner
    function test_setPublicDeploymentStatus_Success() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        assertEq(gateway.getPublicDeploymentStatus(), false);

        vm.expectEmit(true, false, false, false, address(gateway));
        emit EventsLib.PublicDeploymentStatusSet(true);
        vm.prank(deployer);
        gateway.setPublicDeploymentStatus(true);

        assertEq(gateway.getPublicDeploymentStatus(), true);
    }

    // ============================================
    // .transferFactoryOwnership Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_transferFactoryOwnership_RevertWhen_NotOwner() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        gateway.transferFactoryOwnership(another);
    }

    /// @notice Should transfer factory ownership when called by owner
    function test_transferFactoryOwnership_Success() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        assertEq(trexFactory.owner(), address(gateway));

        vm.prank(deployer);
        gateway.transferFactoryOwnership(alice);

        assertEq(trexFactory.owner(), alice);
    }

    // ============================================
    // .enableDeploymentFee Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_enableDeploymentFee_RevertWhen_NotOwner() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        gateway.enableDeploymentFee(true);
    }

    /// @notice Should revert when status doesn't change
    function test_enableDeploymentFee_RevertWhen_StatusDoesntChange() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.DeploymentFeesAlreadyDisabled.selector);
        gateway.enableDeploymentFee(false);

        vm.prank(deployer);
        gateway.enableDeploymentFee(true);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.DeploymentFeesAlreadyEnabled.selector);
        gateway.enableDeploymentFee(true);
    }

    /// @notice Should enable deployment fee when called by owner
    function test_enableDeploymentFee_Success() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        // Initially disabled
        assertFalse(gateway.isDeploymentFeeEnabled());

        vm.expectEmit(true, false, false, false, address(gateway));
        emit EventsLib.DeploymentFeeEnabled(true);
        vm.prank(deployer);
        gateway.enableDeploymentFee(true);

        // Verify it's now enabled
        assertTrue(gateway.isDeploymentFeeEnabled());
    }

    // ============================================
    // .setDeploymentFee Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_setDeploymentFee_RevertWhen_NotOwner() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        gateway.setDeploymentFee(10000, address(0), deployer);
    }

    /// @notice Should revert when fee token is zero address
    function test_setDeploymentFee_RevertWhen_FeeTokenIsZero() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        gateway.setDeploymentFee(10000, address(0), deployer);
    }

    /// @notice Should revert when fee collector is zero address
    function test_setDeploymentFee_RevertWhen_FeeCollectorIsZero() public {
        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        gateway.setDeploymentFee(10000, address(feeToken), address(0));
    }

    /// @notice Should set deployment fee when called by owner
    function test_setDeploymentFee_Success() public {
        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.expectEmit(true, true, true, false, address(gateway));
        emit EventsLib.DeploymentFeeSet(10000, address(feeToken), deployer);
        vm.prank(deployer);
        gateway.setDeploymentFee(10000, address(feeToken), deployer);

        // Verify fee was set correctly
        ITREXGateway.Fee memory fee = gateway.getDeploymentFee();
        assertEq(fee.fee, 10000);
        assertEq(fee.feeToken, address(feeToken));
        assertEq(fee.feeCollector, deployer);
    }

    // ============================================
    // .addDeployer Tests
    // ============================================

    /// @notice Should revert when called by not admin
    function test_addDeployer_RevertWhen_NotAdmin() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(another);
        vm.expectRevert(ErrorsLib.SenderIsNotAdmin.selector);
        gateway.addDeployer(another);
    }

    /// @notice Should revert when deployer already exists
    function test_addDeployer_RevertWhen_DeployerAlreadyExists() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        gateway.addDeployer(tokenAgent);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DeployerAlreadyExists.selector, tokenAgent));
        gateway.addDeployer(tokenAgent);
    }

    /// @notice Should add new deployer when called by owner
    function test_addDeployer_Success_WhenCalledByOwner() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        assertFalse(gateway.isDeployer(tokenAgent));

        vm.expectEmit(true, false, false, false, address(gateway));
        emit EventsLib.DeployerAdded(tokenAgent);
        vm.prank(deployer);
        gateway.addDeployer(tokenAgent);

        assertTrue(gateway.isDeployer(tokenAgent));
    }

    /// @notice Should add new deployer when called by agent
    function test_addDeployer_Success_WhenCalledByAgent() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        assertFalse(gateway.isDeployer(tokenAgent));

        vm.prank(deployer);
        gateway.addAgent(tokenAgent);

        vm.expectEmit(true, false, false, false, address(gateway));
        emit EventsLib.DeployerAdded(tokenAgent);
        vm.prank(tokenAgent);
        gateway.addDeployer(tokenAgent);

        assertTrue(gateway.isDeployer(tokenAgent));
    }

    // ============================================
    // .removeDeployer Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_removeDeployer_RevertWhen_NotOwner() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(another);
        vm.expectRevert(ErrorsLib.SenderIsNotAdmin.selector);
        gateway.removeDeployer(another);
    }

    /// @notice Should revert when deployer does not exist
    function test_removeDeployer_RevertWhen_DeployerDoesNotExist() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DeployerDoesNotExist.selector, tokenAgent));
        gateway.removeDeployer(tokenAgent);
    }

    /// @notice Should remove deployer when called by owner
    function test_removeDeployer_Success() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        gateway.addDeployer(tokenAgent);

        assertTrue(gateway.isDeployer(tokenAgent));

        vm.expectEmit(true, false, false, false, address(gateway));
        emit EventsLib.DeployerRemoved(tokenAgent);
        vm.prank(deployer);
        gateway.removeDeployer(tokenAgent);

        assertFalse(gateway.isDeployer(tokenAgent));
    }

    // ============================================
    // .applyFeeDiscount Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_applyFeeDiscount_RevertWhen_NotOwner() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(another);
        vm.expectRevert(ErrorsLib.SenderIsNotAdmin.selector);
        gateway.applyFeeDiscount(another, 5000);
    }

    /// @notice Should revert when discount out of range
    function test_applyFeeDiscount_RevertWhen_DiscountOutOfRange() public {
        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.DiscountOutOfRange.selector);
        gateway.applyFeeDiscount(another, 12000);
    }

    /// @notice Should apply discount when called by owner
    function test_applyFeeDiscount_Success() public {
        // Deploy a token to use as fee token BEFORE transferring ownership
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("sym", tokenDetails, claimDetails);
        address feeTokenAddress = trexFactory.getToken("sym");

        gateway = _deployGateway(address(0), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        gateway.setDeploymentFee(20000, feeTokenAddress, deployer);

        assertEq(gateway.calculateFee(bob), 20000);

        vm.expectEmit(true, false, false, false, address(gateway));
        emit EventsLib.FeeDiscountApplied(bob, 5000);
        vm.prank(deployer);
        gateway.applyFeeDiscount(bob, 5000);

        assertEq(gateway.calculateFee(bob), 10000); // 50% discount
    }

    // ============================================
    // .deployTREXSuite Tests
    // ============================================

    /// @notice Should revert when called by not deployer and public deployments disabled
    function test_deployTREXSuite_RevertWhen_NotDeployerAndPublicDisabled() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(another);
        vm.expectRevert(ErrorsLib.PublicDeploymentsNotAllowed.selector);
        gateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should revert when public deployments enabled but trying to deploy on behalf
    function test_deployTREXSuite_RevertWhen_PublicEnabledButOnBehalf() public {
        gateway = _deployGateway(address(trexFactory), true);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = bob; // Different from caller
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(another);
        vm.expectRevert(ErrorsLib.PublicCannotDeployOnBehalf.selector);
        gateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should deploy for free when public deployments enabled and fees not activated
    function test_deployTREXSuite_Success_PublicEnabledNoFees() public {
        gateway = _deployGateway(address(trexFactory), true);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(gateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 0);
        vm.prank(another);
        gateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should deploy with full fee when fees activated and no discount
    function test_deployTREXSuite_Success_FullFee() public {
        gateway = _deployGateway(address(trexFactory), true);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        gateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        gateway.enableDeploymentFee(true);

        vm.prank(another);
        feeToken.approve(address(gateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(gateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 20000);
        vm.prank(another);
        gateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 80000);
    }

    /// @notice Should deploy with 50% discount when caller has discount
    function test_deployTREXSuite_Success_HalfFeeWithDiscount() public {
        gateway = _deployGateway(address(trexFactory), true);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        gateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        gateway.enableDeploymentFee(true);

        vm.prank(deployer);
        gateway.applyFeeDiscount(another, 5000); // 50% discount

        vm.prank(another);
        feeToken.approve(address(gateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(gateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 10000);
        vm.prank(another);
        gateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 90000);
    }

    /// @notice Should deploy for free when deployer has 100% discount
    function test_deployTREXSuite_Success_DeployerFreeWithFullDiscount() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        gateway.addDeployer(another);

        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        gateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        gateway.enableDeploymentFee(true);

        vm.prank(deployer);
        gateway.applyFeeDiscount(another, 10000); // 100% discount

        vm.prank(another);
        feeToken.approve(address(gateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(gateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 0);
        vm.prank(another);
        gateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 100000); // No fee deducted
    }

    /// @notice Should deploy when called by deployer with public deployments disabled
    function test_deployTREXSuite_Success_WhenCalledByDeployer() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        gateway.addDeployer(another);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(gateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 0);
        vm.prank(another);
        gateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should deploy on behalf when called by deployer
    function test_deployTREXSuite_Success_DeployOnBehalf() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        gateway.addDeployer(another);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = bob; // Different from caller, but deployer can do this
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(gateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, bob, 0);
        vm.prank(another);
        gateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should deploy with full fee when deployer has no discount
    function test_deployTREXSuite_Success_DeployerFullFee() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        gateway.addDeployer(another);

        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        gateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        gateway.enableDeploymentFee(true);

        vm.prank(another);
        feeToken.approve(address(gateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(gateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 20000);
        vm.prank(another);
        gateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 80000);
    }

    /// @notice Should deploy with 50% discount when deployer has discount
    function test_deployTREXSuite_Success_DeployerHalfFeeWithDiscount() public {
        gateway = _deployGateway(address(trexFactory), false);
        vm.prank(deployer);
        trexFactory.transferOwnership(address(gateway));

        vm.prank(deployer);
        gateway.addDeployer(another);

        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        gateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        gateway.enableDeploymentFee(true);

        vm.prank(deployer);
        gateway.applyFeeDiscount(another, 5000); // 50% discount

        vm.prank(another);
        feeToken.approve(address(gateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(gateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 10000);
        vm.prank(another);
        gateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 90000);
    }

    // ============================================
    // .supportsInterface Tests
    // ============================================

    /// @notice Should return false for unsupported interfaces
    function test_supportsInterface_ReturnsFalse_ForUnsupportedInterface() public {
        gateway = _deployGateway(address(trexFactory), false);

        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(gateway.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the ITREXGateway interface ID
    function test_supportsInterface_ReturnsTrue_ForITREXGateway() public {
        gateway = _deployGateway(address(trexFactory), false);

        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getITREXGatewayInterfaceId();
        assertTrue(gateway.supportsInterface(interfaceId));
    }

    /// @notice Should correctly identify the IERC173 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC173() public {
        gateway = _deployGateway(address(trexFactory), false);

        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getIERC173InterfaceId();
        assertTrue(gateway.supportsInterface(interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public {
        gateway = _deployGateway(address(trexFactory), false);

        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getIERC165InterfaceId();
        assertTrue(gateway.supportsInterface(interfaceId));
    }

}
