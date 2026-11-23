// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { TokenBaseUnitTest } from "test/unit/token/TokenBaseUnitTest.t.sol";

/// @dev Pins the administrative burn policy independently of transfer admission.
contract TokenBatchBurnPolicyTest is TokenBaseUnitTest {

    error UnexpectedAdmissionCheck();
    error BurnHookRefused();

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        token.mint(user2, 50);
        token.freezePartialTokens(user1, 40);
        token.setAddressFrozen(user1, true);
        vm.stopPrank();

        vm.mockCallRevert(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector),
            abi.encodeWithSelector(UnexpectedAdmissionCheck.selector)
        );
        vm.mockCallRevert(
            compliance,
            abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector),
            abi.encodeWithSelector(UnexpectedAdmissionCheck.selector)
        );
    }

    function test_batchBurn_bypassesAdmissionWhilePausedAndFrozen() public {
        assertTrue(token.paused(), "fixture starts paused");
        vm.expectCall(identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector), 0);
        vm.expectCall(compliance, abi.encodeCall(IERC3643Compliance.destroyed, (user1, 70)), 1);
        vm.expectCall(compliance, abi.encodeCall(IERC3643Compliance.destroyed, (user2, 20)), 1);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.created.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), 0);

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.TokensUnfrozen(user1, 10);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(user1, address(0), 70);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(user2, address(0), 20);

        vm.prank(agent);
        token.batchBurn(_holders(), _amounts());

        assertEq(token.balanceOf(user1), 30, "first balance burned");
        assertEq(token.getFrozenTokens(user1), 30, "only ten frozen tokens released");
        assertTrue(token.isFrozen(user1), "address freeze retained");
        assertEq(token.balanceOf(user2), 30, "second balance burned");
        assertEq(token.getFrozenTokens(user2), 0, "second holder remains unfrozen");
        assertEq(token.totalSupply(), 60, "supply reduced by both burns");
        assertTrue(token.paused(), "burn does not lift the pause");
    }

    function test_batchBurn_revertsAtomicallyWhenDestroyedHookRefuses() public {
        vm.mockCallRevert(
            compliance,
            abi.encodeCall(IERC3643Compliance.destroyed, (user2, 20)),
            abi.encodeWithSelector(BurnHookRefused.selector)
        );

        vm.prank(agent);
        vm.expectRevert(BurnHookRefused.selector);
        token.batchBurn(_holders(), _amounts());

        assertEq(token.balanceOf(user1), 100, "earlier burn rolled back");
        assertEq(token.getFrozenTokens(user1), 40, "earlier unfreeze rolled back");
        assertEq(token.balanceOf(user2), 50, "refused burn rolled back");
        assertEq(token.totalSupply(), 150, "whole batch supply restored");
        assertTrue(token.isFrozen(user1), "address freeze retained");
        assertTrue(token.paused(), "pause retained");
    }

    function _holders() private view returns (address[] memory holders) {
        holders = new address[](2);
        holders[0] = user1;
        holders[1] = user2;
    }

    function _amounts() private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = 70;
        amounts[1] = 20;
    }

}
