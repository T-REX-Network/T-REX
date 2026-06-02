// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TREXSuiteTest } from "../integration/helpers/TREXSuiteTest.sol";

/// @title Negative authorization fuzzing
/// @notice For every restricted entry point, a caller that does not hold the required role must revert with
///         AccessManagedUnauthorized. This guards the AccessManager wiring against accidental opening up.
contract AuthFuzzTest is TREXSuiteTest {

    function _assumeNoRole(address caller, uint64 role) internal view {
        (bool has,) = accessManager.hasRole(role, caller);
        vm.assume(!has);
        // role 0 (admin) can call anything via the manager; exclude it too.
        (bool isAdmin,) = accessManager.hasRole(0, caller);
        vm.assume(!isAdmin);
        vm.assume(caller != address(0));
    }

    function testFuzz_mintUnauthorized(address caller, address to, uint256 amount) public {
        _assumeNoRole(caller, RolesLib.AGENT_MINTER);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        token.mint(to, amount);
    }

    function testFuzz_burnUnauthorized(address caller, address from, uint256 amount) public {
        _assumeNoRole(caller, RolesLib.AGENT_BURNER);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        token.burn(from, amount);
    }

    function testFuzz_forcedTransferUnauthorized(address caller, address from, address to, uint256 amount) public {
        _assumeNoRole(caller, RolesLib.AGENT_FORCED_TRANSFER);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        token.forcedTransfer(from, to, amount);
    }

    function testFuzz_pauseUnauthorized(address caller) public {
        _assumeNoRole(caller, RolesLib.AGENT_PAUSER);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        token.pause();
    }

    function testFuzz_freezePartialUnauthorized(address caller, address user, uint256 amount) public {
        _assumeNoRole(caller, RolesLib.AGENT_PARTIAL_FREEZER);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        token.freezePartialTokens(user, amount);
    }

    function testFuzz_setAllowanceForAllUnauthorized(address caller) public {
        _assumeNoRole(caller, RolesLib.SPENDING_ADMIN);
        address[] memory targets = new address[](1);
        targets[0] = caller;
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        token.setAllowanceForAll(targets, true);
    }

    function testFuzz_setNameUnauthorized(address caller, string calldata newName) public {
        _assumeNoRole(caller, RolesLib.TOKEN_ADMIN);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        token.setName(newName);
    }

}
