// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";
import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";

contract TokenFreezeDiagnosticsTest is TokenBaseUnitTest {

    uint256 private constant INITIAL_BALANCE = 1000;

    function setUp() public override {
        super.setUp();
        vm.prank(agent);
        token.mint(user1, INITIAL_BALANCE);
    }

    function test_freezePartialTokens_reportsAvailableBalanceAndPreservesRejectedState() public {
        _freeze(user1, 600);
        vm.recordLogs();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 400, 500));
        vm.prank(agent);
        token.freezePartialTokens(user1, 500);

        assertEq(vm.getRecordedLogs().length, 0, "rejection emits no freeze event");
        _assertHolding(600);
    }

    function test_freezePartialTokens_freezesExactlyTheAvailableBalance() public {
        _freeze(user1, 600);
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.TokensFrozen(user1, 400);

        _freeze(user1, 400);

        _assertHolding(INITIAL_BALANCE);
    }

    function test_freezePartialTokens_reportsZeroWhenFullyFrozen() public {
        _freeze(user1, INITIAL_BALANCE);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 0, 1));
        vm.prank(agent);
        token.freezePartialTokens(user1, 1);

        _assertHolding(INITIAL_BALANCE);
    }

    function test_freezePartialTokens_zeroAmountPreservesAnExistingFreeze() public {
        _freeze(user1, INITIAL_BALANCE);
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.TokensFrozen(user1, 0);

        _freeze(user1, 0);

        _assertHolding(INITIAL_BALANCE);
    }

    function test_freezePartialTokens_reportsTotalBalanceWhenNothingIsFrozen() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 1000, 1001));
        vm.prank(agent);
        token.freezePartialTokens(user1, 1001);

        _assertHolding(0);
    }

    function test_freezePartialTokens_maximumRequestReportsAvailableBalance() public {
        _freeze(user1, 600);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 400, type(uint256).max)
        );
        vm.prank(agent);
        token.freezePartialTokens(user1, type(uint256).max);

        _assertHolding(600);
    }

    function test_batchFreezePartialTokens_rollsBackEarlierFreezesWhenALaterRequestFails() public {
        _freeze(user1, 600);
        (address[] memory wallets, uint256[] memory amounts) = _batch(100, 301);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 300, 301));
        vm.prank(agent);
        token.batchFreezePartialTokens(wallets, amounts);

        _assertHolding(600);
    }

    function test_batchFreezePartialTokens_usesTheRemainingBalanceForRepeatedWallets() public {
        _freeze(user1, 600);
        (address[] memory wallets, uint256[] memory amounts) = _batch(100, 300);

        vm.prank(agent);
        token.batchFreezePartialTokens(wallets, amounts);

        _assertHolding(INITIAL_BALANCE);
    }

    function testFuzz_freezePartialTokens_reportsRemainingBalanceWithoutChangingState(
        uint96 balanceSeed,
        uint96 frozenSeed,
        uint96 excessSeed
    ) public {
        uint256 balance = bound(uint256(balanceSeed), 1, type(uint96).max);
        uint256 frozen = bound(uint256(frozenSeed), 0, balance);
        uint256 availableBalance = balance - frozen;
        uint256 excess = bound(uint256(excessSeed), 1, type(uint96).max);
        uint256 requested = availableBalance + excess;
        vm.prank(agent);
        token.mint(user2, balance);
        _freeze(user2, frozen);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user2, availableBalance, requested)
        );
        vm.prank(agent);
        token.freezePartialTokens(user2, requested);

        assertEq(token.balanceOf(user2), balance, "rejection preserves the wallet balance");
        assertEq(token.getFrozenTokens(user2), frozen, "rejection preserves the frozen amount");
        assertEq(token.totalSupply(), INITIAL_BALANCE + balance, "freezing never changes supply");
    }

    function _freeze(address wallet, uint256 amount) private {
        vm.prank(agent);
        token.freezePartialTokens(wallet, amount);
    }

    function _assertHolding(uint256 expectedFrozen) private view {
        assertEq(token.getFrozenTokens(user1), expectedFrozen, "frozen amount matches the successful requests");
        assertEq(token.balanceOf(user1), INITIAL_BALANCE, "freezing preserves the wallet balance");
        assertEq(token.totalSupply(), INITIAL_BALANCE, "freezing preserves supply");
    }

    function _batch(uint256 firstAmount, uint256 secondAmount)
        private
        view
        returns (address[] memory wallets, uint256[] memory amounts)
    {
        wallets = new address[](2);
        wallets[0] = user1;
        wallets[1] = user1;
        amounts = new uint256[](2);
        amounts[0] = firstAmount;
        amounts[1] = secondAmount;
    }

}
