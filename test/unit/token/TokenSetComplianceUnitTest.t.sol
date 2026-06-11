// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenSetComplianceUnitTest is TokenBaseUnitTest {

    address newCompliance = makeAddr("NewComplianceMock");

    constructor() {
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.unbindToken.selector, address(token)), "");
        vm.mockCall(newCompliance, abi.encodeWithSelector(IERC3643Compliance.bindToken.selector, address(token)), "");
    }

    function setUp() public override {
        super.setUp();

        accessManager.grantRole(RolesLib.IDENTITY_MANAGER, address(this), 0);
    }

    function testTokenSetComplianceRevertsWhenUnauthorized(address caller) public {
        vm.assume(caller != address(this));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.setCompliance(makeAddr("NewCompliance"));
    }

    function testTokenSetComplianceRevertsWhenCallerOnlyTokenAdmin() public {
        address tokenAdmin = makeAddr("TokenAdmin");
        accessManager.grantRole(RolesLib.TOKEN_MANAGER, tokenAdmin, 0);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, tokenAdmin));
        vm.prank(tokenAdmin);
        token.setCompliance(makeAddr("NewCompliance"));
    }

    function testTokenSetComplianceRevertsWhenZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        token.setCompliance(address(0));
    }

    function testTokenSetComplianceNominal() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.ComplianceAdded(newCompliance);
        token.setCompliance(newCompliance);

        assertEq(address(token.compliance()), newCompliance);
    }

    function testTokenSetComplianceUnbindsPreviousCompliance() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.ComplianceAdded(newCompliance);
        token.setCompliance(newCompliance);
    }

}
