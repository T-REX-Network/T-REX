// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import {
    AllTypesModule,
    DuplicateTypeModule,
    NoTypeModule,
    RecordingModule,
    RuleAndTrackerModule,
    RuleOnlyModule,
    SpenderOnlyModule,
    TrackerOnlyModule
} from "test/integration/mocks/CapabilityModules.sol";

/// @dev Binding lifecycle for modules that name their types: what a compliance files, what it refuses, what
///      survives a removal from the middle of the bound set, and what a resync rewrites.
contract ComplianceModuleTypesTest is TREXSuiteTest {

    ModularCompliance internal mc;

    function setUp() public override {
        super.setUp();
        mc = _newUnboundComplianceProxy(address(trexImplementationAuthority));
    }

    // ==== .addModule type filing Tests ====

    /// @notice Binding files the module under the type it names and announces the declaration.
    function test_addModule_Success_WhenModuleNamesAType() public {
        address module = _deploy(address(new RuleOnlyModule()));

        vm.expectEmit(true, false, false, true);
        emit EventsLib.ModuleAdded(module);
        vm.prank(deployer);
        mc.addModule(module);

        assertTrue(mc.isModuleBound(module));
        assertEq(mc.getModules().length, 1);
        _assertListed(IModule.ModuleType.RULE, module);
        assertEq(mc.getModulesByType(IModule.ModuleType.SPENDER).length, 0);
        assertEq(mc.getModulesByType(IModule.ModuleType.TRACKER).length, 0);
    }

    /// @notice Each module lands only in the lists of the types it named.
    function test_addModule_Success_WhenSeveralModulesNameDifferentTypes() public {
        address rule = _deploy(address(new RuleOnlyModule()));
        address spender = _deploy(address(new SpenderOnlyModule()));
        address tracker = _deploy(address(new TrackerOnlyModule()));

        _bind(rule);
        _bind(spender);
        _bind(tracker);

        assertEq(mc.getModules().length, 3);
        _assertListed(IModule.ModuleType.RULE, rule);
        _assertListed(IModule.ModuleType.SPENDER, spender);
        _assertListed(IModule.ModuleType.TRACKER, tracker);
    }

    /// @notice A module naming several types is filed under each of them, and appears once in `getModules`.
    function test_addModule_Success_WhenModuleNamesSeveralTypes() public {
        address ruleAndTracker = _deploy(address(new RuleAndTrackerModule()));

        _bind(ruleAndTracker);

        assertEq(mc.getModules().length, 1, "listed once overall");
        _assertListed(IModule.ModuleType.RULE, ruleAndTracker);
        _assertListed(IModule.ModuleType.TRACKER, ruleAndTracker);
        assertEq(mc.getModulesByType(IModule.ModuleType.SPENDER).length, 0);
    }

    /// @notice A module naming all three is asked every question.
    function test_addModule_Success_WhenModuleNamesEveryType() public {
        address everything = _deploy(address(new AllTypesModule()));

        _bind(everything);

        _assertListed(IModule.ModuleType.RULE, everything);
        _assertListed(IModule.ModuleType.SPENDER, everything);
        _assertListed(IModule.ModuleType.TRACKER, everything);
    }

    /// @notice A module the compliance would never call is refused rather than bound and ignored.
    function test_addModule_RevertWhen_ModuleNamesNoType() public {
        address module = _deploy(address(new NoTypeModule()));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleHasNoType.selector);
        mc.addModule(module);

        assertFalse(mc.isModuleBound(module));
    }

    /// @notice Naming a type twice is a declaration its author did not mean, so it is refused outright.
    function test_addModule_RevertWhen_ModuleNamesATypeTwice() public {
        address module = _deploy(address(new DuplicateTypeModule()));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DuplicateModuleType.selector, uint8(IModule.ModuleType.RULE)));
        mc.addModule(module);

        assertFalse(mc.isModuleBound(module));
    }

    /// @notice A rejected attempt leaves nothing behind: the same address binds once its declaration is fixed.
    function test_addModule_Success_WhenBindingAfterARejectedAttempt() public {
        address module = _deploy(address(new NoTypeModule()));
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleHasNoType.selector);
        mc.addModule(module);

        RecordingModule(module).upgradeToAndCall(address(new RuleOnlyModule()), "");

        _bind(module);
        assertTrue(mc.isModuleBound(module));
        _assertListed(IModule.ModuleType.RULE, module);
    }

    // ==== .getModulesByType Tests ====

    /// @notice One getter per type, listing modules in the order they were bound.
    function test_getModulesByType_Success_WhenModulesNameDifferentTypes() public {
        address tracker = _deploy(address(new TrackerOnlyModule()));
        address rule = _deploy(address(new RuleOnlyModule()));
        address everything = _deploy(address(new AllTypesModule()));

        _bind(tracker);
        _bind(rule);
        _bind(everything);

        address[] memory trackers = mc.getModulesByType(IModule.ModuleType.TRACKER);
        assertEq(trackers.length, 2);
        assertEq(trackers[0], tracker);
        assertEq(trackers[1], everything);

        address[] memory rules = mc.getModulesByType(IModule.ModuleType.RULE);
        assertEq(rules.length, 2);
        assertEq(rules[0], rule);
        assertEq(rules[1], everything);

        assertEq(mc.getModulesByType(IModule.ModuleType.SPENDER).length, 1);
    }

    // ==== .removeModule Tests ====

    /// @notice Removing from the middle keeps every remaining module bound and listed.
    function test_removeModule_Success_WhenRemovingFromTheMiddle() public {
        address first = _deploy(address(new RuleOnlyModule()));
        address middle = _deploy(address(new SpenderOnlyModule()));
        address last = _deploy(address(new TrackerOnlyModule()));
        _bind(first);
        _bind(middle);
        _bind(last);

        vm.prank(deployer);
        mc.removeModule(middle);

        assertEq(mc.getModules().length, 2);
        assertTrue(mc.isModuleBound(first));
        assertFalse(mc.isModuleBound(middle));
        assertTrue(mc.isModuleBound(last));
        assertEq(mc.getModulesByType(IModule.ModuleType.SPENDER).length, 0, "dropped from its type list");
        _assertListed(IModule.ModuleType.RULE, first);
        _assertListed(IModule.ModuleType.TRACKER, last);
    }

    /// @notice A module naming several types leaves all of their lists at once.
    function test_removeModule_Success_WhenModuleNamedSeveralTypes() public {
        address everything = _deploy(address(new AllTypesModule()));
        _bind(everything);

        vm.prank(deployer);
        mc.removeModule(everything);

        assertEq(mc.getModules().length, 0);
        assertEq(mc.getModulesByType(IModule.ModuleType.RULE).length, 0);
        assertEq(mc.getModulesByType(IModule.ModuleType.SPENDER).length, 0);
        assertEq(mc.getModulesByType(IModule.ModuleType.TRACKER).length, 0);
    }

    function test_removeModule_Success_WhenRemovingTheOnlyModule() public {
        address module = _deploy(address(new RuleOnlyModule()));
        _bind(module);

        vm.prank(deployer);
        mc.removeModule(module);

        assertEq(mc.getModules().length, 0);
        assertFalse(mc.isModuleBound(module));
    }

    // ==== .resyncModuleTypes Tests ====

    /// @notice A module upgraded to a different declaration is refiled, and stops being called where it no
    ///         longer answers.
    function test_resyncModuleTypes_Success_WhenTheDeclarationChanged() public {
        address module = _deploy(address(new RuleOnlyModule()));
        _bind(module);
        _assertListed(IModule.ModuleType.RULE, module);

        RecordingModule(module).upgradeToAndCall(address(new TrackerOnlyModule()), "");

        vm.prank(deployer);
        mc.resyncModuleTypes(module);

        assertEq(mc.getModulesByType(IModule.ModuleType.RULE).length, 0, "no longer a rule");
        _assertListed(IModule.ModuleType.TRACKER, module);
        assertTrue(mc.isModuleBound(module), "still bound, so its settings survive");
    }

    /// @notice A resync rewrites one module's filing: the others and the bind order are untouched.
    function test_resyncModuleTypes_Success_WhenOtherModulesAreBound() public {
        address first = _deploy(address(new RuleOnlyModule()));
        address second = _deploy(address(new TrackerOnlyModule()));
        _bind(first);
        _bind(second);

        RecordingModule(first).upgradeToAndCall(address(new SpenderOnlyModule()), "");
        vm.prank(deployer);
        mc.resyncModuleTypes(first);

        assertEq(mc.getModules().length, 2);
        _assertListed(IModule.ModuleType.SPENDER, first);
        _assertListed(IModule.ModuleType.TRACKER, second);
        assertEq(mc.getModulesByType(IModule.ModuleType.RULE).length, 0);
    }

    function test_resyncModuleTypes_Success_WhenNothingChanged() public {
        address module = _deploy(address(new RuleOnlyModule()));
        _bind(module);

        vm.prank(deployer);
        mc.resyncModuleTypes(module);

        _assertListed(IModule.ModuleType.RULE, module);
        assertEq(mc.getModules().length, 1);
    }

    function test_resyncModuleTypes_RevertWhen_ModuleIsNotBound() public {
        address module = _deploy(address(new RuleOnlyModule()));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleNotBound.selector);
        mc.resyncModuleTypes(module);
    }

    /// @notice An upgrade that left the module answering nothing is refused, so the compliance never keeps a
    ///         module it would never call.
    function test_resyncModuleTypes_RevertWhen_DeclarationBecameEmpty() public {
        address module = _deploy(address(new RuleOnlyModule()));
        _bind(module);

        RecordingModule(module).upgradeToAndCall(address(new NoTypeModule()), "");

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleHasNoType.selector);
        mc.resyncModuleTypes(module);
    }

    function test_resyncModuleTypes_RevertWhen_CallerIsNotOwner() public {
        address module = _deploy(address(new RuleOnlyModule()));
        _bind(module);

        vm.prank(alice);
        vm.expectRevert();
        mc.resyncModuleTypes(module);
    }

    /// @dev Asserts `module` is the only entry of that type's list.
    function _assertListed(IModule.ModuleType moduleType, address module) private view {
        address[] memory listed = mc.getModulesByType(moduleType);
        assertEq(listed.length, 1, "expected exactly one module of this type");
        assertEq(listed[0], module, "wrong module listed");
    }

    function _bind(address module) private {
        vm.prank(deployer);
        mc.addModule(module);
    }

    function _deploy(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

}
