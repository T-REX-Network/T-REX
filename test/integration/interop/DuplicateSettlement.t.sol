// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A settlement leg delivered again byte for byte, under another receive id, is applied once: the second
///      delivery is consumed, changes nothing and pauses nothing. That is what a gateway redelivery or a Lite
///      resending a lost settlement produces. Another body under an already settled id is still a replay and
///      pauses the chain that sent it.
contract DuplicateSettlementTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;

    ERC7786GatewayMock polygonGateway;
    ERC7786GatewayMock optimismGateway;

    bytes aliceSat;
    bytes bobSat;
    bytes bobOptimism;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        vm.prank(agent);
        token.unpause();
    }

    function _status(bytes32 id) private view returns (uint8) {
        return uint8(boundCompliance.statusOf(id));
    }

    function _assertNothingPaused() private view {
        assertFalse(token.isInboundPaused(polygon), "polygon inbound");
        assertFalse(token.isInboundPaused(optimism), "optimism inbound");
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

    function test_handleSettlement_PausesTheChain_WhenAnotherBodyArrivesForASettledId() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 100);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95)));
        uint256 conflicting = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 96));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(conflicting);

        assertTrue(token.isInboundPaused(polygon));
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

        assertTrue(token.isInboundPaused(polygon));
    }

    /// @dev A leg outside the issued terms pauses its chain. Once the pauser has reopened it, the copy still
    ///      waiting at the gateway is consumed as a duplicate: the chain is not stopped twice over one leg.
    function test_handleSettlement_KeepsTheChainOpen_WhenARejectedLegIsDeliveredAgainAfterThePauseIsLifted() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 100);
        uint256 first = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 101));
        uint256 again = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 101));
        polygonGateway.relay(first);
        assertTrue(token.isInboundPaused(polygon), "the leg outside the terms pauses its chain");
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, polygon);
        polygonGateway.relay(again);

        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(again)), "consumed");
        _assertNothingPaused();
        assertEq(token.awayBalanceOf(bobSat), 0, "nothing applied");
        assertEq(_status(id), uint8(ITickets.TicketStatus.Open), "the validation stands");
    }

    /* ----- Two legs ----- */

    /// @dev The burn leg delivered again before the mint: one hold, and the mint still completes the pair.
    function test_handleSettlement_HoldsOnce_WhenTheBurnLegIsDeliveredTwice() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 90, 100);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));

        uint256 again = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, polygon);
        polygonGateway.relay(again);

        _assertNothingPaused();
        assertEq(token.onHoldOf(id), 95, "held once");
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 95, "debited once");

        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95)));
        assertEq(_status(id), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobOptimism), 95);
    }

    function test_handleSettlement_CreditsOnce_WhenTheMintLegIsDeliveredTwice() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 90, 100);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));
        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95)));

        uint256 again = _liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(id, optimism);
        optimismGateway.relay(again);

        _assertNothingPaused();
        assertEq(token.awayBalanceOf(bobOptimism), 95, "credited once");
    }

    /// @dev The burn leg landed, the mint never came and the keeper resolved the pair, returning the burned
    ///      amount. The burn leg delivered again then is still the leg already applied: nothing returns twice,
    ///      nothing pauses. A mint arriving after the resolution is another matter, see `StuckValidation.t.sol`.
    function test_handleSettlement_ReturnsOnce_WhenTheBurnLegIsDeliveredAgainAfterTheResolution() public {
        uint256 issuedAt = block.timestamp;
        bytes32 id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 90, 100);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));
        vm.warp(issuedAt + VALIDITY_WINDOW + 2 * OPTIMISM_WINDOW + 1);
        vm.prank(keeper);
        boundCompliance.resolveStuckValidation(id);
        assertEq(token.awayBalanceOf(aliceSat), BALANCE, "returned");

        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));

        _assertNothingPaused();
        assertEq(token.awayBalanceOf(aliceSat), BALANCE, "returned once");
        assertEq(token.onHoldOf(id), 0);
        assertEq(_status(id), uint8(ITickets.TicketStatus.Resolved));
    }

}
