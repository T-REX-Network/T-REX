// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
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
    TransferHookOnlyModule,
    UndefinedBitModule,
    ZeroCapabilityModule
} from "test/integration/mocks/CapabilityModules.sol";

/// @dev Binding lifecycle for capability-declaring modules: what a compliance records, what it
///      refuses, and what survives a removal from the middle of the bound set.
contract ComplianceCapabilitiesTest is TREXSuiteTest {

    ModularCompliance internal mc;

    function setUp() public override {
        super.setUp();
        mc = _newUnboundComplianceProxy(address(trexImplementationAuthority));
    }

    // ==== .addModule capability recording Tests ====

    /// @notice Binding records the module's declaration and announces it.
    function test_addModule_Success_WhenModuleDeclaresACapability() public {
        address module = _deploy(address(new MintOnlyModule()));

        vm.expectEmit(true, false, false, true);
        emit EventsLib.ModuleCapabilitiesRecorded(module, Caps.HOOK_MINT);
        vm.prank(deployer);
        mc.addModule(module);

        assertEq(mc.getModuleCapabilities(module), Caps.HOOK_MINT);
        assertTrue(mc.isModuleBound(module));
    }

    /// @notice The recorded declaration survives alongside the module address.
    function test_addModule_Success_WhenSeveralModulesDeclareDifferentCapabilities() public {
        address mintOnly = _deploy(address(new MintOnlyModule()));
        address burnOnly = _deploy(address(new BurnOnlyModule()));
        address everything = _deploy(address(new AllCapabilitiesModule()));

        _bind(mintOnly);
        _bind(burnOnly);
        _bind(everything);

        assertEq(mc.getModuleCapabilities(mintOnly), Caps.HOOK_MINT);
        assertEq(mc.getModuleCapabilities(burnOnly), Caps.HOOK_BURN);
        assertEq(mc.getModuleCapabilities(everything), Caps.ALL);

        address[] memory modules = mc.getModules();
        assertEq(modules.length, 3);
        assertEq(modules[0], mintOnly);
        assertEq(modules[1], burnOnly);
        assertEq(modules[2], everything);
    }

    /// @notice A module declaring nothing cannot be bound.
    function test_addModule_RevertWhen_ModuleDeclaresNoCapability() public {
        address module = _deploy(address(new ZeroCapabilityModule()));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleHasNoCapabilities.selector);
        mc.addModule(module);

        assertFalse(mc.isModuleBound(module));
        assertEq(mc.getModules().length, 0);
    }

    /// @notice A declaration carrying a bit the compliance cannot route is rejected.
    function test_addModule_RevertWhen_ModuleDeclaresAnUndefinedBit() public {
        address module = _deploy(address(new UndefinedBitModule()));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidModuleCapabilities.selector, uint256(1 << 7)));
        mc.addModule(module);

        assertFalse(mc.isModuleBound(module));
    }

    /// @notice An address that cannot answer the declaration call cannot be bound.
    function test_addModule_RevertWhen_ModuleCannotDeclare() public {
        vm.prank(deployer);
        vm.expectRevert();
        mc.addModule(makeAddr("eoa"));

        assertEq(mc.getModules().length, 0);
    }

    /// @notice A rejected bind leaves nothing behind for the next attempt.
    function test_addModule_Success_WhenRebindingAfterARejectedAttempt() public {
        address rejected = _deploy(address(new ZeroCapabilityModule()));
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleHasNoCapabilities.selector);
        mc.addModule(rejected);

        address accepted = _deploy(address(new MintOnlyModule()));
        _bind(accepted);

        assertEq(mc.getModules().length, 1);
        assertEq(mc.getModules()[0], accepted);
    }

    /// @notice The declaration is only readable for a bound module.
    function test_getModuleCapabilities_RevertWhen_ModuleIsNotBound() public {
        address module = _deploy(address(new MintOnlyModule()));

        vm.expectRevert(ErrorsLib.ModuleNotBound.selector);
        mc.getModuleCapabilities(module);
    }

    // ==== .getModulesByCapability Tests ====

    /// @notice Only the modules that declared a dispatch point are listed for it.
    function test_getModulesByCapability_Success_WhenModulesDeclareDifferentPoints() public {
        address mintOnly = _deploy(address(new MintOnlyModule()));
        address checkOnly = _deploy(address(new CheckTransferOnlyModule()));
        address everything = _deploy(address(new AllCapabilitiesModule()));

        _bind(mintOnly);
        _bind(checkOnly);
        _bind(everything);

        address[] memory minters = mc.getModulesByCapability(Caps.HOOK_MINT);
        assertEq(minters.length, 2);
        assertEq(minters[0], mintOnly);
        assertEq(minters[1], everything);

        address[] memory checkers = mc.getModulesByCapability(Caps.CHECK_TRANSFER);
        assertEq(checkers.length, 2);
        assertEq(checkers[0], checkOnly);
        assertEq(checkers[1], everything);

        assertEq(mc.getModulesByCapability(Caps.HOOK_BURN).length, 1);
        assertEq(mc.getModulesByCapability(Caps.CHECK_SPENDER).length, 1);
    }

    // ==== .removeModule Tests ====

    /// @notice Removing from the middle keeps every remaining module resolvable.
    function test_removeModule_Success_WhenRemovingFromTheMiddle() public {
        address first = _deploy(address(new MintOnlyModule()));
        address middle = _deploy(address(new BurnOnlyModule()));
        address last = _deploy(address(new TransferHookOnlyModule()));

        _bind(first);
        _bind(middle);
        _bind(last);

        vm.prank(deployer);
        mc.removeModule(middle);

        assertFalse(mc.isModuleBound(middle));
        assertTrue(mc.isModuleBound(first));
        assertTrue(mc.isModuleBound(last));
        assertEq(mc.getModuleCapabilities(first), Caps.HOOK_MINT);
        assertEq(mc.getModuleCapabilities(last), Caps.HOOK_TRANSFER);

        address[] memory modules = mc.getModules();
        assertEq(modules.length, 2);
        // swap-and-pop moved the last entry into the freed slot
        assertEq(modules[0], first);
        assertEq(modules[1], last);
    }

    /// @notice Removing the last-positioned module needs no swap.
    function test_removeModule_Success_WhenRemovingTheLastPosition() public {
        address first = _deploy(address(new MintOnlyModule()));
        address last = _deploy(address(new BurnOnlyModule()));
        _bind(first);
        _bind(last);

        vm.prank(deployer);
        mc.removeModule(last);

        assertEq(mc.getModules().length, 1);
        assertEq(mc.getModules()[0], first);
        assertEq(mc.getModuleCapabilities(first), Caps.HOOK_MINT);
    }

    /// @notice Removing the only module empties the bound set.
    function test_removeModule_Success_WhenRemovingTheOnlyModule() public {
        address only = _deploy(address(new MintOnlyModule()));
        _bind(only);

        vm.prank(deployer);
        mc.removeModule(only);

        assertEq(mc.getModules().length, 0);
        assertFalse(mc.isModuleBound(only));
    }

    /// @notice A removed module can be bound again, and lands at the end.
    function test_removeModule_Success_WhenRebindingARemovedModule() public {
        address first = _deploy(address(new MintOnlyModule()));
        address second = _deploy(address(new BurnOnlyModule()));
        _bind(first);
        _bind(second);

        vm.startPrank(deployer);
        mc.removeModule(first);
        mc.addModule(first);
        vm.stopPrank();

        address[] memory modules = mc.getModules();
        assertEq(modules.length, 2);
        assertEq(modules[0], second);
        assertEq(modules[1], first);
        assertEq(mc.getModuleCapabilities(first), Caps.HOOK_MINT);
    }

    // ==== .refreshModuleCapabilities Tests ====

    /// @notice Refreshing picks up a declaration an implementation upgrade changed.
    function test_refreshModuleCapabilities_Success_WhenTheDeclarationChanged() public {
        address module = _deploy(address(new MintOnlyModule()));
        _bind(module);
        assertEq(mc.getModuleCapabilities(module), Caps.HOOK_MINT);

        // the module is upgraded to an implementation declaring a different dispatch point
        RecordingModule(module).upgradeToAndCall(address(new BurnOnlyModule()), "");

        vm.expectEmit(true, false, false, true);
        emit EventsLib.ModuleCapabilitiesRecorded(module, Caps.HOOK_BURN);
        vm.prank(deployer);
        mc.refreshModuleCapabilities(module);

        assertEq(mc.getModuleCapabilities(module), Caps.HOOK_BURN);
    }

    /// @notice A refresh rewrites one entry: the other bound modules and the bind order are untouched.
    function test_refreshModuleCapabilities_Success_WhenOtherModulesAreBound() public {
        address first = _deploy(address(new MintOnlyModule()));
        address second = _deploy(address(new BurnOnlyModule()));
        _bind(first);
        _bind(second);

        RecordingModule(first).upgradeToAndCall(address(new TransferHookOnlyModule()), "");

        vm.prank(deployer);
        mc.refreshModuleCapabilities(first);

        address[] memory modules = mc.getModules();
        assertEq(modules.length, 2);
        assertEq(modules[0], first);
        assertEq(modules[1], second);
        assertEq(mc.getModuleCapabilities(first), Caps.HOOK_TRANSFER);
        assertEq(mc.getModuleCapabilities(second), Caps.HOOK_BURN);
    }

    /// @notice Refreshing an unchanged module is a no-op that still announces the state.
    function test_refreshModuleCapabilities_Success_WhenNothingChanged() public {
        address module = _deploy(address(new MintOnlyModule()));
        _bind(module);

        vm.expectEmit(true, false, false, true);
        emit EventsLib.ModuleCapabilitiesRecorded(module, Caps.HOOK_MINT);
        vm.prank(deployer);
        mc.refreshModuleCapabilities(module);

        assertEq(mc.getModuleCapabilities(module), Caps.HOOK_MINT);
        assertEq(mc.getModules().length, 1);
    }

    /// @notice An unbound module has no routing to refresh.
    function test_refreshModuleCapabilities_RevertWhen_ModuleIsNotBound() public {
        address module = _deploy(address(new MintOnlyModule()));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleNotBound.selector);
        mc.refreshModuleCapabilities(module);
    }

    /// @notice A module that stops declaring anything must be unbound explicitly, not silently.
    function test_refreshModuleCapabilities_RevertWhen_DeclarationBecameEmpty() public {
        address module = _deploy(address(new MintOnlyModule()));
        _bind(module);

        RecordingModule(module).upgradeToAndCall(address(new ZeroCapabilityModule()), "");

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ModuleHasNoCapabilities.selector);
        mc.refreshModuleCapabilities(module);

        // still bound, with the routing it had before
        assertTrue(mc.isModuleBound(module));
        assertEq(mc.getModuleCapabilities(module), Caps.HOOK_MINT);
    }

    /// @notice Only the OWNER role may re-route a bound module.
    function test_refreshModuleCapabilities_RevertWhen_CallerIsNotOwner() public {
        address module = _deploy(address(new MintOnlyModule()));
        _bind(module);

        vm.prank(alice);
        vm.expectRevert();
        mc.refreshModuleCapabilities(module);
    }

    function _bind(address module) private {
        vm.prank(deployer);
        mc.addModule(module);
    }

    function _deploy(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

}
