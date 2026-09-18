// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { AccessManagerHelper } from "test/integration/helpers/AccessManagerHelper.sol";

contract TrustedGatewayRegistryUnitTest is AccessManagerHelper {

    TrustedGatewayRegistry registry;

    address interopManager = makeAddr("InteropManager");
    address gateway = makeAddr("Gateway");

    function setUp() public {
        _deployAccessManager();

        registry = new TrustedGatewayRegistry(address(accessManager));
        AccessManagerSetupLib.setupTrustedGatewayRegistryRoles(accessManager, address(registry));

        _grantInteropManagerRole(interopManager);
    }

    function testConstructorRevertsOnZeroAccessManager() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TrustedGatewayRegistry(address(0));
    }

    function testGatewayIsNotTrustedByDefault() public view {
        assertFalse(registry.isTrusted(gateway));
    }

    function testManagerTrustsGateway() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.TrustedGatewaySet(gateway, true);

        vm.prank(interopManager);
        registry.setTrustedGateway(gateway, true);

        assertTrue(registry.isTrusted(gateway));
    }

    function testManagerUntrustsGatewayInTheSameBlock() public {
        vm.startPrank(interopManager);
        registry.setTrustedGateway(gateway, true);

        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.TrustedGatewaySet(gateway, false);

        registry.setTrustedGateway(gateway, false);
        vm.stopPrank();

        assertFalse(registry.isTrusted(gateway));
    }

    function testRedundantWriteKeepsStateAndStillEmits() public {
        vm.startPrank(interopManager);
        registry.setTrustedGateway(gateway, true);

        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.TrustedGatewaySet(gateway, true);

        registry.setTrustedGateway(gateway, true);
        vm.stopPrank();

        assertTrue(registry.isTrusted(gateway));
    }

    function testSetTrustedGatewayRevertsWhenNotInteropManager(address caller) public {
        vm.assume(caller != interopManager);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        registry.setTrustedGateway(gateway, true);
    }

    /// @dev The registry is network-level: no suite role reaches it, only INTEROP_MANAGER.
    function testSetTrustedGatewayRevertsForAnotherSuiteRole() public {
        address owner = makeAddr("Owner");
        _grantOwnerRole(owner);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        registry.setTrustedGateway(gateway, true);
    }

    function testSetTrustedGatewayRevertsOnZeroGateway() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(interopManager);
        registry.setTrustedGateway(address(0), true);
    }

    function testInteropManagerRoleIdIsUnique() public pure {
        assertTrue(RolesLib.INTEROP_MANAGER != RolesLib.VERSION_MANAGER);
        assertTrue(RolesLib.INTEROP_MANAGER != RolesLib.ASSET_DEPLOYER);
        assertTrue(RolesLib.INTEROP_MANAGER != RolesLib.IRS_BINDER);
        assertTrue(RolesLib.INTEROP_MANAGER != RolesLib.OWNER);
        assertTrue(RolesLib.INTEROP_MANAGER != RolesLib.SUITE_ADMIN);
        assertTrue(RolesLib.INTEROP_MANAGER != RolesLib.AGENT_ADMIN);
    }

}
