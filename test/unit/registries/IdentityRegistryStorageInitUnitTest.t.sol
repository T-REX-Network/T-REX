// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorageProxy } from "contracts/proxy/IdentityRegistryStorageProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";

import { AccessManagerHelper } from "../../helpers/AccessManagerHelper.sol";

contract IdentityRegistryStorageInitUnitTest is AccessManagerHelper {

    IdentityRegistryStorage private irsImplementation;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private owner = makeAddr("Owner");
    address private notOwner = makeAddr("NotOwner");

    function setUp() public {
        irsImplementation = new IdentityRegistryStorage();
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getIRSImplementation.selector),
            abi.encode(address(irsImplementation))
        );
    }

    function test_init_SetsOwnerToAccessManager() public {
        IdentityRegistryStorage irs = _deployProxy();

        assertEq(irs.owner(), address(accessManager));
        assertNotEq(irs.owner(), address(this));
    }

    function test_init_StartsWithNoLinkedRegistries() public {
        IdentityRegistryStorage irs = _deployProxy();

        address[] memory linked = irs.linkedIdentityRegistries();
        assertEq(linked.length, 0);
    }

    function test_init_OwnerCanBindIRAfterInit() public {
        IdentityRegistryStorage irs = _deployProxy();

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(irs));
        accessManager.grantRole(RolesLib.OWNER, owner, NO_DELAY);
        // lets the IRS grant AGENT to the IR it binds
        accessManager.grantRole(RolesLib.AGENT_MANAGER, address(irs), NO_DELAY);
        vm.stopPrank();

        address ir = makeAddr("ir");
        vm.prank(owner);
        irs.bindIdentityRegistry(ir);

        address[] memory linked = irs.linkedIdentityRegistries();
        assertEq(linked.length, 1);
        assertEq(linked[0], ir);
    }

    function test_bindIdentityRegistry_RevertWhen_NotOwner() public {
        IdentityRegistryStorage irs = _deployProxy();

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(irs));
        vm.stopPrank();

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, notOwner));
        irs.bindIdentityRegistry(makeAddr("ir"));
    }

    function test_init_RevertWhen_AccessManagerIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryStorageProxy(implementationAuthority, address(0));
    }

    function test_init_RevertWhen_AlreadyInitialized() public {
        IdentityRegistryStorage irs = _deployProxy();

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        irs.init(address(accessManager));
    }

    function _deployProxy() private returns (IdentityRegistryStorage) {
        return IdentityRegistryStorage(
            address(new IdentityRegistryStorageProxy(implementationAuthority, address(accessManager)))
        );
    }

}
