// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { IdentityRegistryProxy } from "contracts/proxy/IdentityRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";

contract IdentityRegistryInitUnitTest is Test {

    IdentityRegistry private irImplementation;
    AccessManager private accessManager;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private tir = makeAddr("TrustedIssuersRegistry");
    address private ctr = makeAddr("ClaimTopicsRegistry");
    address private irs = makeAddr("IdentityRegistryStorage");

    function setUp() public {
        irImplementation = new IdentityRegistry();
        accessManager = new AccessManager(address(this));
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getIRImplementation.selector),
            abi.encode(address(irImplementation))
        );
    }

    function test_init_SetsAccessManagerFromArgument_NotDeployer() public {
        IdentityRegistry ir = _deployProxy();

        assertEq(IAccessManaged(address(ir)).authority(), address(accessManager));
        assertNotEq(IAccessManaged(address(ir)).authority(), address(this));
    }

    function test_init_SetsDependencies() public {
        IdentityRegistry ir = _deployProxy();

        assertEq(address(ir.issuersRegistry()), tir);
        assertEq(address(ir.topicsRegistry()), ctr);
        assertEq(address(ir.identityStorage()), irs);
    }

    function test_init_RevertWhen_AccessManagerIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, address(0));
    }

    function test_init_RevertWhen_TIRIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new IdentityRegistryProxy(implementationAuthority, address(0), ctr, irs, address(accessManager));
    }

    function test_init_RevertWhen_CTRIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, address(0), irs, address(accessManager));
    }

    function test_init_RevertWhen_IRSIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, ctr, address(0), address(accessManager));
    }

    function _deployProxy() private returns (IdentityRegistry) {
        return IdentityRegistry(
            address(new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, address(accessManager)))
        );
    }

}
