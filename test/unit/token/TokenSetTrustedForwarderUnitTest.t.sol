// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenSetTrustedForwarderUnitTest is TokenBaseUnitTest {

    address newTrustedForwarder = makeAddr("NewTrustedForwarder");

    function testTokenSetTrustedForwarderRevertsWhenNotOwner(address caller) public {
        vm.assume(caller != token.owner());

        vm.expectPartialRevert(OwnableUpgradeable.OwnableUnauthorizedAccount.selector);
        vm.prank(caller);
        token.setTrustedForwarder(newTrustedForwarder);
    }

    function testTokenSetTrustedForwarderNominal() public {
        vm.expectEmit(true, true, true, true);
        emit EventsLib.TrustedForwarderSet(newTrustedForwarder);

        token.setTrustedForwarder(newTrustedForwarder);

        assertEq(token.trustedForwarder(), newTrustedForwarder);
    }

    function testTokenSetTrustedForwarderToZeroAddress() public {
        address zeroAddress = address(0);

        vm.expectEmit(true, true, true, true);
        emit EventsLib.TrustedForwarderSet(zeroAddress);

        token.setTrustedForwarder(zeroAddress);

        assertEq(token.trustedForwarder(), zeroAddress);
    }

    function testTokenTrustedForwarderInitialValue() public {
        // Initially should be zero address (set in constructor)
        assertEq(token.trustedForwarder(), address(0));
    }

}

