// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev A move from A to B run against the away token mock on both chains: every receipt home sees is produced by an
///      away token acting on what home sent it. The second half reaches B from home only.
contract SecondHalvesAwayTokensTest is InteropSuiteTest {

    uint256 internal constant MINTED = 1000;
    uint256 internal constant MOVED_OUT = 500;
    uint256 internal constant MOVED = 80;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    SatelliteLiteMock internal polygonLite;
    SatelliteLiteMock internal optimismLite;

    Account internal aliceOnPolygon;
    bytes internal aliceOnA;
    bytes internal bobOnB;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        // Each away token is the token's peer before its route opens: a peer set on an open route is a change.
        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);
        optimismLite = new SatelliteLiteMock(OPTIMISM, address(token), optimismGateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)), false);
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, address(optimismLite)), false);
        vm.stopPrank();
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        aliceOnA = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobOnB = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();

        bytes memory aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        vm.prank(alice);
        boundCompliance.askToMove(aliceHome, aliceOnA, MOVED_OUT, MOVED_OUT, "", _salt());
        _relayAll(polygonGateway);
        assertEq(polygonLite.balanceOf(aliceOnA), MOVED_OUT);
    }

    /// @notice B's away token mints a move out once per half, strictly before its valid until, and only on home's
    ///         message: a repeat of the half is answered with the stored receipt, and a message another away token
    ///         sends is refused, whatever it carries.
    function test_otherAwayToken_neverMintsOnAnotherAwayTokensMessage() public {
        bytes32 id = _askAndExecute(MOVED);
        _relayAll(polygonGateway);
        uint256 moveOutIndex = _lastIndex(optimismGateway);
        bytes memory moveOutPayload = optimismGateway.queuedMessage(moveOutIndex).payload;

        optimismGateway.relay(moveOutIndex);
        assertEq(optimismLite.balanceOf(bobOnB), MOVED, "minted on home's half");
        _homeSendsAgain(moveOutPayload);
        assertEq(optimismLite.mints(), MOVED, "a repeat of the half mints nothing more");

        vm.prank(address(polygonLite));
        optimismGateway.sendMessage(
            InteroperableAddress.formatEvmV1(OPTIMISM, address(optimismLite)), moveOutPayload, new bytes[](0)
        );
        uint256 fromAnotherAwayToken = _lastIndex(optimismGateway);
        vm.expectRevert(
            abi.encodeWithSelector(
                SatelliteLiteMock.NotTheReferenceToken.selector,
                InteroperableAddress.formatEvmV1(OPTIMISM, address(polygonLite))
            )
        );
        optimismGateway.relay(fromAnotherAwayToken);
        optimismGateway.drop(fromAnotherAwayToken);

        _relayAll(optimismGateway);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobOnB), MOVED);
        assertEq(optimismLite.mints(), MOVED, "one mint for one move");
    }

    /// @notice B's away token reads only envelope version 2: home's own move out, wrapped in an older or a newer
    ///         version, is refused and mints nothing.
    function test_otherAwayToken_refusesAMessageOfAnotherVersion() public {
        uint8 olderVersion = 1;
        uint8 newerVersion = 99;
        _askAndExecute(MOVED);
        _relayAll(polygonGateway);
        uint256 moveOutIndex = _lastIndex(optimismGateway);
        (uint8 messageType,, bytes memory body) =
            abi.decode(optimismGateway.queuedMessage(moveOutIndex).payload, (uint8, uint8, bytes));
        optimismGateway.drop(moveOutIndex);

        uint256 olderIndex = _homeQueues(abi.encode(messageType, olderVersion, body));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedMessageVersion.selector, olderVersion));
        optimismGateway.relay(olderIndex);

        uint256 newerIndex = _homeQueues(abi.encode(messageType, newerVersion, body));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedMessageVersion.selector, newerVersion));
        optimismGateway.relay(newerIndex);

        assertEq(optimismLite.mints(), 0, "nothing minted");
    }

    /// @notice A half that reaches B at or after its valid until is answered zero and stored: home makes a new half
    ///         owed, and the late half, sent again, still mints nothing.
    function test_otherAwayToken_answersALateHalfZero_andHomeOwesANewHalf() public {
        bytes32 id = _askAndExecute(MOVED);
        _relayAll(polygonGateway);
        uint256 moveOutIndex = _lastIndex(optimismGateway);
        bytes memory moveOutPayload = optimismGateway.queuedMessage(moveOutIndex).payload;
        vm.warp(boundCompliance.ticketOf(id).secondHalfValidUntil);

        optimismGateway.relay(moveOutIndex);
        _homeSendsAgain(moveOutPayload);
        _relayAll(optimismGateway);

        assertEq(optimismLite.mints(), 0, "nothing minted at or after valid until");
        MessageTypesLib.ReceiptMessage memory stored =
            optimismLite.storedReceipt(uint8(MessageTypesLib.Message.MOVE_OUT), MessageTypesLib.halfKeyOf(id, 1));
        assertEq(uint8(stored.answer), uint8(MessageTypesLib.ReceiptAnswer.Expired));
        assertTrue(boundCompliance.ticketOf(id).secondHalfOwed, "a new half is owed");

        boundCompliance.sendSecondHalf(id, bobOnB);
        _relayAll(optimismGateway);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(optimismLite.balanceOf(bobOnB), MOVED, "the new half minted once");
    }

    /* ----- Helpers ----- */

    /// @dev Alice asks to move `amount` from A to Bob on B; A's away token gets the ticket and Alice executes it.
    function _askAndExecute(uint256 amount) private returns (bytes32 id) {
        id = _requestValidation(address(aliceIdentity), aliceOnA, bobOnB, amount, amount);
        _relayAll(polygonGateway);
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(id, amount);
    }

    /// @dev Home's message to B delivered a second time, under a new delivery id.
    function _homeSendsAgain(bytes memory payload) private {
        _homeQueues(payload);
        optimismGateway.relay(_lastIndex(optimismGateway));
    }

    /// @dev Queues `payload` on B's bridge as sent by home's token.
    /// @return index its place in the queue
    function _homeQueues(bytes memory payload) private returns (uint256 index) {
        vm.prank(address(token));
        optimismGateway.sendMessage(
            InteroperableAddress.formatEvmV1(OPTIMISM, address(optimismLite)), payload, new bytes[](0)
        );
        index = _lastIndex(optimismGateway);
    }

    /// @dev Delivers every queued entry of `gateway` not yet delivered or dropped, in order.
    function _relayAll(ERC7786GatewayMock gateway) private {
        for (uint256 index = 0; index < gateway.queueLength(); index++) {
            ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(index);
            bool undelivered = message.deliveries == 0 && !message.dropped;
            if (undelivered) gateway.relay(index);
        }
    }

    function _lastIndex(ERC7786GatewayMock gateway) private view returns (uint256) {
        return gateway.queueLength() - 1;
    }

}
