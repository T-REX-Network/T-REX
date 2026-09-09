// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenSetIdentityRegistryUnitTest is TokenBaseUnitTest {

    address newIdentityRegistry = makeAddr("NewIdentityRegistry");

    function setUp() public override {
        super.setUp();

        accessManager.grantRole(RolesLib.IDENTITY_MANAGER, address(this), 0);
    }

    function testTokenSetIdentityRegistryRevertsWhenUnauthorized(address caller) public {
        vm.assume(caller != address(this));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.setIdentityRegistry(newIdentityRegistry);
    }

    function testTokenSetIdentityRegistryRevertsWhenZeroAddress() public {
        // The onlySharedAuthority guard rejects the zero address before the in-body ZeroAddress check,
        // since address(0) cannot share the Token's authority.
        vm.expectRevert(ErrorsLib.AuthorityMismatch.selector);
        token.setIdentityRegistry(address(0));
    }

    /// @notice A target with no ERC-165 support is refused, so a mistyped address cannot halt the token.
    function testTokenSetIdentityRegistryRevertsWhenNoERC165() public {
        address notAContract = makeAddr("NotAContract");
        vm.mockCall(
            notAContract, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );

        vm.expectRevert(ErrorsLib.InvalidIdentityRegistry.selector);
        token.setIdentityRegistry(notAContract);

        assertEq(address(token.identityRegistry()), identityRegistry, "rejected registry must not be recorded");
    }

    /// @notice A contract that is not an identity registry is refused.
    function testTokenSetIdentityRegistryRevertsWhenWrongInterface() public {
        vm.mockCall(
            newIdentityRegistry,
            abi.encodeWithSelector(IAccessManaged.authority.selector),
            abi.encode(address(accessManager))
        );
        mockSupportsInterface(newIdentityRegistry, type(IERC3643Compliance).interfaceId);

        vm.expectRevert(ErrorsLib.InvalidIdentityRegistry.selector);
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), identityRegistry, "rejected registry must not be recorded");
    }

    function testTokenSetIdentityRegistryNominal() public {
        vm.mockCall(
            newIdentityRegistry,
            abi.encodeWithSelector(IAccessManaged.authority.selector),
            abi.encode(address(accessManager))
        );
        mockSupportsInterface(newIdentityRegistry, type(IERC3643IdentityRegistry).interfaceId);
        AccessManagerSetupLib.setupTREXRegistryRoles(accessManager, newIdentityRegistry);
        accessManager.grantRole(RolesLib.AGENT, address(token), 0);

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.IdentityRegistryAdded(newIdentityRegistry);
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), newIdentityRegistry);
    }

}
