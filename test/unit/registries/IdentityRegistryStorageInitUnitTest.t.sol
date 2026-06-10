// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { IdentityRegistryStorageProxy } from "contracts/proxy/IdentityRegistryStorageProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";

contract IdentityRegistryStorageInitUnitTest is Test {

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

    function test_init_SetsOwnerFromArgument_NotDeployer() public {
        IdentityRegistryStorage irs = _deployProxy(owner, address(0));

        assertEq(irs.owner(), owner);
        assertNotEq(irs.owner(), address(this));
    }

    function test_init_WithZeroInitialIR_DoesNotBindAnything() public {
        IdentityRegistryStorage storageContract = _deployProxy(owner, address(0));

        address[] memory linked = storageContract.linkedIdentityRegistries();
        assertEq(linked.length, 0);
    }

    function test_init_WithInitialIR_BindsAndGrantsAgentRole() public {
        address ir = makeAddr("ir");

        IdentityRegistryStorage storageContract = _deployProxy(owner, ir);

        address[] memory linked = storageContract.linkedIdentityRegistries();
        assertEq(linked.length, 1);
        assertEq(linked[0], ir);

        assertTrue(storageContract.isAgent(ir));
    }

    function test_init_OwnerCanStillBindAdditionalIRAfterInit() public {
        address ir1 = makeAddr("ir1");
        IdentityRegistryStorage storageContract = _deployProxy(owner, ir1);

        address ir2 = makeAddr("ir2");
        vm.prank(owner);
        storageContract.bindIdentityRegistry(ir2);

        assertTrue(storageContract.isAgent(ir2));
        address[] memory linked = storageContract.linkedIdentityRegistries();
        assertEq(linked.length, 2);
    }

    function test_bindIdentityRegistry_RevertWhen_NotOwner() public {
        IdentityRegistryStorage storageContract = _deployProxy(owner, address(0));

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        storageContract.bindIdentityRegistry(makeAddr("ir"));
    }

    function test_init_RevertWhen_OwnerIsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new IdentityRegistryStorageProxy(implementationAuthority, address(0), address(0));
    }

    function _deployProxy(address _owner, address _initialIR) private returns (IdentityRegistryStorage) {
        return IdentityRegistryStorage(
            address(new IdentityRegistryStorageProxy(implementationAuthority, _owner, _initialIR))
        );
    }

}
