// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";

import { MintOnlyModule, RecordingModule } from "../mocks/CapabilityModules.sol";
import { MockContract } from "../mocks/MockContract.sol";
import { TestModule } from "../mocks/TestModule.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract ComplianceCheckTest is TREXSuiteTest {

    ModularCompliance public compliance;
    TestModule public testModule;
    MockContract public mockContract;
    UtilityChecker public utilityChecker;

    function setUp() public override {
        super.setUp();

        compliance = ModularCompliance(address(token.compliance()));

        // Deploy TestModule implementation
        TestModule testModuleImplementation = new TestModule();

        // Deploy TestModule proxy with initialize using ModuleProxy
        bytes memory moduleInitData = abi.encodeWithSelector(TestModule.initialize.selector);
        ModuleProxy testModuleProxy = new ModuleProxy(address(testModuleImplementation), moduleInitData);
        testModule = TestModule(address(testModuleProxy));

        // Add module to compliance
        vm.prank(deployer);
        compliance.addModule(address(testModule));

        // Deploy MockContract
        mockContract = new MockContract();

        // Bind token to compliance
        vm.prank(deployer);
        compliance.bindToken(address(mockContract));

        // Set compliance on mock contract
        mockContract.setCompliance(address(compliance));

        // Deploy UtilityChecker via proxy
        UtilityChecker utilityCheckerImpl = new UtilityChecker();
        bytes memory utilityCheckerInitData = abi.encodeWithSelector(UtilityChecker.initialize.selector);
        UtilityCheckerProxy utilityCheckerProxy =
            new UtilityCheckerProxy(address(utilityCheckerImpl), utilityCheckerInitData);
        utilityChecker = UtilityChecker(address(utilityCheckerProxy));
    }

    // ============ getTransferDetails() Tests ============

    /// @notice Should return pass for single module
    function test_getTransferDetails_ReturnsPass_ForSingleModule() public view {
        UtilityChecker.ComplianceCheckDetails[] memory results =
            utilityChecker.getTransferDetails(address(mockContract), alice, bob, 100);

        assertEq(results.length, 1);
        assertEq(keccak256(bytes(results[0].moduleName)), keccak256(bytes("TestModule")));
        assertTrue(results[0].pass);
    }

    /// @notice Should return no pass for one of multiple modules
    function test_getTransferDetails_ReturnsNoPass_ForOneOfMultipleModules() public {
        // Deploy second module with proxy
        TestModule testModule2Implementation = new TestModule();
        bytes memory module2InitData = abi.encodeWithSelector(TestModule.initialize.selector);
        ModuleProxy testModule2Proxy = new ModuleProxy(address(testModule2Implementation), module2InitData);
        TestModule testModule2 = TestModule(address(testModule2Proxy));

        // Add the proxy address to compliance
        vm.prank(deployer);
        compliance.addModule(address(testModule2));

        // Block the second test module to show 2 different outputs
        bytes memory blockModuleCall = abi.encodeWithSignature("blockModule(bool)", true);
        vm.prank(deployer);
        compliance.callModuleFunction(blockModuleCall, address(testModule2));

        UtilityChecker.ComplianceCheckDetails[] memory results =
            utilityChecker.getTransferDetails(address(mockContract), alice, bob, 100);

        assertEq(results.length, 2);
        assertEq(keccak256(bytes(results[0].moduleName)), keccak256(bytes("TestModule")));
        assertTrue(results[0].pass);
        assertEq(keccak256(bytes(results[1].moduleName)), keccak256(bytes("TestModule")));
        assertFalse(results[1].pass);
    }

    /// @notice Should return pass for multiple modules
    function test_getTransferDetails_ReturnsPass_ForMultipleModules() public {
        // Deploy second module with proxy
        TestModule testModule2Implementation = new TestModule();
        bytes memory module2InitData = abi.encodeWithSelector(TestModule.initialize.selector);
        ModuleProxy testModule2Proxy = new ModuleProxy(address(testModule2Implementation), module2InitData);
        TestModule testModule2 = TestModule(address(testModule2Proxy));

        // Add the proxy address to compliance
        vm.prank(deployer);
        compliance.addModule(address(testModule2));

        UtilityChecker.ComplianceCheckDetails[] memory results =
            utilityChecker.getTransferDetails(address(mockContract), alice, bob, 100);

        assertEq(results.length, 2);
        assertEq(keccak256(bytes(results[0].moduleName)), keccak256(bytes("TestModule")));
        assertTrue(results[0].pass);
        assertEq(keccak256(bytes(results[1].moduleName)), keccak256(bytes("TestModule")));
        assertTrue(results[1].pass);
    }

    /// @notice Should skip modules that never declared the transfer check
    function test_getTransferDetails_OmitsModules_WithoutTheTransferCheck() public {
        MintOnlyModule mintOnlyImplementation = new MintOnlyModule();
        bytes memory initData = abi.encodeCall(RecordingModule.initialize, ());
        address mintOnly = address(new ModuleProxy(address(mintOnlyImplementation), initData));

        vm.prank(deployer);
        compliance.addModule(mintOnly);

        UtilityChecker.ComplianceCheckDetails[] memory results =
            utilityChecker.getTransferDetails(address(mockContract), alice, bob, 100);

        // the mint-only module is bound, but it enforces nothing on a transfer
        assertEq(compliance.getModules().length, 2);
        assertEq(results.length, 1);
        assertEq(keccak256(bytes(results[0].moduleName)), keccak256(bytes("TestModule")));
    }

}
