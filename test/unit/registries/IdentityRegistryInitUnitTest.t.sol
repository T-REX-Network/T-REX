// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryProxy } from "contracts/proxy/IdentityRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";

import { AccessManagerHelper } from "../../helpers/AccessManagerHelper.sol";

contract IdentityRegistryInitUnitTest is AccessManagerHelper {

    IdentityRegistry private irImplementation;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private owner = makeAddr("Owner");
    address private notOwner = makeAddr("NotOwner");

    address private tir = makeAddr("TrustedIssuersRegistry");
    address private ctr = makeAddr("ClaimTopicsRegistry");
    address private irs = makeAddr("IdentityRegistryStorage");

    function setUp() public {
        irImplementation = new IdentityRegistry();
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getIRImplementation.selector),
            abi.encode(address(irImplementation))
        );
    }

    function test_init_SetsOwnerToAccessManager() public {
        IdentityRegistry ir = _deployProxy();

        assertEq(ir.owner(), address(accessManager));
        assertNotEq(ir.owner(), address(this));
    }

    function test_init_SetsDependencies() public {
        IdentityRegistry ir = _deployProxy();

        assertEq(address(ir.issuersRegistry()), tir);
        assertEq(address(ir.topicsRegistry()), ctr);
        assertEq(address(ir.identityStorage()), irs);
    }

    function test_init_RevertWhen_TIRIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, address(0), ctr, irs, address(accessManager));
    }

    function test_init_RevertWhen_CTRIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, address(0), irs, address(accessManager));
    }

    function test_init_RevertWhen_IRSIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, ctr, address(0), address(accessManager));
    }

    function test_init_RevertWhen_AlreadyInitialized() public {
        IdentityRegistry ir = _deployProxy();

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        ir.init(tir, ctr, irs, address(accessManager));
    }

    function _deployProxy() private returns (IdentityRegistry) {
        return IdentityRegistry(
            address(new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, address(accessManager)))
        );
    }

}
