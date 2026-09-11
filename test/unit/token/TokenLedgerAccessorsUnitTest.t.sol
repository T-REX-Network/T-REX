// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

/// @notice The ledger accessors on a plain token: what they read on a fresh deployment and how they relate once
///         a native position exists. The bridged bucket is exercised through the harness in the transition tests.
contract TokenLedgerAccessorsUnitTest is TokenBaseUnitTest {

    uint256 internal constant SATELLITE_CHAIN = 8453;

    function setUp() public override {
        super.setUp();
        vm.prank(agent);
        token.unpause();
    }

    function test_freshToken_EveryAccessorReadsZero() public view {
        assertEq(token.balanceOf(user1), 0);
        assertEq(token.getFrozenTokens(user1), 0);
        assertEq(token.freeBalanceOf(user1), 0);
        assertEq(token.bridgedBalanceOf(InteroperableAddress.formatEvmV1(SATELLITE_CHAIN, user1)), 0);
        assertEq(token.totalBridged(), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_balanceOf_IsFreePlusFrozen() public {
        vm.startPrank(agent);
        token.mint(user1, 1000);
        token.freezePartialTokens(user1, 300);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), 1000);
        assertEq(token.getFrozenTokens(user1), 300);
        assertEq(token.freeBalanceOf(user1), 700);
        assertEq(token.balanceOf(user1), token.freeBalanceOf(user1) + token.getFrozenTokens(user1));
    }

    function test_freeBalanceOf_FollowsFreezeAndUnfreeze() public {
        vm.startPrank(agent);
        token.mint(user1, 1000);
        token.freezePartialTokens(user1, 1000);
        assertEq(token.freeBalanceOf(user1), 0);
        token.unfreezePartialTokens(user1, 250);
        vm.stopPrank();

        assertEq(token.freeBalanceOf(user1), 250);
    }

    function test_totalSupply_IsThePlainSupplyWhileNothingIsBridged() public {
        vm.prank(agent);
        token.mint(user1, 1000);

        assertEq(token.totalSupply(), 1000);
        assertEq(token.totalBridged(), 0);
    }

    function test_bridgedBalanceOf_ReadsZeroForAReferenceChainWallet() public view {
        assertEq(token.bridgedBalanceOf(InteroperableAddress.formatEvmV1(block.chainid, user1)), 0);
    }

    function test_bridgedBalanceOf_AcceptsANonEvmEnvelope() public view {
        bytes memory envelope = InteroperableAddress.formatV1(0x0002, hex"0102", new bytes(32));
        assertEq(token.bridgedBalanceOf(envelope), 0);
    }

    function test_bridgedBalanceOf_RevertWhen_EnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(InteroperableAddress.formatEvmV1(SATELLITE_CHAIN, user1), hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        token.bridgedBalanceOf(padded);
    }

    function test_bridgedBalanceOf_RevertWhen_EnvelopeIsEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, ""));
        token.bridgedBalanceOf("");
    }

}
