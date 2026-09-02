// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { SpenderWhitelistModule } from "contracts/compliance/modular/modules/SpenderWhitelistModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { ModuleCapabilitiesLib } from "contracts/libraries/ModuleCapabilitiesLib.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @dev Default closed: the module allows nobody until the issuer names an operator, and forgets
///      the list on unbind.
contract SpenderWhitelistModuleTest is TREXSuiteTest {

    ModularCompliance internal mc;
    SpenderWhitelistModule internal module;

    function setUp() public override {
        super.setUp();

        mc = ModularCompliance(address(token.compliance()));

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
        assertTrue(module.isPlugAndPlay());
        assertEq(module.name(), "SpenderWhitelistModule");
    }

    // ============ Enforcement Tests ============

    /// @notice Should block every spender while the allowlist is empty
    function test_transferFrom_RevertWhen_AllowlistEmpty() public {
        assertFalse(module.isSpenderAllowed(address(mc), charlie));

        vm.prank(alice);
        token.approve(charlie, 100);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, charlie, alice, bob, 100));
        token.transferFrom(alice, bob, 100);
    }

    /// @notice Should let a listed spender through
    function test_transferFrom_Success_WhenSpenderAllowed() public {
        vm.expectEmit(true, true, false, false, address(module));
        emit SpenderWhitelistModule.SpenderAllowed(address(mc), charlie);
        _allow(charlie);

        assertTrue(module.isSpenderAllowed(address(mc), charlie));

        vm.prank(alice);
        token.approve(charlie, 100);

        vm.prank(charlie);
        token.transferFrom(alice, bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    /// @notice Should block again once delisted
    function test_transferFrom_RevertWhen_SpenderDisallowed() public {
        _allow(charlie);

        vm.expectEmit(true, true, false, false, address(module));
        emit SpenderWhitelistModule.SpenderDisallowed(address(mc), charlie);
        _disallow(charlie);

        vm.prank(alice);
        token.approve(charlie, 100);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, charlie, alice, bob, 100));
        token.transferFrom(alice, bob, 100);
    }

    /// @notice Should leave a direct transfer alone: there is no spender to vet
    function test_transfer_Success_WhenAllowlistEmpty() public {
        vm.prank(alice);
        token.transfer(bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    /// @notice Should leave the agent paths alone: they answer to roles, not to this module
    function test_agentPaths_Success_WhenAllowlistEmpty() public {
        vm.startPrank(agent);
        token.mint(alice, 100);
        token.burn(alice, 50);
        token.forcedTransfer(alice, bob, 100);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 100);
    }

    // ============ Allowlist Administration Tests ============

    /// @notice Should list a spender and announce it
    function test_allowSpender_Success_ListsAndEmits() public {
        vm.expectEmit(true, true, false, false, address(module));
        emit SpenderWhitelistModule.SpenderAllowed(address(mc), charlie);
        _allow(charlie);

        assertTrue(module.isSpenderAllowed(address(mc), charlie));
    }

    /// @notice Should delist a spender and announce it
    function test_disallowSpender_Success_DelistsAndEmits() public {
        _allow(charlie);

        vm.expectEmit(true, true, false, false, address(module));
        emit SpenderWhitelistModule.SpenderDisallowed(address(mc), charlie);
        _disallow(charlie);

        assertFalse(module.isSpenderAllowed(address(mc), charlie));
    }

    /// @notice Should refuse to list a spender that is already on the allowlist
    function test_allowSpender_RevertWhen_AlreadyAllowed() public {
        _allow(charlie);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderAlreadyAllowed.selector, charlie));
        mc.callModuleFunction(abi.encodeCall(SpenderWhitelistModule.allowSpender, (charlie)), address(module));
    }

    /// @notice Should refuse to delist a spender that was never listed
    function test_disallowSpender_RevertWhen_NotListed() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotListed.selector, charlie));
        mc.callModuleFunction(abi.encodeCall(SpenderWhitelistModule.disallowSpender, (charlie)), address(module));
    }

    /// @notice Should refuse the zero address
    function test_allowSpender_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        mc.callModuleFunction(abi.encodeCall(SpenderWhitelistModule.allowSpender, (address(0))), address(module));
    }

    /// @notice Should reach the allowlist only through the bound compliance
    function test_allowSpender_RevertWhen_CalledDirectly() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        module.allowSpender(charlie);
    }

    // ============ Lifecycle Tests ============

    /// @notice Should forget the allowlist across an unbind and rebind
    function test_isSpenderAllowed_Success_ForgetsListAfterRebind() public {
        _allow(charlie);
        assertTrue(module.isSpenderAllowed(address(mc), charlie));

        vm.startPrank(deployer);
        mc.removeModule(address(module));
        mc.addModule(address(module));
        vm.stopPrank();

        assertFalse(module.isSpenderAllowed(address(mc), charlie));

        vm.prank(alice);
        token.approve(charlie, 100);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, charlie, alice, bob, 100));
        token.transferFrom(alice, bob, 100);
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
        address newImplementation = address(new SpenderWhitelistModule());

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        module.upgradeToAndCall(newImplementation, "");
    }

    /// @notice Should refuse a zero authority at initialization
    function test_initialize_RevertWhen_ZeroAuthority() public {
        SpenderWhitelistModule implementation = new SpenderWhitelistModule();

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new ModuleProxy(address(implementation), abi.encodeCall(SpenderWhitelistModule.initialize, (address(0))));
    }

    function _allow(address spender) private {
        vm.prank(deployer);
        mc.callModuleFunction(abi.encodeCall(SpenderWhitelistModule.allowSpender, (spender)), address(module));
    }

    function _disallow(address spender) private {
        vm.prank(deployer);
        mc.callModuleFunction(abi.encodeCall(SpenderWhitelistModule.disallowSpender, (spender)), address(module));
    }

    function _deployModule() private returns (SpenderWhitelistModule) {
        SpenderWhitelistModule implementation = new SpenderWhitelistModule();
        ModuleProxy proxy = new ModuleProxy(
            address(implementation), abi.encodeCall(SpenderWhitelistModule.initialize, (address(accessManager)))
        );
        return SpenderWhitelistModule(address(proxy));
    }

}
