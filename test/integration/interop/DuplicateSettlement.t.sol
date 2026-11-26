// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A receipt delivered again byte for byte, under another receive id, is applied once: the second
///      delivery is consumed, changes nothing and pauses nothing. That is what a gateway redelivery or a Lite
///      resending a lost receipt produces. Another body for a half that already has one is a bad receipt and
///      blocks the chain that sent it.
contract DuplicateSettlementTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;

    ERC7786GatewayMock polygonGateway;
    ERC7786GatewayMock optimismGateway;

    bytes aliceSat;
    bytes bobSat;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.prank(agent);
        token.unpause();
    }

    function _status(bytes32 id) private view returns (uint8) {
        return uint8(boundCompliance.statusOf(id));
    }

    function _assertNothingPaused() private view {
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "polygon inbound");
        assertFalse(boundCompliance.isAwayChainBlocked(optimism), "optimism inbound");
        assertFalse(token.paused(), "token");
    }

    /* ----- One leg ----- */

    function test_handleSettlement_AppliesOnce_WhenTheSameLegIsDeliveredTwice() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 100);
        uint256 first = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));
        uint256 again = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));
        assertTrue(polygonGateway.receiveIdFor(first) != polygonGateway.receiveIdFor(again), "two receive ids");
        polygonGateway.relay(first);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, polygon);
        polygonGateway.relay(again);

        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(again)), "consumed");
        _assertNothingPaused();
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 95, "debited once");
        assertEq(token.awayBalanceOf(bobSat), 95, "credited once");
        assertEq(_status(id), uint8(ITickets.TicketStatus.Done));
    }

    /// @dev The same leg any number of times is still one movement.
    function test_handleSettlement_AppliesOnce_WhenTheSameLegIsDeliveredManyTimes() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 100);
        for (uint256 i; i < 4; ++i) {
            polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95)));
        }

        _assertNothingPaused();
        assertEq(token.awayBalanceOf(bobSat), 95);
    }

    /// @dev A second, different receipt for a half that already has one is a bad receipt: refused, and its away
    ///      chain blocked. An away token answers one half once and sends that very receipt again on every repeat.
    function test_handleSettlement_PausesTheChain_WhenAnotherBodyArrivesForASettledId() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 100);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95)));
        uint256 conflicting = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 96));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, polygon, 96, boundCompliance.ticketOf(id).askBlockHash);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        polygonGateway.relay(conflicting);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertFalse(token.paused(), "the token keeps running");
        assertEq(token.awayBalanceOf(bobSat), 95, "applied once, at the first amount");
    }

    /// @dev A duplicate does not clear a conflict either: the conflicting body still pauses after it.
    function test_handleSettlement_PausesTheChain_WhenAConflictFollowsADuplicate() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 100);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95)));
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95)));
        _assertNothingPaused();

        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 90)));

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @dev A receipt outside the terms of home's own copy is applied as it happened and blocks its chain. Once the
    ///      pauser has reopened it, the copy still waiting at the bridge is consumed as a duplicate: the chain is not
    ///      blocked twice over one receipt, and nothing is applied twice.
    function test_handleSettlement_KeepsTheChainOpen_WhenARejectedLegIsDeliveredAgainAfterThePauseIsLifted() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 100);
        uint256 first = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 101));
        uint256 again = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 101));
        polygonGateway.relay(first);
        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the receipt outside the terms blocks its chain");
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, polygon);
        polygonGateway.relay(again);

        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(again)), "consumed");
        _assertNothingPaused();
        assertEq(token.awayBalanceOf(bobSat), 101, "applied once, as it happened");
        assertEq(_status(id), uint8(ITickets.TicketStatus.Done));
    }

}
