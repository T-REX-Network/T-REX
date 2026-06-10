// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenSetIdentityRegistryUnitTest is TokenBaseUnitTest {

    address newIdentityRegistry = makeAddr("NewIdentityRegistry");

    function testTokenSetIdentityRegistryRevertsWhenNotOwner(address caller) public {
        vm.assume(caller != token.owner());

        vm.expectPartialRevert(OwnableUpgradeable.OwnableUnauthorizedAccount.selector);
        vm.prank(caller);
        token.setIdentityRegistry(newIdentityRegistry);
    }

    function testTokenSetIdentityRegistryNominal() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.IdentityRegistryAdded(newIdentityRegistry);
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), newIdentityRegistry);
    }

}
