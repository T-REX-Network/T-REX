// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { ModularComplianceProxy } from "contracts/proxy/ModularComplianceProxy.sol";
import { TREXImplementationAuthority } from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { IProxy } from "contracts/proxy/interface/IProxy.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";

contract AbstractProxyTest is TREXSuiteTest {

    IProxy public proxy;

    function setUp() public override {
        super.setUp();
        // Deploy ModularComplianceProxy (which inherits from AbstractProxy)
        proxy =
            IProxy(address(new ModularComplianceProxy(address(trexImplementationAuthority), address(accessManager))));
    }

    // ============ setImplementationAuthority() Tests ============

    /// @notice Should revert when called by non-implementation authority
    function test_setImplementationAuthority_RevertWhen_NotImplementationAuthority() public {
        address randomAddress = makeAddr("random");
        TREXImplementationAuthority newIA = _deployTREXImplementationAuthority(true);

        vm.prank(randomAddress);
        vm.expectRevert(ErrorsLib.OnlyCurrentImplementationAuthorityCanCall.selector);
        proxy.setImplementationAuthority(address(newIA));
    }

    /// @notice Should revert when new implementation authority is zero address
    function test_setImplementationAuthority_RevertWhen_ZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(address(trexImplementationAuthority));
        proxy.setImplementationAuthority(address(0));
    }

    /// @notice Should revert when new implementation authority is incomplete
    function test_setImplementationAuthority_RevertWhen_IncompleteIA() public {
        // Deploy an incomplete IA (no implementations set)
        TREXImplementationAuthority incompleteIA =
            new TREXImplementationAuthority(false, address(0), address(0), address(accessManager));

        vm.prank(address(trexImplementationAuthority));
        vm.expectRevert(ErrorsLib.InvalidImplementationAuthority.selector);
        proxy.setImplementationAuthority(address(incompleteIA));
    }

    /// @notice Should succeed when called by implementation authority with complete IA
    function test_setImplementationAuthority_Success() public {
        TREXImplementationAuthority newIA = _deployTREXImplementationAuthority(true);

        vm.prank(address(trexImplementationAuthority));
        vm.expectEmit(true, false, false, false);
        emit EventsLib.ImplementationAuthoritySet(address(newIA));
        proxy.setImplementationAuthority(address(newIA));

        assertEq(proxy.getImplementationAuthority(), address(newIA), "IA should be updated");
    }

}
