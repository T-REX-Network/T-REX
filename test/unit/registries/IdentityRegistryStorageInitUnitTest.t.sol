// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";

import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

contract IdentityRegistryStorageInitUnitTest is Test {

    IdentityRegistryStorage private irsImplementation;
    AccessManager private accessManager;
    address private irsBeacon;

    address private notOwner = makeAddr("NotOwner");

    address private idFactory = makeAddr("IdFactoryMock");

    function setUp() public {
        irsImplementation = new IdentityRegistryStorage();
        accessManager = new AccessManager(address(this));
        accessManager.grantRole(RolesLib.OWNER, address(this), 0);
        // bindIdentityRegistry is gated by IRS_BINDER (not OWNER); the test acts as the binder here.
        accessManager.grantRole(RolesLib.IRS_BINDER, address(this), 0);
        irsBeacon = BeaconProxyDeployer.newBeacon(address(irsImplementation));
    }

    function test_init_SetsAccessManagerFromArgument_NotDeployer() public {
        IdentityRegistryStorage irs = _deployProxy(address(0));

        assertEq(IAccessManaged(address(irs)).authority(), address(accessManager));
        assertNotEq(IAccessManaged(address(irs)).authority(), address(this));
    }

    function test_init_WithZeroInitialIR_DoesNotBindAnything() public {
        IdentityRegistryStorage storageContract = _deployProxy(address(0));

        address[] memory linked = storageContract.linkedIdentityRegistries();
        assertEq(linked.length, 0);
    }

    function test_init_WithInitialIR_BindsInitialIR_WithoutGrantingAgentRole() public {
        address ir = makeAddr("ir");

        IdentityRegistryStorage storageContract = _deployProxy(ir);

        address[] memory linked = storageContract.linkedIdentityRegistries();
        assertEq(linked.length, 1);
        assertEq(linked[0], ir);
        assertFalse(_hasAgentRole(ir));
    }

    function test_init_BinderCanStillBindAdditionalIRAfterInit() public {
        address ir1 = makeAddr("ir1");
        IdentityRegistryStorage storageContract = _deployProxy(ir1);

        address ir2 = makeAddr("ir2");
        // The external bindIdentityRegistry is gated by onlySharedAuthority: ir2 must report the storage's
        // AccessManager as its authority.
        vm.mockCall(ir2, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager)));
        storageContract.bindIdentityRegistry(ir2);

        address[] memory linked = storageContract.linkedIdentityRegistries();
        assertEq(linked.length, 2);
        assertFalse(_hasAgentRole(ir2));
    }

    function test_bindIdentityRegistry_AdminGrantsAgentRoleExplicitly() public {
        IdentityRegistryStorage storageContract = _deployProxy(address(0));

        address ir = makeAddr("ir");
        // The external bindIdentityRegistry is gated by onlySharedAuthority: ir must report the storage's
        // AccessManager as its authority.
        vm.mockCall(ir, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager)));
        storageContract.bindIdentityRegistry(ir);
        accessManager.grantRole(RolesLib.AGENT, ir, 0);

        assertTrue(_hasAgentRole(ir));
    }

    function test_bindIdentityRegistry_RevertWhen_NotBinder() public {
        IdentityRegistryStorage storageContract = _deployProxy(address(0));

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, notOwner));
        storageContract.bindIdentityRegistry(makeAddr("ir"));
    }

    function test_init_RevertWhen_AccessManagerIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        BeaconProxyDeployer.newProxy(
            irsBeacon, abi.encodeCall(IdentityRegistryStorage.init, (address(0), address(0), idFactory))
        );
    }

    function test_init_RevertWhen_IdFactoryIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        BeaconProxyDeployer.newProxy(
            irsBeacon, abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0), address(0)))
        );
    }

    function _deployProxy(address _initialIR) private returns (IdentityRegistryStorage) {
        IdentityRegistryStorage irs = IdentityRegistryStorage(
            BeaconProxyDeployer.newProxy(
                irsBeacon, abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), _initialIR, idFactory))
            )
        );
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(irs));
        return irs;
    }

    function _hasAgentRole(address account) private view returns (bool) {
        (bool isMember,) = accessManager.hasRole(RolesLib.AGENT, account);
        return isMember;
    }

}
