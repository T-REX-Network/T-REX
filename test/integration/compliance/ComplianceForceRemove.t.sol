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
import { ModuleCapabilitiesLib as Caps } from "contracts/libraries/ModuleCapabilitiesLib.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import {
    AllCapabilitiesModule,
    BurnOnlyModule,
    CheckTransferOnlyModule,
    MintOnlyModule,
    RecordingModule,
    SpenderCheckOnlyModule,
    TransferHookOnlyModule
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

    function test_removeModule_Success_WhenModuleRevertsFromUnbindCompliance() public {
        address module = address(new UnbindRevertingModule());
        _bind(module);

        vm.expectEmit(true, false, false, false, address(mc));
        emit EventsLib.ModuleUnbindingFailed(module);
        vm.expectEmit(true, false, false, false, address(mc));
        emit EventsLib.ModuleRemoved(module);
        vm.prank(deployer);
        mc.removeModule(module);

        assertFalse(mc.isModuleBound(module));
        assertEq(mc.getModules().length, 0);
        _assertNoRouting(module);
    }

    function test_removeModule_Success_WhenModuleRevertsEverywhere() public {
        address module = _bindHostage(address(new AllCapabilitiesModule()));

        vm.prank(alice);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.transfer(bob, 100);

        vm.expectEmit(true, false, false, false, address(mc));
        emit EventsLib.ModuleUnbindingFailed(module);
        vm.prank(deployer);
        mc.removeModule(module);

        assertFalse(mc.isModuleBound(module));
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 600);
    }

    function test_removeModule_Success_WhenModuleIsHealthy_UnbindsIt() public {
        address module = _deploy(address(new AllCapabilitiesModule()));
        _bind(module);

        vm.recordLogs();
        vm.prank(deployer);
        mc.removeModule(module);

        assertFalse(IModule(module).isComplianceBound(address(mc)));
        assertFalse(_logged(EventsLib.ModuleUnbindingFailed.selector));
    }

    function test_forceRemoveModule_Success_WhenModuleRevertsEverywhere() public {
        address module = _bindHostage(address(new AllCapabilitiesModule()));

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

    function test_forceRemoveModule_Success_WhenCheckTransferIsHeldHostage() public {
        address hostage = _bindHostage(address(new CheckTransferOnlyModule()));

        vm.prank(alice);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.transfer(bob, 100);

        _forceRemove(hostage, Caps.CHECK_TRANSFER);

        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 600);
    }

    function test_forceRemoveModule_Success_WhenTransferHookIsHeldHostage() public {
        address hostage = _bindHostage(address(new TransferHookOnlyModule()));

        vm.prank(alice);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.transfer(bob, 100);

        _forceRemove(hostage, Caps.HOOK_TRANSFER);

        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 600);
    }

    function test_forceRemoveModule_Success_WhenMintHookIsHeldHostage() public {
        address hostage = _bindHostage(address(new MintOnlyModule()));

        vm.prank(agent);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.mint(alice, 10);

        _forceRemove(hostage, Caps.HOOK_MINT);

        vm.prank(agent);
        token.mint(alice, 10);
        assertEq(token.balanceOf(alice), 1010);
    }

    function test_forceRemoveModule_Success_WhenBurnHookIsHeldHostage() public {
        address hostage = _bindHostage(address(new BurnOnlyModule()));

        vm.prank(agent);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.burn(alice, 10);

        _forceRemove(hostage, Caps.HOOK_BURN);

        vm.prank(agent);
        token.burn(alice, 10);
        assertEq(token.balanceOf(alice), 990);
    }

    function test_forceRemoveModule_Success_WhenSpenderCheckIsHeldHostage() public {
        address hostage = _bindHostage(address(new SpenderCheckOnlyModule()));
        vm.prank(alice);
        token.approve(another, 100);

        vm.prank(another);
        vm.expectRevert(RevertEverywhereModule.ModuleHostage.selector);
        token.transferFrom(alice, bob, 100);

        _forceRemove(hostage, Caps.CHECK_SPENDER);

        vm.prank(another);
        token.transferFrom(alice, bob, 100);
        assertEq(token.balanceOf(bob), 600);
    }

    function test_forceRemoveModule_Success_KeepsOtherModulesRouted() public {
        address healthy = _deploy(address(new MintOnlyModule()));
        _bind(healthy);
        address hostage = _bindHostage(address(new BurnOnlyModule()));

        vm.prank(deployer);
        mc.forceRemoveModule(hostage);

        address[] memory minters = mc.getModulesByCapability(Caps.HOOK_MINT);
        assertEq(minters.length, 1);
        assertEq(minters[0], healthy);
        assertEq(mc.getModules().length, 1);
        vm.prank(agent);
        token.mint(alice, 1);
        assertEq(RecordingModule(healthy).mintHookCalls(), 1);
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
        address module = _deploy(address(new MintOnlyModule()));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleNotBound.selector);
        mc.forceRemoveModule(module);
    }

    function test_addModule_RevertWhen_RebindingAForceRemovedModule() public {
        address module = _deploy(address(new AllCapabilitiesModule()));
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
        address module = _bindHostage(address(new AllCapabilitiesModule()));
        UUPSUpgradeable(module).upgradeToAndCall(address(new AllCapabilitiesModule()), "");

        vm.prank(deployer);
        mc.removeModule(module);
        assertFalse(IModule(module).isComplianceBound(address(mc)));
        _bind(module);

        assertTrue(mc.isModuleBound(module));
        _assertTokenOperationsWork();
    }

    function test_removeModule_Success_WhenModuleHasNoCode() public {
        address module = _deploy(address(new AllCapabilitiesModule()));
        _bind(module);
        vm.etch(module, "");

        vm.expectEmit(true, false, false, false, address(mc));
        emit EventsLib.ModuleRemoved(module);
        vm.prank(deployer);
        mc.removeModule(module);

        assertFalse(mc.isModuleBound(module));
    }

    function test_callModuleFunction_RevertWhen_ForwardingUnbindCompliance() public {
        address module = _deploy(address(new AllCapabilitiesModule()));
        _bind(module);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleStillBound.selector);
        mc.callModuleFunction(abi.encodeCall(IModule.unbindCompliance, (address(mc))), module);

        assertTrue(IModule(module).isComplianceBound(address(mc)));
        assertTrue(mc.isModuleBound(module));
    }

    function test_callModuleFunction_RevertWhen_ForwardingUnbindComplianceThroughMulticall() public {
        address module = _deploy(address(new AllCapabilitiesModule()));
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

    function _forceRemove(address hostage, uint256 capability) private {
        vm.prank(deployer);
        mc.forceRemoveModule(hostage);
        assertFalse(mc.isModuleBound(hostage));
        assertEq(mc.getModulesByCapability(capability).length, 0);
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
        uint256[5] memory bits =
            [Caps.CHECK_TRANSFER, Caps.HOOK_TRANSFER, Caps.HOOK_MINT, Caps.HOOK_BURN, Caps.CHECK_SPENDER];
        for (uint256 i = 0; i < bits.length; i++) {
            address[] memory routed = mc.getModulesByCapability(bits[i]);
            for (uint256 j = 0; j < routed.length; j++) {
                assertNotEq(routed[j], module);
            }
        }
    }

    function _logged(bytes32 topic) private view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) return true;
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
