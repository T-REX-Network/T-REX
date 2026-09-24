// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { MulticallUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import {
    AllTypesModule,
    RecordingModule,
    RuleOnlyModule,
    SpenderOnlyModule,
    TrackerOnlyModule
} from "test/integration/mocks/CapabilityModules.sol";
import { RevertEverywhereModule, UnbindRevertingModule } from "test/integration/mocks/HostileModules.sol";

contract ComplianceForceRemoveTest is TREXSuiteTest {

    ModularCompliance internal mc;
    address internal revertEverywhere;

    function setUp() public override {
        super.setUp();
        mc = ModularCompliance(address(token.compliance()));
        revertEverywhere = address(new RevertEverywhereModule());

        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.mint(bob, 500);
        token.unpause();
        vm.stopPrank();
    }

    function test_removeModule_RevertWhen_ModuleRevertsFromUnbindCompliance_ForceRemovalStillWorks() public {
        address module = address(new UnbindRevertingModule());
        _bind(module);

        vm.prank(deployer);
        vm.expectRevert(UnbindRevertingModule.UnbindRefused.selector);
        mc.removeModule(module);
        assertTrue(mc.isModuleBound(module));

        vm.prank(deployer);
        mc.forceRemoveModule(module);
        assertFalse(mc.isModuleBound(module));
        assertEq(mc.getModules().length, 0);
        _assertNoRouting(module);
    }

    function test_removeModule_RevertWhen_ModuleRevertsEverywhere() public {
        address module = _bindHostage(address(new AllTypesModule()));

        vm.prank(alice);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.transfer(bob, 100);

        vm.prank(deployer);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        mc.removeModule(module);
        assertTrue(mc.isModuleBound(module));
    }

    function testFuzz_removeModule_NeverRemovesWithoutUnbinding(uint64 gasLimit) public {
        gasLimit = uint64(bound(gasLimit, 30_000, 400_000));
        address module = _deploy(address(new AllTypesModule()));
        _bind(module);

        vm.prank(deployer);
        (bool removed,) = address(mc).call{ gas: gasLimit }(abi.encodeCall(ModularCompliance.removeModule, (module)));

        assertEq(mc.isModuleBound(module), !removed);
        assertEq(IModule(module).isComplianceBound(address(mc)), !removed);
    }

    function test_removeModule_Success_WhenModuleIsHealthy_UnbindsIt() public {
        address module = _deploy(address(new AllTypesModule()));
        _bind(module);

        vm.prank(deployer);
        mc.removeModule(module);

        assertFalse(mc.isModuleBound(module));
        assertFalse(IModule(module).isComplianceBound(address(mc)));
    }

    function test_forceRemoveModule_Success_WhenModuleRevertsEverywhere() public {
        address module = _bindHostage(address(new AllTypesModule()));

        vm.recordLogs();
        vm.expectEmit(true, false, false, false, address(mc));
        emit EventsLib.ModuleForceRemoved(module);
        vm.prank(deployer);
        mc.forceRemoveModule(module);

        assertFalse(_logged(EventsLib.ModuleRemoved.selector));
        assertFalse(mc.isModuleBound(module));
        assertEq(mc.getModules().length, 0);
        _assertNoRouting(module);
        _assertTokenOperationsWork();
    }

    function test_forceRemoveModule_Success_WhenARuleIsHeldHostage() public {
        address hostage = _bindHostage(address(new RuleOnlyModule()));

        vm.prank(alice);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.transfer(bob, 100);

        _forceRemove(hostage, IModule.ModuleType.RULE);

        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 600);
    }

    /// @notice A tracker holds every movement hostage at once, since it is told about all three. Removing it
    ///         frees the transfer, the mint and the burn together.
    function test_forceRemoveModule_Success_WhenATrackerIsHeldHostage() public {
        address hostage = _bindHostage(address(new TrackerOnlyModule()));

        vm.prank(alice);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.transfer(bob, 100);
        vm.prank(agent);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.mint(alice, 10);
        vm.prank(agent);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.burn(alice, 10);

        _forceRemove(hostage, IModule.ModuleType.TRACKER);

        vm.prank(alice);
        token.transfer(bob, 100);
        vm.prank(agent);
        token.mint(alice, 10);
        vm.prank(agent);
        token.burn(alice, 10);
        assertEq(token.balanceOf(bob), 600);
    }

    function test_forceRemoveModule_Success_WhenASpenderRuleIsHeldHostage() public {
        address hostage = _bindHostage(address(new SpenderOnlyModule()));
        vm.prank(alice);
        token.approve(another, 100);

        vm.prank(another);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.transferFrom(alice, bob, 100);

        _forceRemove(hostage, IModule.ModuleType.SPENDER);

        vm.prank(another);
        token.transferFrom(alice, bob, 100);
        assertEq(token.balanceOf(bob), 600);
    }

    function test_forceRemoveModule_Success_KeepsOtherModulesRouted() public {
        address healthy = _deploy(address(new TrackerOnlyModule()));
        _bind(healthy);
        address hostage = _bindHostage(address(new RuleOnlyModule()));

        vm.prank(deployer);
        mc.forceRemoveModule(hostage);

        address[] memory trackers = mc.getModulesByType(IModule.ModuleType.TRACKER);
        assertEq(trackers.length, 1);
        assertEq(trackers[0], healthy);
        assertEq(mc.getModules().length, 1);
        vm.prank(agent);
        token.mint(alice, 1);
        assertEq(RecordingModule(healthy).mintActionCalls(), 1);
    }

    function test_forceRemoveModule_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        mc.forceRemoveModule(address(0));
    }

    function test_forceRemoveModule_RevertWhen_ModuleAddressIsZero() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        mc.forceRemoveModule(address(0));
    }

    function test_forceRemoveModule_RevertWhen_ModuleNotBound() public {
        address module = _deploy(address(new TrackerOnlyModule()));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleNotBound.selector);
        mc.forceRemoveModule(module);
    }

    function test_addModule_RevertWhen_RebindingAForceRemovedModule() public {
        address module = _deploy(address(new AllTypesModule()));
        _bind(module);
        vm.prank(deployer);
        mc.forceRemoveModule(module);
        assertTrue(IModule(module).isComplianceBound(address(mc)));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ComplianceAlreadyBound.selector);
        mc.addModule(module);
        assertFalse(mc.isModuleBound(module));
    }

    function test_addModule_Success_WhenRebindingAfterRemoveModuleUnbound() public {
        address module = _bindHostage(address(new AllTypesModule()));
        UUPSUpgradeable(module).upgradeToAndCall(address(new AllTypesModule()), "");

        vm.prank(deployer);
        mc.removeModule(module);
        assertFalse(IModule(module).isComplianceBound(address(mc)));
        _bind(module);

        assertTrue(mc.isModuleBound(module));
        _assertTokenOperationsWork();
    }

    function test_removeModule_RevertWhen_ModuleHasNoCode_ForceRemovalStillWorks() public {
        address module = _deploy(address(new AllTypesModule()));
        _bind(module);
        vm.etch(module, "");

        vm.prank(deployer);
        vm.expectRevert();
        mc.removeModule(module);
        assertTrue(mc.isModuleBound(module));

        vm.expectEmit(true, false, false, false, address(mc));
        emit EventsLib.ModuleForceRemoved(module);
        vm.prank(deployer);
        mc.forceRemoveModule(module);
        assertFalse(mc.isModuleBound(module));
    }

    function test_callModuleFunction_RevertWhen_ForwardingUnbindCompliance() public {
        address module = _deploy(address(new AllTypesModule()));
        _bind(module);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleStillBound.selector);
        mc.callModuleFunction(abi.encodeCall(IModule.unbindCompliance, (address(mc))), module);

        assertTrue(IModule(module).isComplianceBound(address(mc)));
        assertTrue(mc.isModuleBound(module));
    }

    function test_callModuleFunction_RevertWhen_ForwardingUnbindComplianceThroughMulticall() public {
        address module = _deploy(address(new AllTypesModule()));
        _bind(module);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IModule.unbindCompliance, (address(mc)));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleStillBound.selector);
        mc.callModuleFunction(abi.encodeCall(MulticallUpgradeable.multicall, (calls)), module);

        assertTrue(IModule(module).isComplianceBound(address(mc)));
        assertTrue(mc.isModuleBound(module));
        vm.prank(agent);
        token.mint(alice, 1);
    }

    function _forceRemove(address hostage, IModule.ModuleType moduleType) private {
        vm.prank(deployer);
        mc.forceRemoveModule(hostage);
        assertFalse(mc.isModuleBound(hostage));
        assertEq(mc.getModulesByType(moduleType).length, 0);
    }

    function _bindHostage(address implementation) private returns (address module) {
        module = _deploy(implementation);
        _bind(module);
        UUPSUpgradeable(module).upgradeToAndCall(revertEverywhere, "");
    }

    function _assertTokenOperationsWork() private {
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, 100);
        vm.prank(agent);
        token.mint(alice, 10);
        vm.prank(agent);
        token.burn(alice, 5);
        vm.prank(alice);
        token.approve(another, 50);
        vm.prank(another);
        token.transferFrom(alice, bob, 50);

        assertEq(token.balanceOf(alice), aliceBefore - 100 + 10 - 5 - 50);
        assertEq(token.balanceOf(bob), bobBefore + 100 + 50);
    }

    function _assertNoRouting(address module) private view {
        IModule.ModuleType[3] memory types =
            [IModule.ModuleType.RULE, IModule.ModuleType.SPENDER, IModule.ModuleType.TRACKER];
        for (uint256 i = 0; i < types.length; i++) {
            address[] memory routed = mc.getModulesByType(types[i]);
            for (uint256 j = 0; j < routed.length; j++) {
                assertNotEq(routed[j], module);
            }
        }
    }

    function _logged(bytes32 topic) private returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }

    function _bind(address module) private {
        vm.prank(deployer);
        mc.addModule(module);
    }

    function _deploy(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

}
