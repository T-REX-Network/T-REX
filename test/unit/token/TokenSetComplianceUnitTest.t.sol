// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenSetComplianceUnitTest is TokenBaseUnitTest {

    address newCompliance = makeAddr("NewComplianceMock");

    constructor() {
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.unbindToken.selector, address(token)), "");
        vm.mockCall(newCompliance, abi.encodeWithSelector(IERC3643Compliance.bindToken.selector, address(token)), "");
    }

    function testTokenSetComplianceRevertsWhenNotOwner(address caller) public {
        vm.assume(caller != address(this));

        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
        vm.prank(caller);
        token.setCompliance(makeAddr("NewCompliance"));
    }

    function testTokenSetComplianceNominal() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.ComplianceAdded(newCompliance);
        token.setCompliance(newCompliance);

        assertEq(address(token.compliance()), newCompliance);
    }

    /// @dev When a compliance is already bound, setting a new one must unbind the old and bind the new.
    ///      `expectCall` pins both external calls (Token.sol:225-229) so deleting either is caught.
    function testTokenSetComplianceUnbindsPreviousCompliance() public {
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.unbindToken.selector, address(token)));
        vm.expectCall(newCompliance, abi.encodeWithSelector(IERC3643Compliance.bindToken.selector, address(token)));

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.ComplianceAdded(newCompliance);
        token.setCompliance(newCompliance);
    }

    /// @dev Pins the `_compliance != address(0)` guard (Token.sol:221) — covers the revert branch and kills the
    ///      zero-check mutants.
    function testTokenSetComplianceRevertsWhenZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        token.setCompliance(address(0));
    }

}
