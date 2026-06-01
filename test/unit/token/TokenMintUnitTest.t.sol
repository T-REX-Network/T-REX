// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenMintUnitTest is TokenBaseUnitTest {

    uint256 mintAmount = 1000;

    function setUp() public override {
        super.setUp();

        vm.prank(agent);
        token.unpause();
    }

    function testTokenMintRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
        vm.prank(caller);
        token.mint(user1, mintAmount);
    }

    function testTokenMintRevertsWhenUserNotVerified() public {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector, user1),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        vm.prank(agent);
        token.mint(user1, mintAmount);
    }

    function testTokenMintRevertsWhenComplianceNotFollowed() public {
        vm.mockCall(
            compliance,
            abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector, address(0), user1, mintAmount),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
        vm.prank(agent);
        token.mint(user1, mintAmount);
    }

    function testTokenMintNominal() public {
        // The post-mint compliance hook must fire (Token._update: compliance.created(to, value)).
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.created.selector, user1, mintAmount));

        vm.prank(agent);
        token.mint(user1, mintAmount);

        assertEq(token.balanceOf(user1), mintAmount);
        assertEq(token.totalSupply(), mintAmount);
    }

    function testTokenMintRevertsWhenDisableMintRestrictionIsSet() public {
        vm.prank(accessManagerAdmin);
        accessManager.revokeRole(RolesLib.AGENT_MINTER, agent);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        vm.prank(agent);
        token.mint(user1, mintAmount);
    }

}

