// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TREXSuiteTest } from "../integration/helpers/TREXSuiteTest.sol";

/// @title Token property fuzzing
/// @notice Stateless property tests for the Token freeze arithmetic and default-allowance truth table.
contract TokenFuzzTest is TREXSuiteTest {

    function setUp() public override {
        super.setUp();
        vm.prank(agent);
        token.unpause();
    }

    // ------------------------------------------------------------------
    // Freeze / unfreeze arithmetic
    // ------------------------------------------------------------------

    /// Frozen amount can never be set above balance, and once set stays <= balance.
    function testFuzz_freezeNeverExceedsBalance(uint256 mintAmt, uint256 freezeAmt) public {
        mintAmt = bound(mintAmt, 1, 1e30); // mint(0) reverts ZeroValue via compliance.created
        vm.prank(agent);
        token.mint(alice, mintAmt);

        freezeAmt = bound(freezeAmt, 0, mintAmt);
        vm.prank(agent);
        token.freezePartialTokens(alice, freezeAmt);

        assertEq(token.getFrozenTokens(alice), freezeAmt);
        assertLe(token.getFrozenTokens(alice), token.balanceOf(alice));
    }

    /// Freezing more than the balance must revert (no silent clamp).
    function testFuzz_freezeAboveBalanceReverts(uint256 mintAmt, uint256 excess) public {
        mintAmt = bound(mintAmt, 1, 1e30);
        excess = bound(excess, 1, 1e30);
        vm.prank(agent);
        token.mint(alice, mintAmt);

        vm.prank(agent);
        vm.expectRevert();
        token.freezePartialTokens(alice, mintAmt + excess);
    }

    /// Unfreezing more than is frozen reverts with AmountAboveFrozenTokens.
    function testFuzz_unfreezeAboveFrozenReverts(uint256 mintAmt, uint256 freezeAmt, uint256 unfreezeExcess) public {
        mintAmt = bound(mintAmt, 1, 1e30);
        freezeAmt = bound(freezeAmt, 0, mintAmt);
        unfreezeExcess = bound(unfreezeExcess, 1, 1e30);
        vm.startPrank(agent);
        token.mint(alice, mintAmt);
        token.freezePartialTokens(alice, freezeAmt);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.AmountAboveFrozenTokens.selector, freezeAmt + unfreezeExcess, freezeAmt)
        );
        token.unfreezePartialTokens(alice, freezeAmt + unfreezeExcess);
        vm.stopPrank();
    }

    /// A regular transfer can never spend into frozen tokens: it reverts if value > free balance.
    function testFuzz_transferCannotSpendFrozen(uint256 mintAmt, uint256 freezeAmt, uint256 sendAmt) public {
        mintAmt = bound(mintAmt, 1, 1e30);
        freezeAmt = bound(freezeAmt, 0, mintAmt);
        vm.startPrank(agent);
        token.mint(alice, mintAmt);
        token.freezePartialTokens(alice, freezeAmt);
        vm.stopPrank();

        uint256 free = mintAmt - freezeAmt;
        sendAmt = bound(sendAmt, free + 1, type(uint256).max);
        // guard against overflow of the bound range when free == mintAmt
        if (sendAmt <= free) return;

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, sendAmt);
    }

    /// Burning into frozen tokens auto-unfreezes exactly the shortfall.
    function testFuzz_burnAutoUnfreezes(uint256 mintAmt, uint256 freezeAmt, uint256 burnAmt) public {
        mintAmt = bound(mintAmt, 1, 1e30);
        freezeAmt = bound(freezeAmt, 0, mintAmt);
        burnAmt = bound(burnAmt, 1, mintAmt); // burn(0) reverts ZeroValue via compliance.destroyed
        vm.startPrank(agent);
        token.mint(alice, mintAmt);
        token.freezePartialTokens(alice, freezeAmt);

        uint256 free = mintAmt - freezeAmt;
        token.burn(alice, burnAmt);
        vm.stopPrank();

        uint256 expectedFrozen = burnAmt > free ? freezeAmt - (burnAmt - free) : freezeAmt;
        assertEq(token.getFrozenTokens(alice), expectedFrozen, "frozen after burn");
        assertEq(token.balanceOf(alice), mintAmt - burnAmt, "balance after burn");
        assertLe(token.getFrozenTokens(alice), token.balanceOf(alice), "frozen <= balance");
    }

    // ------------------------------------------------------------------
    // Default-allowance truth table  (covers AV-2)
    // ------------------------------------------------------------------

    /// allowance(owner, spender) == max  IFF  default-allowance(spender) && !optOut(owner).
    function testFuzz_defaultAllowanceTruthTable(address owner, address spender, bool makeDefault, bool optOut)
        public
    {
        vm.assume(owner != address(0) && spender != address(0));
        vm.assume(owner != spender);

        if (makeDefault) {
            address[] memory targets = new address[](1);
            targets[0] = spender;
            vm.prank(deployer); // SPENDING_ADMIN
            token.setAllowanceForAll(targets, true);
        }
        if (optOut) {
            vm.prank(owner);
            token.setDefaultAllowance(false); // sets opt-out for `owner`
        }

        uint256 expected = (makeDefault && !optOut) ? type(uint256).max : 0;
        assertEq(token.allowance(owner, spender), expected, "default-allowance truth table");
    }
}
