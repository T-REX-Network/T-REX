// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ITREXGateway } from "contracts/factory/ITREXGateway.sol";
import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { TREXGateway } from "contracts/factory/TREXGateway.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { InterfaceIdCalculator } from "contracts/utils/InterfaceIdCalculator.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";
import { TestERC20 } from "../mocks/TestERC20.sol";

contract TREXGatewayTest is TREXSuiteTest {

    TREXGateway public publicGateway;
    TREXGateway public privateGateway;

    function setUp() public virtual override {
        super.setUp();

        publicGateway = new TREXGateway(address(trexFactory), true, address(accessManager));
        privateGateway = new TREXGateway(address(trexFactory), false, address(accessManager));

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupTREXGatewayRoles(accessManager, address(publicGateway));
        AccessManagerSetupLib.setupTREXGatewayRoles(accessManager, address(privateGateway));

        accessManager.grantRole(RolesLib.OWNER, address(publicGateway), 0);
        accessManager.grantRole(RolesLib.OWNER, address(privateGateway), 0);

        accessManager.grantRole(RolesLib.AGENT, deployer, 0);
        vm.stopPrank();
    }

    // ============================================
    // .setFactory Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_setFactory_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.setFactory(address(trexFactory));
    }

    /// @notice Should revert when factory address is zero
    function test_setFactory_RevertWhen_FactoryAddressIsZero() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        privateGateway.setFactory(address(0));
    }

    /// @notice Should set factory when called by owner
    function test_setFactory_Success() public {
        assertEq(privateGateway.getFactory(), address(trexFactory));

        TREXFactory newFactory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(accessManager));
        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.FactorySet(address(newFactory));
        vm.prank(deployer);
        privateGateway.setFactory(address(newFactory));

        assertEq(privateGateway.getFactory(), address(newFactory));
    }

    // ============================================
    // .setPublicDeploymentStatus Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_setPublicDeploymentStatus_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.setPublicDeploymentStatus(true);
    }

    /// @notice Should revert when status doesn't change
    function test_setPublicDeploymentStatus_RevertWhen_StatusDoesntChange() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.PublicDeploymentAlreadyDisabled.selector);
        privateGateway.setPublicDeploymentStatus(false);

        vm.prank(deployer);
        privateGateway.setPublicDeploymentStatus(true);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.PublicDeploymentAlreadyEnabled.selector);
        privateGateway.setPublicDeploymentStatus(true);
    }

    /// @notice Should set new status when called by owner
    function test_setPublicDeploymentStatus_Success() public {
        assertEq(privateGateway.getPublicDeploymentStatus(), false);

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.PublicDeploymentStatusSet(true);
        vm.prank(deployer);
        privateGateway.setPublicDeploymentStatus(true);

        assertEq(privateGateway.getPublicDeploymentStatus(), true);
    }

    // ============================================
    // .enableDeploymentFee Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_enableDeploymentFee_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.enableDeploymentFee(true);
    }

    /// @notice Should revert when status doesn't change
    function test_enableDeploymentFee_RevertWhen_StatusDoesntChange() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.DeploymentFeesAlreadyDisabled.selector);
        privateGateway.enableDeploymentFee(false);

        vm.prank(deployer);
        privateGateway.enableDeploymentFee(true);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.DeploymentFeesAlreadyEnabled.selector);
        privateGateway.enableDeploymentFee(true);
    }

    /// @notice Should enable deployment fee when called by owner
    function test_enableDeploymentFee_Success() public {
        // Initially disabled
        assertFalse(privateGateway.isDeploymentFeeEnabled());

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.DeploymentFeeEnabled(true);
        vm.prank(deployer);
        privateGateway.enableDeploymentFee(true);

        // Verify it's now enabled
        assertTrue(privateGateway.isDeploymentFeeEnabled());
    }

    // ============================================
    // .setDeploymentFee Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_setDeploymentFee_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.setDeploymentFee(10000, address(0), deployer);
    }

    /// @notice Should revert when fee token is zero address
    function test_setDeploymentFee_RevertWhen_FeeTokenIsZero() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        privateGateway.setDeploymentFee(10000, address(0), deployer);
    }

    /// @notice Should revert when fee collector is zero address
    function test_setDeploymentFee_RevertWhen_FeeCollectorIsZero() public {
        TestERC20 feeToken = new TestERC20("FeeToken", "FT");

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        privateGateway.setDeploymentFee(10000, address(feeToken), address(0));
    }

    /// @notice Should set deployment fee when called by owner
    function test_setDeploymentFee_Success() public {
        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        vm.expectEmit(true, true, true, false, address(privateGateway));
        emit EventsLib.DeploymentFeeSet(10000, address(feeToken), deployer);
        vm.prank(deployer);
        privateGateway.setDeploymentFee(10000, address(feeToken), deployer);

        // Verify fee was set correctly
        ITREXGateway.Fee memory fee = privateGateway.getDeploymentFee();
        assertEq(fee.fee, 10000);
        assertEq(fee.feeToken, address(feeToken));
        assertEq(fee.feeCollector, deployer);
    }

    // ============================================
    // .addDeployer Tests
    // ============================================

    /// @notice Should revert when called by not admin
    function test_addDeployer_RevertWhen_NotAdmin() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.addDeployer(another);
    }

    /// @notice Should revert when deployer already exists
    function test_addDeployer_RevertWhen_DeployerAlreadyExists() public {
        vm.prank(deployer);
        privateGateway.addDeployer(agent);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DeployerAlreadyExists.selector, agent));
        privateGateway.addDeployer(agent);
    }

    /// @notice Should add new deployer when called by owner
    function test_addDeployer_Success_WhenCalledByOwner() public {
        assertFalse(privateGateway.isDeployer(agent));

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.DeployerAdded(agent);
        vm.prank(deployer);
        privateGateway.addDeployer(agent);

        assertTrue(privateGateway.isDeployer(agent));
    }

    /// @notice Should add new deployer when called by agent
    function test_addDeployer_Success_WhenCalledByAgent() public {
        assertFalse(privateGateway.isDeployer(agent));

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.DeployerAdded(agent);
        vm.prank(agent);
        privateGateway.addDeployer(agent);

        assertTrue(privateGateway.isDeployer(agent));
    }

    // ============================================
    // .batchAddDeployer Tests
    // ============================================

    /// @notice Should revert when called by not admin
    function test_batchAddDeployer_RevertWhen_NotAdmin() public {
        address[] memory deployers = new address[](1);
        deployers[0] = another;

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.batchAddDeployer(deployers);
    }

    /// @notice Should revert when batch includes already registered deployer
    function test_batchAddDeployer_RevertWhen_DeployerAlreadyExists() public {
        vm.prank(deployer);
        privateGateway.addDeployer(agent);

        address[] memory deployers = new address[](10);
        for (uint256 i = 0; i < 9; i++) {
            deployers[i] = makeAddr(string(abi.encodePacked("deployer", i)));
        }
        deployers[9] = agent; // Already exists

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DeployerAlreadyExists.selector, agent));
        privateGateway.batchAddDeployer(deployers);
    }

    /// @notice Should revert when batch size exceeds 500
    function test_batchAddDeployer_RevertWhen_BatchSizeExceeds500() public {
        address[] memory deployers = new address[](501);
        address duplicateAddress = makeAddr("duplicate");
        for (uint256 i = 0; i < 501; i++) {
            deployers[i] = duplicateAddress;
        }

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BatchMaxLengthExceeded.selector, 500));
        privateGateway.batchAddDeployer(deployers);
    }

    /// @notice Should add 1 new deployer when called by owner
    function test_batchAddDeployer_Success_AddOneDeployer() public {
        assertFalse(privateGateway.isDeployer(agent));

        address[] memory deployers = new address[](1);
        deployers[0] = agent;

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.DeployerAdded(agent);
        vm.prank(deployer);
        privateGateway.batchAddDeployer(deployers);

        assertTrue(privateGateway.isDeployer(agent));
    }

    /// @notice Should add 10 new deployers when called by owner
    function test_batchAddDeployer_Success_AddTenDeployers() public {
        address[] memory deployers = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            deployers[i] = makeAddr(string(abi.encodePacked("deployer", i)));
            assertFalse(privateGateway.isDeployer(deployers[i]));
        }

        for (uint256 i = 0; i < 10; i++) {
            vm.expectEmit(true, false, false, false, address(privateGateway));
            emit EventsLib.DeployerAdded(deployers[i]);
        }
        vm.prank(deployer);
        privateGateway.batchAddDeployer(deployers);

        for (uint256 i = 0; i < 10; i++) {
            assertTrue(privateGateway.isDeployer(deployers[i]));
        }
    }

    /// @notice Should revert when agent tries to add batch with already registered deployer
    function test_batchAddDeployer_RevertWhen_AgentAddsAlreadyRegisteredDeployer() public {
        vm.prank(accessManagerAdmin);
        accessManager.grantRole(RolesLib.AGENT, another, 0);

        vm.prank(another);
        privateGateway.addDeployer(agent);

        address[] memory deployers = new address[](10);
        for (uint256 i = 0; i < 9; i++) {
            deployers[i] = makeAddr(string(abi.encodePacked("deployer", i)));
        }
        // Insert agent at random position (using position 5)
        deployers[5] = agent;

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DeployerAlreadyExists.selector, agent));
        privateGateway.batchAddDeployer(deployers);
    }

    /// @notice Should add 1 new deployer when called by agent
    function test_batchAddDeployer_Success_WhenCalledByAgent() public {
        address[] memory deployers = new address[](1);
        deployers[0] = agent;

        assertFalse(privateGateway.isDeployer(agent));

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.DeployerAdded(agent);
        vm.prank(deployer);
        privateGateway.batchAddDeployer(deployers);

        assertTrue(privateGateway.isDeployer(agent));
    }

    /// @notice Should add 10 new deployers when called by agent
    function test_batchAddDeployer_Success_AgentAddsTenDeployers() public {
        address[] memory deployers = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            deployers[i] = makeAddr(string(abi.encodePacked("deployer", i)));
            assertFalse(privateGateway.isDeployer(deployers[i]));
        }

        for (uint256 i = 0; i < 10; i++) {
            vm.expectEmit(true, false, false, false, address(privateGateway));
            emit EventsLib.DeployerAdded(deployers[i]);
        }
        vm.prank(deployer);
        privateGateway.batchAddDeployer(deployers);

        for (uint256 i = 0; i < 10; i++) {
            assertTrue(privateGateway.isDeployer(deployers[i]));
        }
    }

    // ============================================
    // .removeDeployer Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_removeDeployer_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.removeDeployer(another);
    }

    /// @notice Should revert when deployer does not exist
    function test_removeDeployer_RevertWhen_DeployerDoesNotExist() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DeployerDoesNotExist.selector, agent));
        privateGateway.removeDeployer(agent);
    }

    /// @notice Should remove deployer when called by owner
    function test_removeDeployer_Success() public {
        vm.prank(deployer);
        privateGateway.addDeployer(agent);

        assertTrue(privateGateway.isDeployer(agent));

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.DeployerRemoved(agent);
        vm.prank(deployer);
        privateGateway.removeDeployer(agent);

        assertFalse(privateGateway.isDeployer(agent));
    }

    // ============================================
    // .batchRemoveDeployer Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_batchRemoveDeployer_RevertWhen_NotOwner() public {
        address[] memory deployers = new address[](1);
        deployers[0] = another;

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.batchRemoveDeployer(deployers);
    }

    /// @notice Should revert when deployer does not exist
    function test_batchRemoveDeployer_RevertWhen_DeployerDoesNotExist() public {
        address[] memory deployers = new address[](1);
        deployers[0] = agent;

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DeployerDoesNotExist.selector, agent));
        privateGateway.batchRemoveDeployer(deployers);
    }

    /// @notice Should remove deployer when called by owner
    function test_batchRemoveDeployer_Success() public {
        vm.prank(deployer);
        privateGateway.addDeployer(agent);

        assertTrue(privateGateway.isDeployer(agent));

        address[] memory deployers = new address[](1);
        deployers[0] = agent;

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.DeployerRemoved(agent);
        vm.prank(deployer);
        privateGateway.batchRemoveDeployer(deployers);

        assertFalse(privateGateway.isDeployer(agent));
    }

    /// @notice Should revert when agent tries to remove non-existent deployer
    function test_batchRemoveDeployer_RevertWhen_AgentRemovesNonExistent() public {
        // Add 9 deployers first
        address[] memory deployers = new address[](9);
        for (uint256 i = 0; i < 9; i++) {
            deployers[i] = makeAddr(string(abi.encodePacked("deployer", i)));
        }

        vm.prank(deployer);
        privateGateway.batchAddDeployer(deployers);

        // Now create array with the 9 deployers + agent (who was never added as deployer)
        address[] memory deployersToRemove = new address[](10);
        for (uint256 i = 0; i < 9; i++) {
            deployersToRemove[i] = deployers[i];
        }
        deployersToRemove[9] = agent; // This one doesn't exist as a deployer

        vm.prank(accessManagerAdmin);
        accessManager.grantRole(RolesLib.AGENT, another, 0);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DeployerDoesNotExist.selector, agent));
        privateGateway.batchRemoveDeployer(deployersToRemove);
    }

    /// @notice Should revert when batch size exceeds 500
    function test_batchRemoveDeployer_RevertWhen_BatchSizeExceeds500() public {
        address duplicateAddress = makeAddr("duplicate");
        address[] memory deployers = new address[](501);
        for (uint256 i = 0; i < 501; i++) {
            deployers[i] = duplicateAddress;
        }

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BatchMaxLengthExceeded.selector, 500));
        privateGateway.batchRemoveDeployer(deployers);
    }

    /// @notice Should remove deployers when called by agent
    function test_batchRemoveDeployer_Success_WhenCalledByAgent() public {
        address[] memory deployers = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            deployers[i] = makeAddr(string(abi.encodePacked("deployer", i)));
        }

        vm.prank(deployer);
        privateGateway.batchAddDeployer(deployers);

        for (uint256 i = 0; i < 10; i++) {
            vm.expectEmit(true, false, false, false, address(privateGateway));
            emit EventsLib.DeployerRemoved(deployers[i]);
        }
        vm.prank(agent);
        privateGateway.batchRemoveDeployer(deployers);

        for (uint256 i = 0; i < 10; i++) {
            assertFalse(privateGateway.isDeployer(deployers[i]));
        }
    }

    // ============================================
    // .applyFeeDiscount Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_applyFeeDiscount_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.applyFeeDiscount(another, 5000);
    }

    /// @notice Should revert when discount out of range
    function test_applyFeeDiscount_RevertWhen_DiscountOutOfRange() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.DiscountOutOfRange.selector);
        privateGateway.applyFeeDiscount(another, 12000);
    }

    /// @notice Should apply discount when called by owner
    function test_applyFeeDiscount_Success() public {
        // Deploy a token to use as fee token BEFORE transferring ownership
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("sym", tokenDetails, claimDetails);
        address feeTokenAddress = trexFactory.getToken("sym");

        vm.prank(deployer);
        privateGateway.setDeploymentFee(20000, feeTokenAddress, deployer);

        assertEq(privateGateway.calculateFee(bob), 20000);

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.FeeDiscountApplied(bob, 5000);
        vm.prank(deployer);
        privateGateway.applyFeeDiscount(bob, 5000);

        assertEq(privateGateway.calculateFee(bob), 10000); // 50% discount
    }

    // ============================================
    // .batchApplyFeeDiscount Tests
    // ============================================

    /// @notice Should revert when called by not owner
    function test_batchApplyFeeDiscount_RevertWhen_NotOwner() public {
        address[] memory deployers = new address[](1);
        deployers[0] = another;
        uint16[] memory discounts = new uint16[](1);
        discounts[0] = 5000;

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        privateGateway.batchApplyFeeDiscount(deployers, discounts);
    }

    /// @notice Should revert when discount out of range
    function test_batchApplyFeeDiscount_RevertWhen_DiscountOutOfRange() public {
        address[] memory deployers = new address[](1);
        deployers[0] = another;
        uint16[] memory discounts = new uint16[](1);
        discounts[0] = 12000;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.DiscountOutOfRange.selector);
        privateGateway.batchApplyFeeDiscount(deployers, discounts);
    }

    /// @notice Should apply discounts when called by owner
    function test_batchApplyFeeDiscount_Success() public {
        // Deploy a token to use as fee token BEFORE transferring ownership
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("sym", tokenDetails, claimDetails);
        address feeTokenAddress = trexFactory.getToken("sym");

        vm.prank(deployer);
        privateGateway.setDeploymentFee(20000, feeTokenAddress, deployer);

        address[] memory deployers = new address[](2);
        deployers[0] = alice;
        deployers[1] = bob;
        uint16[] memory discounts = new uint16[](2);
        discounts[0] = 5000;
        discounts[1] = 10000;

        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.FeeDiscountApplied(alice, 5000);
        vm.expectEmit(true, false, false, false, address(privateGateway));
        emit EventsLib.FeeDiscountApplied(bob, 10000);
        vm.prank(deployer);
        privateGateway.batchApplyFeeDiscount(deployers, discounts);

        assertEq(privateGateway.calculateFee(alice), 10000); // 50% discount
        assertEq(privateGateway.calculateFee(bob), 0); // 100% discount
    }

    /// @notice Should revert when agent tries to apply batch with out-of-range discount
    function test_batchApplyFeeDiscount_RevertWhen_AgentDiscountOutOfRange() public {
        address[] memory deployers = new address[](1);
        uint16[] memory discounts = new uint16[](1);
        deployers[0] = another;
        discounts[0] = 12000; // Out of range

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.DiscountOutOfRange.selector);
        privateGateway.batchApplyFeeDiscount(deployers, discounts);
    }

    /// @notice Should revert when batch size exceeds 500
    function test_batchApplyFeeDiscount_RevertWhen_BatchSizeExceeds500() public {
        address[] memory deployers = new address[](501);
        uint16[] memory discounts = new uint16[](501);
        for (uint256 i = 0; i < 501; i++) {
            deployers[i] = makeAddr(string(abi.encodePacked("deployer", i)));
            discounts[i] = 5000;
        }

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BatchMaxLengthExceeded.selector, 500));
        privateGateway.batchApplyFeeDiscount(deployers, discounts);
    }

    /// @notice Should apply discounts to all deployers when called by agent
    function test_batchApplyFeeDiscount_Success_WhenCalledByAgent() public {
        // Deploy a token to use as fee token BEFORE transferring ownership
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("sym", tokenDetails, claimDetails);
        address feeTokenAddress = trexFactory.getToken("sym");

        uint256 deploymentFee = 20000;
        vm.prank(deployer);
        privateGateway.setDeploymentFee(deploymentFee, feeTokenAddress, deployer);

        address[] memory deployers = new address[](10);
        uint16[] memory discounts = new uint16[](10);
        for (uint256 i = 0; i < 10; i++) {
            deployers[i] = makeAddr(string(abi.encodePacked("deployer", i)));
            discounts[i] = 5000; // 50% discount
        }

        for (uint256 i = 0; i < 10; i++) {
            vm.expectEmit(true, false, false, false, address(privateGateway));
            emit EventsLib.FeeDiscountApplied(deployers[i], discounts[i]);
        }

        vm.prank(agent);
        privateGateway.batchApplyFeeDiscount(deployers, discounts);

        uint256 expectedFeeAfterDiscount = deploymentFee - (deploymentFee * discounts[0]) / 10000;
        for (uint256 i = 0; i < 10; i++) {
            assertEq(privateGateway.calculateFee(deployers[i]), expectedFeeAfterDiscount);
        }
    }

    // ============================================
    // .deployTREXSuite Tests
    // ============================================

    /// @notice Should revert when called by not deployer and public deployments disabled
    function test_deployTREXSuite_RevertWhen_NotDeployerAndPublicDisabled() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(another);
        vm.expectRevert(ErrorsLib.PublicDeploymentsNotAllowed.selector);
        privateGateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should revert when public deployments enabled but trying to deploy on behalf
    function test_deployTREXSuite_RevertWhen_PublicEnabledButOnBehalf() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = bob; // Different from caller
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(another);
        vm.expectRevert(ErrorsLib.PublicCannotDeployOnBehalf.selector);
        publicGateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should deploy for free when public deployments enabled and fees not activated
    function test_deployTREXSuite_Success_PublicEnabledNoFees() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(publicGateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 0);
        vm.prank(another);
        publicGateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should deploy with full fee when fees activated and no discount
    function test_deployTREXSuite_Success_FullFee() public {
        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        publicGateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        publicGateway.enableDeploymentFee(true);

        vm.prank(another);
        feeToken.approve(address(publicGateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(publicGateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 20000);
        vm.prank(another);
        publicGateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 80000);
    }

    /// @notice Should deploy with 50% discount when caller has discount
    function test_deployTREXSuite_Success_HalfFeeWithDiscount() public {
        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        publicGateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        publicGateway.enableDeploymentFee(true);

        vm.prank(deployer);
        publicGateway.applyFeeDiscount(another, 5000); // 50% discount

        vm.prank(another);
        feeToken.approve(address(publicGateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(publicGateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 10000);
        vm.prank(another);
        publicGateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 90000);
    }

    /// @notice Should deploy for free when deployer has 100% discount
    function test_deployTREXSuite_Success_DeployerFreeWithFullDiscount() public {
        vm.prank(deployer);
        privateGateway.addDeployer(another);

        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        privateGateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        privateGateway.enableDeploymentFee(true);

        vm.prank(deployer);
        privateGateway.applyFeeDiscount(another, 10000); // 100% discount

        vm.prank(another);
        feeToken.approve(address(privateGateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(privateGateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 0);
        vm.prank(another);
        privateGateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 100000); // No fee deducted
    }

    /// @notice Should deploy when called by deployer with public deployments disabled
    function test_deployTREXSuite_Success_WhenCalledByDeployer() public {
        vm.prank(deployer);
        privateGateway.addDeployer(another);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(privateGateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 0);
        vm.prank(another);
        privateGateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should deploy on behalf when called by deployer
    function test_deployTREXSuite_Success_DeployOnBehalf() public {
        vm.prank(deployer);
        privateGateway.addDeployer(another);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = bob; // Different from caller, but deployer can do this
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(privateGateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, bob, 0);
        vm.prank(another);
        privateGateway.deployTREXSuite(tokenDetails, claimDetails);
    }

    /// @notice Should deploy with full fee when deployer has no discount
    function test_deployTREXSuite_Success_DeployerFullFee() public {
        vm.prank(deployer);
        privateGateway.addDeployer(another);

        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        privateGateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        privateGateway.enableDeploymentFee(true);

        vm.prank(another);
        feeToken.approve(address(privateGateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(privateGateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 20000);
        vm.prank(another);
        privateGateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 80000);
    }

    /// @notice Should deploy with 50% discount when deployer has discount
    function test_deployTREXSuite_Success_DeployerHalfFeeWithDiscount() public {
        vm.prank(deployer);
        privateGateway.addDeployer(another);

        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 100000);

        vm.prank(deployer);
        privateGateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        privateGateway.enableDeploymentFee(true);

        vm.prank(deployer);
        privateGateway.applyFeeDiscount(another, 5000); // 50% discount

        vm.prank(another);
        feeToken.approve(address(privateGateway), 20000);

        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        tokenDetails.owner = another;
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectEmit(false, false, false, true, address(privateGateway));
        emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 10000);
        vm.prank(another);
        privateGateway.deployTREXSuite(tokenDetails, claimDetails);

        assertEq(feeToken.balanceOf(another), 90000);
    }

    // ============================================
    // .batchDeployTREXSuite Tests
    // ============================================

    /// @notice Should revert when called by not deployer and public deployments disabled
    function test_batchDeployTREXSuite_RevertWhen_NotDeployerAndPublicDisabled() public {
        ITREXFactory.TokenDetails[] memory tokenDetailsArray = new ITREXFactory.TokenDetails[](5);
        ITREXFactory.ClaimDetails[] memory claimDetailsArray = new ITREXFactory.ClaimDetails[](5);

        for (uint256 i = 0; i < 5; i++) {
            tokenDetailsArray[i] = _createEmptyTokenDetails();
            tokenDetailsArray[i].name = string.concat("Token name ", vm.toString(i));
            tokenDetailsArray[i].symbol = string.concat("SYM", vm.toString(i));
            tokenDetailsArray[i].owner = another;
            claimDetailsArray[i] = _createEmptyClaimDetails();
        }

        vm.prank(another);
        vm.expectRevert(ErrorsLib.PublicDeploymentsNotAllowed.selector);
        privateGateway.batchDeployTREXSuite(tokenDetailsArray, claimDetailsArray);
    }

    /// @notice Should revert when trying to deploy on behalf in batch
    function test_batchDeployTREXSuite_RevertWhen_PublicEnabledButOnBehalf() public {
        ITREXFactory.TokenDetails[] memory tokenDetailsArray = new ITREXFactory.TokenDetails[](5);
        ITREXFactory.ClaimDetails[] memory claimDetailsArray = new ITREXFactory.ClaimDetails[](5);

        for (uint256 i = 0; i < 4; i++) {
            tokenDetailsArray[i] = _createEmptyTokenDetails();
            tokenDetailsArray[i].name = string(abi.encodePacked("Token name ", vm.toString(i)));
            tokenDetailsArray[i].symbol = string(abi.encodePacked("SYM", vm.toString(i)));
            tokenDetailsArray[i].owner = another;
            claimDetailsArray[i] = _createEmptyClaimDetails();
        }
        // Last one has different owner
        tokenDetailsArray[4] = _createEmptyTokenDetails();
        tokenDetailsArray[4].name = "Token name behalf";
        tokenDetailsArray[4].symbol = "SYM42";
        tokenDetailsArray[4].owner = bob;
        claimDetailsArray[4] = _createEmptyClaimDetails();

        vm.prank(another);
        vm.expectRevert(ErrorsLib.PublicCannotDeployOnBehalf.selector);
        publicGateway.batchDeployTREXSuite(tokenDetailsArray, claimDetailsArray);
    }

    /// @notice Should revert when batch size exceeds 5
    function test_batchDeployTREXSuite_RevertWhen_BatchSizeExceeds5() public {
        ITREXFactory.TokenDetails[] memory tokenDetailsArray = new ITREXFactory.TokenDetails[](6);
        ITREXFactory.ClaimDetails[] memory claimDetailsArray = new ITREXFactory.ClaimDetails[](6);

        for (uint256 i = 0; i < 6; i++) {
            tokenDetailsArray[i] = _createEmptyTokenDetails();
            tokenDetailsArray[i].name = string(abi.encodePacked("Token name ", vm.toString(i)));
            tokenDetailsArray[i].symbol = string(abi.encodePacked("SYM", vm.toString(i)));
            tokenDetailsArray[i].owner = another;
            claimDetailsArray[i] = _createEmptyClaimDetails();
        }

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BatchMaxLengthExceeded.selector, 5));
        publicGateway.batchDeployTREXSuite(tokenDetailsArray, claimDetailsArray);
    }

    /// @notice Should deploy tokens for free in batch when fees not activated
    function test_batchDeployTREXSuite_Success_NoFees() public {
        ITREXFactory.TokenDetails[] memory tokenDetailsArray = new ITREXFactory.TokenDetails[](5);
        ITREXFactory.ClaimDetails[] memory claimDetailsArray = new ITREXFactory.ClaimDetails[](5);

        for (uint256 i = 0; i < 5; i++) {
            tokenDetailsArray[i] = _createEmptyTokenDetails();
            tokenDetailsArray[i].name = string(abi.encodePacked("Token name ", vm.toString(i)));
            tokenDetailsArray[i].symbol = string(abi.encodePacked("SYM", vm.toString(i)));
            tokenDetailsArray[i].owner = another;
            claimDetailsArray[i] = _createEmptyClaimDetails();
        }

        for (uint256 i = 0; i < 5; i++) {
            vm.expectEmit(false, false, false, true, address(publicGateway));
            emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 0);
        }
        vm.prank(another);
        publicGateway.batchDeployTREXSuite(tokenDetailsArray, claimDetailsArray);
    }

    /// @notice Should deploy tokens for full fee in batch
    function test_batchDeployTREXSuite_Success_FullFee() public {
        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 500000);

        vm.prank(deployer);
        publicGateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        publicGateway.enableDeploymentFee(true);

        vm.prank(another);
        feeToken.approve(address(publicGateway), 100000);

        ITREXFactory.TokenDetails[] memory tokenDetailsArray = new ITREXFactory.TokenDetails[](5);
        ITREXFactory.ClaimDetails[] memory claimDetailsArray = new ITREXFactory.ClaimDetails[](5);

        for (uint256 i = 0; i < 5; i++) {
            tokenDetailsArray[i] = _createEmptyTokenDetails();
            tokenDetailsArray[i].name = string(abi.encodePacked("Token name ", vm.toString(i)));
            tokenDetailsArray[i].symbol = string(abi.encodePacked("SYM", vm.toString(i)));
            tokenDetailsArray[i].owner = another;
            claimDetailsArray[i] = _createEmptyClaimDetails();
        }

        for (uint256 i = 0; i < 5; i++) {
            vm.expectEmit(false, false, false, true, address(publicGateway));
            emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 20000);
        }

        vm.prank(another);
        publicGateway.batchDeployTREXSuite(tokenDetailsArray, claimDetailsArray);

        assertEq(feeToken.balanceOf(another), 400000);
    }

    /// @notice Should deploy tokens for half fee in batch with discount
    function test_batchDeployTREXSuite_Success_HalfFeeWithDiscount() public {
        TestERC20 feeToken = new TestERC20("FeeToken", "FT");
        feeToken.mint(another, 500000);

        vm.prank(deployer);
        publicGateway.setDeploymentFee(20000, address(feeToken), deployer);

        vm.prank(deployer);
        publicGateway.enableDeploymentFee(true);

        vm.prank(deployer);
        publicGateway.applyFeeDiscount(another, 5000); // 50% discount

        vm.prank(another);
        feeToken.approve(address(publicGateway), 50000);

        ITREXFactory.TokenDetails[] memory tokenDetailsArray = new ITREXFactory.TokenDetails[](5);
        ITREXFactory.ClaimDetails[] memory claimDetailsArray = new ITREXFactory.ClaimDetails[](5);

        for (uint256 i = 0; i < 5; i++) {
            tokenDetailsArray[i] = _createEmptyTokenDetails();
            tokenDetailsArray[i].name = string(abi.encodePacked("Token name ", vm.toString(i)));
            tokenDetailsArray[i].symbol = string(abi.encodePacked("SYM", vm.toString(i)));
            tokenDetailsArray[i].owner = another;
            claimDetailsArray[i] = _createEmptyClaimDetails();
        }

        for (uint256 i = 0; i < 5; i++) {
            vm.expectEmit(false, false, false, true, address(publicGateway));
            emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 10000);
        }
        vm.prank(another);
        publicGateway.batchDeployTREXSuite(tokenDetailsArray, claimDetailsArray);

        assertEq(feeToken.balanceOf(another), 450000);
    }

    /// @notice Should deploy in batch when called by deployer
    function test_batchDeployTREXSuite_Success_WhenCalledByDeployer() public {
        vm.prank(deployer);
        privateGateway.addDeployer(another);

        ITREXFactory.TokenDetails[] memory tokenDetailsArray = new ITREXFactory.TokenDetails[](5);
        ITREXFactory.ClaimDetails[] memory claimDetailsArray = new ITREXFactory.ClaimDetails[](5);

        for (uint256 i = 0; i < 5; i++) {
            tokenDetailsArray[i] = _createEmptyTokenDetails();
            tokenDetailsArray[i].name = string(abi.encodePacked("Token name ", vm.toString(i)));
            tokenDetailsArray[i].symbol = string(abi.encodePacked("SYM", vm.toString(i)));
            tokenDetailsArray[i].owner = another;
            claimDetailsArray[i] = _createEmptyClaimDetails();
        }

        for (uint256 i = 0; i < 5; i++) {
            vm.expectEmit(false, false, false, true, address(privateGateway));
            emit EventsLib.GatewaySuiteDeploymentProcessed(another, another, 0);
        }

        vm.prank(another);
        privateGateway.batchDeployTREXSuite(tokenDetailsArray, claimDetailsArray);
    }

    /// @notice Should deploy on behalf in batch when called by deployer
    function test_batchDeployTREXSuite_Success_DeployOnBehalf() public {
        vm.prank(deployer);
        privateGateway.addDeployer(another);

        ITREXFactory.TokenDetails[] memory tokenDetailsArray = new ITREXFactory.TokenDetails[](5);
        ITREXFactory.ClaimDetails[] memory claimDetailsArray = new ITREXFactory.ClaimDetails[](5);

        for (uint256 i = 0; i < 5; i++) {
            tokenDetailsArray[i] = _createEmptyTokenDetails();
            tokenDetailsArray[i].name = string(abi.encodePacked("Token name ", vm.toString(i)));
            tokenDetailsArray[i].symbol = string(abi.encodePacked("SYM", vm.toString(i)));
            tokenDetailsArray[i].owner = bob; // Different from caller
            claimDetailsArray[i] = _createEmptyClaimDetails();
        }

        for (uint256 i = 0; i < 5; i++) {
            vm.expectEmit(false, false, false, true, address(privateGateway));
            emit EventsLib.GatewaySuiteDeploymentProcessed(another, bob, 0);
        }

        vm.prank(another);
        privateGateway.batchDeployTREXSuite(tokenDetailsArray, claimDetailsArray);
    }

    // ============================================
    // .supportsInterface Tests
    // ============================================

    /// @notice Should return false for unsupported interfaces
    function test_supportsInterface_ReturnsFalse_ForUnsupportedInterface() public view {
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(privateGateway.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the ITREXGateway interface ID
    function test_supportsInterface_ReturnsTrue_ForITREXGateway() public {
        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getITREXGatewayInterfaceId();
        assertTrue(privateGateway.supportsInterface(interfaceId));
    }

    /// @notice Should correctly identify the IERC173 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC173() public {
        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getIERC173InterfaceId();
        assertTrue(privateGateway.supportsInterface(interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public {
        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getIERC165InterfaceId();
        assertTrue(privateGateway.supportsInterface(interfaceId));
    }

}
