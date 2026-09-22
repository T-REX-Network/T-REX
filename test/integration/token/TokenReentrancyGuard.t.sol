// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";

import { ReentrantModule } from "../mocks/ReentrantModule.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice M-06: a module hook must not be able to reenter the token mid-operation.
/// @dev Each test arms a hostile module bound to the live compliance, runs a normal operation, and
///  asserts the nested call the module made from its hook was rejected by the guard. The module records
///  the nested result instead of bubbling it, so the assertion is on the nested call specifically and
///  cannot be satisfied by the outer operation failing for some unrelated reason.
contract TokenReentrancyGuardTest is TREXSuiteTest {

    ModularCompliance internal compliance;
    ReentrantModule internal attacker;

    uint256 internal constant MINT_AMOUNT = 1000;
    uint256 internal constant TRANSFER_AMOUNT = 100;

    function setUp() public override {
        super.setUp();

        compliance = ModularCompliance(address(token.compliance()));

        attacker = ReentrantModule(
            address(new ERC1967Proxy(address(new ReentrantModule()), abi.encodeCall(ReentrantModule.initialize, ())))
        );

        vm.prank(deployer);
        compliance.addModule(address(attacker));

        // The module is given full agent rights so its nested mint and forced transfer are authorized
        // calls. Without them those paths revert on access control before ever reaching the guard, and
        // the test would pass without proving anything about reentrancy.
        _grantAllAgentRoles(address(attacker));

        vm.startPrank(agent);
        token.unpause();
        token.mint(alice, MINT_AMOUNT);
        vm.stopPrank();
    }

    function testNestedTransferFromTransferHookIsBlocked() public {
        attacker.arm(address(token), ReentrantModule.Attack.Transfer, alice, bob, TRANSFER_AMOUNT);

        vm.prank(alice);
        token.transfer(bob, TRANSFER_AMOUNT);

        _assertNestedCallRejected();
    }

    function testNestedMintFromMintHookIsBlocked() public {
        attacker.arm(address(token), ReentrantModule.Attack.Mint, address(0), bob, TRANSFER_AMOUNT);

        vm.prank(agent);
        token.mint(alice, MINT_AMOUNT);

        _assertNestedCallRejected();
    }

    function testNestedForcedTransferFromTransferHookIsBlocked() public {
        attacker.arm(address(token), ReentrantModule.Attack.ForcedTransfer, alice, bob, TRANSFER_AMOUNT);

        vm.prank(agent);
        token.forcedTransfer(alice, bob, TRANSFER_AMOUNT);

        _assertNestedCallRejected();
    }

    /// @dev A disarmed module proves the harness itself does not block anything: the same setup with no
    ///  reentry lets the transfer through, so the three tests above fail for the reentry and nothing else.
    function testTransferSucceedsWhenModuleDoesNotReenter() public {
        attacker.arm(address(token), ReentrantModule.Attack.None, alice, bob, TRANSFER_AMOUNT);

        vm.prank(alice);
        token.transfer(bob, TRANSFER_AMOUNT);

        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(alice), MINT_AMOUNT - TRANSFER_AMOUNT);
    }

    function _assertNestedCallRejected() private view {
        assertFalse(attacker.lastCallSucceeded(), "nested call should have been rejected");
        assertEq(
            attacker.lastCallReturnData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "nested call should revert on the guard"
        );
    }

}
