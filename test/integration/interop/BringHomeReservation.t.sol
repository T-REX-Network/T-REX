// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev An open bring home holds its amount back from the away wallet's available balance, from the ask until its
///      receipt lands, so no ticket asked in between can draw on tokens being brought home.
contract BringHomeReservationTest is InteropSuiteTest {

    uint256 internal constant POSITION = 500;

    ERC7786GatewayMock polygonGateway;

    bytes aliceSat;
    bytes bobSat;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(polygonGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), POSITION);
        bobSat = _fundSatelliteWallet(bobIdentity, bob, POLYGON, makeAccount("bobOnPolygon"), POSITION);

        vm.prank(agent);
        token.unpause();
    }

    /// @dev An agent brings `amount` of `wallet` home to `nativeWallet`.
    function _bringHome(bytes memory wallet, address nativeWallet, uint256 amount) private returns (bytes32) {
        vm.prank(agent);
        return boundCompliance.bringHome(wallet, amount, nativeWallet, _salt());
    }

    /// @dev The away token's receipt for the bring home's first half, burning `amount` from `wallet`, lands.
    function _landTheReceipt(bytes32 bringHomeId, bytes memory wallet, uint256 amount) private {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _bringHomeReceipt(bringHomeId, wallet, amount)));
    }

    function _bringHomeReceipt(bytes32 bringHomeId, bytes memory wallet, uint256 amount)
        private
        pure
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return MessageTypesLib.ReceiptMessage({
            ticketId: bringHomeId,
            from: wallet,
            to: "",
            amount: amount,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: 1,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
    }

    function _aliceRequests(uint256 min, uint256 max) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, min, max);
    }

    /* ----- From the bring home ----- */

    /// @dev A bring home reserves its amount in the same table as every ticket.
    function test_bringHome_reservesTheAmountOnTheWallet() public {
        _bringHome(aliceSat, alice, 200);

        assertEq(token.availableOf(aliceSat), POSITION - 200, "the amount brought home is held back");
        assertEq(token.awayBalanceOf(aliceSat), POSITION, "nothing moves until the receipt");
        assertEq(token.reservedOf(aliceSat), 200, "reserved like a ticket");
        assertEq(token.availableOf(bobSat), POSITION, "another wallet is untouched");
    }

    /// @dev The headline case: a bring home followed by an ask on the same wallet. The ask must fit in what is free.
    function test_askToMove_reverts_when_itWouldSpendTokensABringHomeReserved() public {
        _bringHome(aliceSat, alice, 200);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceSat, POSITION - 200, POSITION)
        );
        _aliceRequests(1, POSITION);

        bytes32 id = _aliceRequests(1, POSITION - 200);
        assertEq(boundCompliance.ticketOf(id).amountMax, POSITION - 200, "what is free may be asked");
        assertEq(token.reservedOf(aliceSat), POSITION);
        assertEq(token.availableOf(aliceSat), 0);
    }

    function test_askToMove_reverts_when_theBringHomeTakesTheWholePosition() public {
        _bringHome(aliceSat, alice, POSITION);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceSat, 0, 100));
        _aliceRequests(1, 100);
    }

    /// @dev A bring home is bounded by what tickets leave free, so the two never together exceed the position.
    function test_bringHome_reverts_when_aTicketReservedWhatItAsksFor() public {
        _aliceRequests(1, 300);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceSat, POSITION - 300, POSITION - 299)
        );
        boundCompliance.bringHome(aliceSat, POSITION - 299, alice, _salt());
    }

    /// @dev A half sent again repeats the bring home under the same record, so the amount is not held back twice.
    function test_sendSecondHalf_doesNotReserveTheBringHomeTwice() public {
        bytes32 bringHomeId = _bringHome(aliceSat, alice, 200);
        vm.warp(boundCompliance.ticketOf(bringHomeId).secondHalfValidUntil + POLYGON_WINDOW);

        boundCompliance.sendSecondHalf(bringHomeId, aliceSat);

        assertEq(token.availableOf(aliceSat), POSITION - 200);
    }

    /* ----- Until the receipt ----- */

    function test_receiveReceipt_releasesTheReservation_whenTheWholeAmountIsBurned() public {
        bytes32 bringHomeId = _bringHome(aliceSat, alice, 200);

        _landTheReceipt(bringHomeId, aliceSat, 200);

        assertEq(token.awayBalanceOf(aliceSat), POSITION - 200);
        assertEq(token.availableOf(aliceSat), POSITION - 200, "what is left is free again");
        bytes32 id = _aliceRequests(1, POSITION - 200);
        assertEq(boundCompliance.ticketOf(id).amountMax, POSITION - 200);
    }

    /// @dev The away token burned less than asked: the receipt ends the bring home, so the whole remainder is
    ///      free, the part that was reserved but not burned included.
    function test_receiveReceipt_releasesTheReservation_whenTheAwayTokenBurnedLess() public {
        bytes32 bringHomeId = _bringHome(aliceSat, alice, 200);

        _landTheReceipt(bringHomeId, aliceSat, 150);

        assertEq(token.awayBalanceOf(aliceSat), POSITION - 150);
        assertEq(token.availableOf(aliceSat), POSITION - 150);
    }

    function test_receiveReceipt_releasesTheReservation_whenTheAwayTokenBurnedNothing() public {
        bytes32 bringHomeId = _bringHome(aliceSat, alice, 200);

        _landTheReceipt(bringHomeId, aliceSat, 0);

        assertEq(token.availableOf(aliceSat), POSITION, "a zero receipt ends the bring home too");
        _aliceRequests(1, POSITION);
    }

    /// @dev A receipt that burned more than asked is refused, blocks the chain, and leaves the reservation.
    function test_receiveReceipt_keepsTheReservation_whenTheReceiptIsRefused() public {
        bytes32 bringHomeId = _bringHome(aliceSat, alice, 200);

        uint256 index = _liteSettles(polygonGateway, token, _bringHomeReceipt(bringHomeId, aliceSat, 201));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(bringHomeId, polygon, 201, bytes32(0), ITickets.ReceiptRefusal.AboveTheBringHome);
        polygonGateway.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(token.availableOf(aliceSat), POSITION - 200);
    }

    /// @dev End to end: a bring home, an ask for what is left, the away token burning the amount brought home and
    ///      executing the ticket in full, and both landing.
    function test_bringHomeThenTicket_bothSettle_whenTheAwayTokenExecutesBoth() public {
        bytes32 bringHomeId = _bringHome(aliceSat, alice, 200);
        bytes32 id = _aliceRequests(1, POSITION - 200);

        _landTheReceipt(bringHomeId, aliceSat, 200);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, POSITION - 200)));

        assertEq(token.awayBalanceOf(aliceSat), 0);
        assertEq(token.awayBalanceOf(bobSat), POSITION + POSITION - 200);
        assertEq(token.availableOf(aliceSat), 0);
        assertEq(token.reservedOf(aliceSat), 0);
        assertFalse(token.paused());
    }

}
