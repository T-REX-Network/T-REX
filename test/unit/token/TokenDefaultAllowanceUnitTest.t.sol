// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenDefaultAllowanceUnitTest is TokenBaseUnitTest {

    address spender1 = makeAddr("Spender1");
    address spender2 = makeAddr("Spender2");

    function testTokenSetAllowanceForAllRevertsWhenNotOwner(address caller) public {
        vm.assume(caller != token.owner());

        address[] memory targets = new address[](1);
        targets[0] = spender1;

        vm.expectPartialRevert(OwnableUpgradeable.OwnableUnauthorizedAccount.selector);
        vm.prank(caller);
        token.setAllowanceForAll(targets, true);
    }

    function testTokenSetAllowanceForAllRevertsWhenArrayTooLarge() public {
        address[] memory targets = new address[](101);
        for (uint256 i = 0; i < 101; i++) {
            targets[i] = makeAddr(string(abi.encodePacked("Spender", i)));
        }

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ArraySizeLimited.selector, 100));
        token.setAllowanceForAll(targets, true);
    }

    function testTokenSetAllowanceForAllRevertsWhenAlreadySet() public {
        address[] memory targets = new address[](1);
        targets[0] = spender1;

        // Set allowance first
        token.setAllowanceForAll(targets, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DefaultAllowanceAlreadySet.selector, spender1, true));
        token.setAllowanceForAll(targets, true);
    }

    function testTokenSetAllowanceForAllNominal() public {
        address[] memory targets = new address[](2);
        targets[0] = spender1;
        targets[1] = spender2;

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.DefaultAllowanceUpdated(spender1, true, token.owner());

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.DefaultAllowanceUpdated(spender2, true, token.owner());

        token.setAllowanceForAll(targets, true);

        assertEq(token.allowance(user1, spender1), type(uint256).max);
        assertEq(token.allowance(user1, spender2), type(uint256).max);
    }

    function testTokenSetAllowanceForAllToFalse() public {
        address[] memory targets = new address[](1);
        targets[0] = spender1;

        token.setAllowanceForAll(targets, true);

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.DefaultAllowanceUpdated(spender1, false, token.owner());

        token.setAllowanceForAll(targets, false);

        assertEq(token.allowance(user1, spender1), 0);
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

