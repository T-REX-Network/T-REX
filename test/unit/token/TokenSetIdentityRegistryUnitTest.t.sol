// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenSetIdentityRegistryUnitTest is TokenBaseUnitTest {

    address newIdentityRegistry = makeAddr("NewIdentityRegistry");

    function testTokenSetIdentityRegistryRevertsWhenNotOwner(address caller) public {
        vm.assume(caller != address(this));

        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
        vm.prank(caller);
        token.setIdentityRegistry(newIdentityRegistry);
    }

    /// @dev Pins the `_identityRegistry != address(0)` guard (Token.sol:213) — covers the revert branch and
    ///      kills the zero-check mutants (DeleteExpression / Require → true).
    function testTokenSetIdentityRegistryRevertsWhenZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        token.setIdentityRegistry(address(0));
    }

    function testTokenSetIdentityRegistryNominal() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.IdentityRegistryAdded(newIdentityRegistry);
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), newIdentityRegistry);
    }

}
