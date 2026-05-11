// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenSetDefaultAllowanceUnitTest is TokenBaseUnitTest {

    address spender1 = makeAddr("Spender1");
    address spender2 = makeAddr("Spender2");

    function setUp() public override {
        super.setUp();

        _mockIdentity(spender1, makeAddr("Spender1Identity"));
        _mockIdentity(spender2, makeAddr("Spender2Identity"));
    }

    function testTokenSetDefaultAllowanceRevertsWhenAlreadySet() public {
        vm.prank(user1);
        token.setDefaultAllowance(false);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DefaultAllowanceOptOutAlreadySet.selector, user1, false));
        vm.prank(user1);
        token.setDefaultAllowance(false);
    }

    function testTokenSetDefaultAllowanceNominal() public {
        address[] memory targets = new address[](1);
        targets[0] = spender1;
        token.setAllowanceForAll(targets, true);

        // User should have max allowance by default
        assertEq(token.allowance(user1, spender1), type(uint256).max);

        // User opts out
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.DefaultAllowanceOptOutUpdated(user1, true);
        vm.prank(user1);
        token.setDefaultAllowance(false);

        // Now user should have 0 allowance (opted out)
        assertEq(token.allowance(user1, spender1), 0);
    }

    function testTokenSetDefaultAllowanceOptOutToFalse() public {
        // Set default allowance for spender
        address[] memory targets = new address[](1);
        targets[0] = spender1;
        token.setAllowanceForAll(targets, true);

        // User opts out
        vm.prank(user1);
        token.setDefaultAllowance(false);

        // User opts back in
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.DefaultAllowanceOptOutUpdated(user1, false);
        vm.prank(user1);
        token.setDefaultAllowance(true);

        // Now user should have max allowance again
        assertEq(token.allowance(user1, spender1), type(uint256).max);
    }

    function testTokenAllowanceWithDefaultAllowance() public {
        // Set default allowance for spender
        address[] memory targets = new address[](1);
        targets[0] = spender1;
        token.setAllowanceForAll(targets, true);

        // User should have max allowance
        assertEq(token.allowance(user1, spender1), type(uint256).max);

        // User opts out
        vm.prank(user1);
        token.setDefaultAllowance(false);

        // User should have 0 allowance
        assertEq(token.allowance(user1, spender1), 0);

        // User manually approves
        vm.prank(user1);
        token.approve(spender1, 1000);

        // User should have 1000 allowance (manual approval overrides opt-out)
        assertEq(token.allowance(user1, spender1), 1000);
    }

    function testTokenAllowanceWithoutDefaultAllowance() public {
        // No default allowance set, should return 0
        assertEq(token.allowance(user1, spender1), 0);

        // User manually approves
        vm.prank(user1);
        token.approve(spender1, 1000);

        // User should have 1000 allowance
        assertEq(token.allowance(user1, spender1), 1000);
    }

}

