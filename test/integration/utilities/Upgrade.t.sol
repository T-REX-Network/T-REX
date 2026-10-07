// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract UpgradeTest is TREXSuiteTest {

    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _deployChecker() private returns (UtilityChecker) {
        UtilityChecker implementation = new UtilityChecker();
        bytes memory initData = abi.encodeCall(UtilityChecker.initialize, (address(accessManager)));
        return UtilityChecker(address(new UtilityCheckerProxy(address(implementation), initData)));
    }

    function test_initialize_RevertWhen_AccessManagerIsZero() public {
        UtilityChecker implementation = new UtilityChecker();
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new UtilityCheckerProxy(address(implementation), abi.encodeCall(UtilityChecker.initialize, (address(0))));
    }

    /// @notice The upgrade is gated by the AccessManager, not by a single owner: an unmapped selector
    ///         resolves to ADMIN_ROLE, which the manager admin holds and alice does not.
    function test_upgradeToAndCall_RevertWhen_NotAuthorized() public {
        UtilityChecker utilityChecker = _deployChecker();
        UtilityChecker newImplementation = new UtilityChecker();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        utilityChecker.upgradeToAndCall(address(newImplementation), "");
    }

    function test_upgradeToAndCall_Success() public {
        UtilityChecker utilityChecker = _deployChecker();
        assertEq(utilityChecker.owner(), address(accessManager), "owner() reports the authority");
        UtilityChecker newImplementation = new UtilityChecker();

        // The test contract is the manager admin (see AccessManagerHelper).
        utilityChecker.upgradeToAndCall(address(newImplementation), "");

        address actualImplementation = address(uint160(uint256(vm.load(address(utilityChecker), IMPLEMENTATION_SLOT))));
        assertEq(actualImplementation, address(newImplementation));
    }

}
