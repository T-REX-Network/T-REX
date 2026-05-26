// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract FreezeCheckTest is TREXSuiteTest {

    UtilityChecker public utilityChecker;

    function setUp() public override {
        super.setUp();

        IdentityRegistry identityRegistry = IdentityRegistry(address(token.identityRegistry()));

        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();

        // Deploy UtilityChecker via proxy
        UtilityChecker utilityCheckerImpl = new UtilityChecker();
        bytes memory utilityCheckerInitData = abi.encodeWithSelector(UtilityChecker.initialize.selector);
        UtilityCheckerProxy utilityCheckerProxy =
            new UtilityCheckerProxy(address(utilityCheckerImpl), utilityCheckerInitData);
        utilityChecker = UtilityChecker(address(utilityCheckerProxy));
    }

    // ============ getFreezeStatus() Tests ============

    /// @notice Should return true when sender is frozen
    function test_getFreezeStatus_ReturnsTrue_WhenSenderIsFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        (bool success, uint256 balance) = utilityChecker.getFreezeStatus(address(token), alice, bob, 100);
        assertTrue(success);
        assertEq(balance, 0);
    }

    /// @notice Should return true when recipient is frozen
    function test_getFreezeStatus_ReturnsTrue_WhenRecipientIsFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(bob, true);

        (bool success, uint256 balance) = utilityChecker.getFreezeStatus(address(token), alice, bob, 100);
        assertTrue(success);
        assertEq(balance, 0);
    }

    /// @notice Should return true when unfrozen balance is insufficient
    function test_getFreezeStatus_ReturnsTrue_WhenUnfrozenBalanceInsufficient() public {
        uint256 initialBalance = token.balanceOf(alice);
        vm.prank(agent);
        token.freezePartialTokens(alice, initialBalance - 10);

        (bool success, uint256 balance) = utilityChecker.getFreezeStatus(address(token), alice, bob, 100);
        assertTrue(success);
        assertEq(balance, 10);
    }

    /// @notice Should return false in normal case
    function test_getFreezeStatus_ReturnsFalse_WhenNormalCase() public {
        uint256 initialBalance = token.balanceOf(alice);

        (bool success, uint256 balance) = utilityChecker.getFreezeStatus(address(token), alice, bob, 100);
        assertFalse(success);
        assertEq(balance, initialBalance);
    }

}
