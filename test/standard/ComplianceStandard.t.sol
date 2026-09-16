// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";

import { ComplianceMock } from "./mocks/StandardMocks.sol";

/// @dev ERC-3643 standard: Compliance.
///
///  Runs against the standard base alone (issue #65), so this file must pass unchanged when
///  OpenZeppelin's base replaces ours. A compliance with no rules is compliant, which is what the
///  `canTransfer` assertions below pin down.
contract ComplianceStandardTest is Test {

    ComplianceMock internal compliance;

    address internal token = makeAddr("token");
    address internal otherToken = makeAddr("otherToken");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        compliance = new ComplianceMock();
    }

    function test_getTokenBound_IsZeroInitially() public view {
        assertEq(compliance.getTokenBound(), address(0));
        assertFalse(compliance.isTokenBound(token));
    }

    function test_bindToken_RecordsTheToken() public {
        compliance.bindToken(token);

        assertEq(compliance.getTokenBound(), token);
        assertTrue(compliance.isTokenBound(token));
        assertFalse(compliance.isTokenBound(otherToken));
    }

    function test_bindToken_EmitsTokenBound() public {
        vm.expectEmit(false, false, false, true, address(compliance));
        emit IERC3643Compliance.TokenBound(token);

        compliance.bindToken(token);
    }

    function test_bindToken_RevertWhen_ZeroAddress() public {
        vm.expectRevert(ERC3643ErrorsLib.ZeroAddress.selector);
        compliance.bindToken(address(0));
    }

    function test_unbindToken_ClearsTheToken() public {
        compliance.bindToken(token);

        compliance.unbindToken(token);

        assertEq(compliance.getTokenBound(), address(0));
        assertFalse(compliance.isTokenBound(token));
    }

    function test_unbindToken_EmitsTokenUnbound() public {
        compliance.bindToken(token);

        vm.expectEmit(false, false, false, true, address(compliance));
        emit IERC3643Compliance.TokenUnbound(token);

        compliance.unbindToken(token);
    }

    function test_unbindToken_RevertWhen_NotTheBoundToken() public {
        compliance.bindToken(token);

        vm.expectRevert(ERC3643ErrorsLib.TokenNotBound.selector);
        compliance.unbindToken(otherToken);
    }

    /// @dev A compliance carrying no rules permits every transfer.
    function test_canTransfer_IsTrueWithNoRules() public view {
        assertTrue(compliance.canTransfer(alice, bob, 1));
    }

    function test_transferred_OnlyBoundTokenMayCall() public {
        compliance.bindToken(token);

        vm.prank(token);
        compliance.transferred(alice, bob, 1);

        vm.prank(alice);
        vm.expectRevert(ERC3643ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        compliance.transferred(alice, bob, 1);
    }

    function test_created_OnlyBoundTokenMayCall() public {
        compliance.bindToken(token);

        vm.prank(token);
        compliance.created(alice, 1);

        vm.prank(alice);
        vm.expectRevert(ERC3643ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        compliance.created(alice, 1);
    }

    function test_destroyed_OnlyBoundTokenMayCall() public {
        compliance.bindToken(token);

        vm.prank(token);
        compliance.destroyed(alice, 1);

        vm.prank(alice);
        vm.expectRevert(ERC3643ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        compliance.destroyed(alice, 1);
    }

    function test_transferred_RevertWhen_ZeroAddress() public {
        compliance.bindToken(token);

        vm.prank(token);
        vm.expectRevert(ERC3643ErrorsLib.ZeroAddress.selector);
        compliance.transferred(address(0), bob, 1);
    }

    function test_transferred_RevertWhen_ZeroValue() public {
        compliance.bindToken(token);

        vm.prank(token);
        vm.expectRevert(ERC3643ErrorsLib.ZeroValue.selector);
        compliance.transferred(alice, bob, 0);
    }

}
