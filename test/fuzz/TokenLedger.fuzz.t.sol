// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { Token } from "contracts/token/Token.sol";

import { TREXSuiteTest } from "../integration/helpers/TREXSuiteTest.sol";
import { TokenLedgerHarness } from "../integration/helpers/TokenLedgerHarness.sol";

/// @title Token ledger property fuzzing
/// @notice Random movement sequences over the real suite keep the supply partitioned across the three buckets;
///         a delegation and its recall cancel out exactly; a padded satellite envelope never reaches a transition.
contract TokenLedgerFuzzTest is TREXSuiteTest {

    uint256 internal constant SATELLITE_CHAIN = 8453;
    uint256 internal constant OTHER_SATELLITE_CHAIN = 137;
    uint256 internal constant STEPS = 16;

    TokenLedgerHarness internal ledger;

    address[] internal actors;
    bytes[] internal satellites;

    function _deployImplementations() internal override {
        super._deployImplementations();
        tokenImplementation = Token(address(new TokenLedgerHarness()));
    }

    function setUp() public override {
        super.setUp();

        // The proxy is any token's; the implementation behind the beacon is the ledger harness.
        ledger = TokenLedgerHarness(address(token));

        actors = [alice, bob, charlie];
        satellites.push(InteroperableAddress.formatEvmV1(SATELLITE_CHAIN, makeAddr("alice-satellite")));
        satellites.push(InteroperableAddress.formatEvmV1(SATELLITE_CHAIN, makeAddr("bob-satellite")));
        satellites.push(InteroperableAddress.formatEvmV1(OTHER_SATELLITE_CHAIN, makeAddr("charlie-satellite")));

        vm.prank(agent);
        token.unpause();
    }

    /// @dev One movement per step: 0 mint, 1 burn, 2 transfer, 3 forced transfer, 4 freeze, 5 delegate out,
    ///      6 recall, 7 bridged transfer. Every call is bounded to the available position, and a revert is
    ///      tolerated: the property is about the state after whatever did apply.
    function _apply(uint8 op, uint8 a, uint8 b, uint128 rawAmount) internal {
        uint256 from = a % actors.length;
        uint256 to = b % actors.length;
        uint256 amount = rawAmount;
        uint8 kind = op % 8;
        if (kind == 2) {
            vm.prank(actors[from]);
            try token.transfer(actors[to], amount % (token.freeBalanceOf(actors[from]) + 1)) { } catch { }
            return;
        }

        vm.startPrank(agent);
        if (kind == 0) {
            try token.mint(actors[to], amount % 1e24) { } catch { }
        } else if (kind == 1) {
            try token.burn(actors[from], amount % (token.balanceOf(actors[from]) + 1)) { } catch { }
        } else if (kind == 3) {
            try token.forcedTransfer(actors[from], actors[to], amount % (token.balanceOf(actors[from]) + 1)) { }
                catch { }
        } else if (kind == 4) {
            try token.freezePartialTokens(actors[from], amount % (token.freeBalanceOf(actors[from]) + 1)) { } catch { }
        } else if (kind == 5) {
            try ledger.delegateOut(actors[from], satellites[from], amount % (token.freeBalanceOf(actors[from]) + 1)) { }
                catch { }
        } else if (kind == 6) {
            try ledger.recall(
                satellites[from], actors[from], amount % (token.bridgedBalanceOf(satellites[from]) + 1)
            ) { }
                catch { }
        } else {
            try ledger.bridgedTransfer(
                satellites[from], satellites[to], amount % (token.bridgedBalanceOf(satellites[from]) + 1), op
            ) { }
                catch { }
        }
        vm.stopPrank();
    }

    function _sums() internal view returns (uint256 freeSum, uint256 frozenSum, uint256 bridgedSum) {
        for (uint256 i = 0; i < actors.length; i++) {
            freeSum += token.freeBalanceOf(actors[i]);
            frozenSum += token.getFrozenTokens(actors[i]);
            bridgedSum += token.bridgedBalanceOf(satellites[i]);
        }
    }

    function testFuzz_movementSequencesKeepTheSupplyPartitioned(
        uint8[STEPS] memory ops,
        uint8[STEPS] memory froms,
        uint8[STEPS] memory tos,
        uint128[STEPS] memory amounts
    ) public {
        for (uint256 i = 0; i < STEPS; i++) {
            _apply(ops[i], froms[i], tos[i], amounts[i]);
        }

        (uint256 freeSum, uint256 frozenSum, uint256 bridgedSum) = _sums();
        assertEq(freeSum + frozenSum + bridgedSum, token.totalSupply(), "buckets do not sum to the supply");
        assertEq(bridgedSum, token.totalBridged(), "bridged total != bridged sum");
        assertEq(token.balanceOf(address(token)), 0, "the token holds no escrow");
        for (uint256 i = 0; i < actors.length; i++) {
            assertEq(
                token.balanceOf(actors[i]),
                token.freeBalanceOf(actors[i]) + token.getFrozenTokens(actors[i]),
                "balanceOf != free + frozen"
            );
        }
    }

    function testFuzz_delegateThenRecallIsTheIdentity(uint128 mintAmount, uint128 delegated, uint128 frozen) public {
        mintAmount = uint128(bound(mintAmount, 1, 1e30));
        frozen = uint128(bound(frozen, 0, mintAmount));
        delegated = uint128(bound(delegated, 0, mintAmount - frozen));

        vm.startPrank(agent);
        token.mint(alice, mintAmount);
        token.freezePartialTokens(alice, frozen);
        ledger.delegateOut(alice, satellites[0], delegated);

        assertEq(token.balanceOf(alice), mintAmount - delegated, "balance after delegation");
        assertEq(token.getFrozenTokens(alice), frozen, "frozen after delegation");
        assertEq(token.bridgedBalanceOf(satellites[0]), delegated, "bridged after delegation");
        assertEq(token.totalSupply(), mintAmount, "supply after delegation");

        ledger.recall(satellites[0], alice, delegated);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), mintAmount, "balance after recall");
        assertEq(token.getFrozenTokens(alice), frozen, "frozen after recall");
        assertEq(token.bridgedBalanceOf(satellites[0]), 0, "bridged after recall");
        assertEq(token.totalBridged(), 0, "bridged total after recall");
        assertEq(token.totalSupply(), mintAmount, "supply after recall");
    }

    function testFuzz_settlementConservesTheBridgedTotal(uint128 mintAmount, uint128 delegated, uint128 settled)
        public
    {
        mintAmount = uint128(bound(mintAmount, 1, 1e30));
        delegated = uint128(bound(delegated, 0, mintAmount));
        settled = uint128(bound(settled, 0, delegated));

        vm.startPrank(agent);
        token.mint(alice, mintAmount);
        ledger.delegateOut(alice, satellites[0], delegated);
        ledger.bridgedTransfer(satellites[0], satellites[2], settled, 1);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellites[0]), delegated - settled);
        assertEq(token.bridgedBalanceOf(satellites[2]), settled);
        assertEq(token.totalBridged(), delegated);
        assertEq(token.totalSupply(), mintAmount);
    }

    function testFuzz_paddedEnvelopeReachesNoTransition(bytes memory suffix, uint128 amount) public {
        vm.assume(suffix.length > 0);
        bytes memory padded = abi.encodePacked(satellites[0], suffix);
        bytes memory expected = abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded);

        vm.startPrank(agent);
        token.mint(alice, 1000);
        ledger.delegateOut(alice, satellites[0], 500);

        vm.expectRevert(expected);
        ledger.delegateOut(alice, padded, amount % 500);
        vm.expectRevert(expected);
        ledger.recall(padded, alice, amount % 500);
        vm.expectRevert(expected);
        ledger.bridgedTransfer(padded, satellites[1], amount % 500, 1);
        vm.expectRevert(expected);
        ledger.bridgedTransfer(satellites[0], padded, amount % 500, 1);
        vm.stopPrank();

        assertEq(token.bridgedBalanceOf(satellites[0]), 500);
        assertEq(token.totalBridged(), 500);
    }

}
