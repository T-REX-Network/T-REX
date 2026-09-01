// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { SpenderVerificationModule } from "contracts/compliance/modular/modules/SpenderVerificationModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { ModuleCapabilitiesLib } from "contracts/libraries/ModuleCapabilitiesLib.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";

import { Countries } from "test/integration/helpers/Countries.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @dev The rule PR #4 hardcoded in the token, as an opt-in module: only a verified spender may
///      move someone else's tokens. `charlie` holds a registered identity, `another` does not.
contract SpenderVerificationModuleTest is TREXSuiteTest {

    ModularCompliance internal mc;
    IdentityRegistry internal identityRegistry;
    SpenderVerificationModule internal module;

    function setUp() public override {
        super.setUp();

        mc = ModularCompliance(address(token.compliance()));
        identityRegistry = IdentityRegistry(address(token.identityRegistry()));

        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();

        module = _deployModule();

        vm.prank(deployer);
        mc.addModule(address(module));
    }

    // ============ Declaration Tests ============

    /// @notice Should declare the spender check and nothing else
    function test_moduleCapabilities_DeclaresOnlyTheSpenderCheck() public view {
        assertEq(module.moduleCapabilities(), ModuleCapabilitiesLib.CHECK_SPENDER);
        assertEq(mc.getModuleCapabilities(address(module)), ModuleCapabilitiesLib.CHECK_SPENDER);
    }

    /// @notice Should claim plug and play: the module holds no per-compliance state to set up
    function test_isPlugAndPlay_Success() public view {
        assertTrue(module.isPlugAndPlay());
        assertEq(module.name(), "SpenderVerificationModule");
    }

    /// @notice Should bind to a compliance that has no token yet: the registry is resolved at check time
    function test_addModule_Success_WhenComplianceHasNoToken() public {
        ModularCompliance unbound = _newUnboundComplianceProxy(address(trexImplementationAuthority));
        SpenderVerificationModule fresh = _deployModule();

        assertTrue(fresh.canComplianceBind(address(unbound)));

        vm.prank(deployer);
        unbound.addModule(address(fresh));

        assertEq(unbound.getModuleCapabilities(address(fresh)), ModuleCapabilitiesLib.CHECK_SPENDER);
    }

    // ============ Enforcement Tests ============

    /// @notice Should let a verified spender move the holder's tokens
    function test_transferFrom_Success_WhenSpenderIsVerified() public {
        assertTrue(identityRegistry.isVerified(charlie));

        vm.prank(alice);
        token.approve(charlie, 100);

        vm.prank(charlie);
        token.transferFrom(alice, bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    /// @notice Should refuse a spender holding no identity
    function test_transferFrom_RevertWhen_SpenderNotVerified() public {
        assertFalse(identityRegistry.isVerified(another));

        vm.prank(alice);
        token.approve(another, 100);

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, another, alice, bob, 100));
        token.transferFrom(alice, bob, 100);

        assertEq(token.allowance(alice, another), 100);
    }

    /// @notice Should stop refusing once the spender gets an identity
    function test_transferFrom_Success_AfterSpenderRegistered() public {
        vm.prank(alice);
        token.approve(charlie, 100);

        vm.prank(agent);
        identityRegistry.deleteIdentity(charlie);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, charlie, alice, bob, 100));
        token.transferFrom(alice, bob, 100);

        vm.prank(agent);
        identityRegistry.registerIdentity(charlie, charlieIdentity, Countries.SPAIN);

        vm.prank(charlie);
        token.transferFrom(alice, bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    /// @notice Should leave a direct transfer alone, even from a holder with no identity left
    function test_transfer_Success_WhenHolderNotVerified() public {
        vm.prank(agent);
        identityRegistry.deleteIdentity(alice);

        vm.prank(alice);
        token.transfer(bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    /// @notice Should leave the agent paths alone: they answer to roles, not to this module
    function test_agentPaths_Success_WhenModuleBound() public {
        vm.startPrank(agent);
        token.mint(alice, 100);
        token.burn(alice, 50);
        token.forcedTransfer(alice, bob, 100);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 100);
    }

    /// @notice Should re-open transferFrom to anyone once unbound
    function test_transferFrom_Success_AfterModuleUnbound() public {
        vm.prank(deployer);
        mc.removeModule(address(module));

        vm.prank(alice);
        token.approve(another, 100);

        vm.prank(another);
        token.transferFrom(alice, bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    // ============ Upgrade Tests ============

    /// @notice Should gate the implementation upgrade through the shared authority
    function test_upgradeToAndCall_RevertWhen_NotAuthorized() public {
        address newImplementation = address(new SpenderVerificationModule());

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        module.upgradeToAndCall(newImplementation, "");
    }

    /// @notice Should refuse a zero authority at initialization
    function test_initialize_RevertWhen_ZeroAuthority() public {
        SpenderVerificationModule implementation = new SpenderVerificationModule();

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new ModuleProxy(address(implementation), abi.encodeCall(SpenderVerificationModule.initialize, (address(0))));
    }

    function _deployModule() private returns (SpenderVerificationModule) {
        SpenderVerificationModule implementation = new SpenderVerificationModule();
        ModuleProxy proxy = new ModuleProxy(
            address(implementation), abi.encodeCall(SpenderVerificationModule.initialize, (address(accessManager)))
        );
        return SpenderVerificationModule(address(proxy));
    }

}
