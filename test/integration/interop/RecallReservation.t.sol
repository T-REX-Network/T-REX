// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev An open recall holds its amount back from the satellite wallet's available balance, from the instruction
///      until the proof settles it, so no validation issued in between can draw on tokens being recalled.
contract RecallReservationTest is InteropSuiteTest {

    uint256 internal constant POSITION = 500;

    ERC7786GatewayMock polygonGateway;

    bytes aliceSat;
    bytes bobSat;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(polygonGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), POSITION);
        bobSat = _fundSatelliteWallet(bobIdentity, bob, POLYGON, makeAccount("bobOnPolygon"), POSITION);

        vm.prank(agent);
        token.unpause();
    }

    function _recall(bytes memory wallet, address nativeWallet, uint256 amount) private returns (uint256) {
        vm.prank(agent);
        return token.instructRecall(wallet, amount, nativeWallet);
    }

    function _prove(uint256 recallId, bytes memory wallet, uint256 amount) private {
        polygonGateway.relay(
            _liteSends(polygonGateway, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, wallet, amount)))
        );
    }

    function _aliceRequests(uint256 min, uint256 max) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, min, max);
    }

    /* ----- From the instruction ----- */

    function test_instructRecall_ReservesTheAmountOnTheWallet() public {
        _recall(aliceSat, alice, 200);

        assertEq(token.availableOf(aliceSat), POSITION - 200, "the recalled amount is held back");
        assertEq(token.awayBalanceOf(aliceSat), POSITION, "nothing moves until the proof");
        assertEq(token.reservedOf(aliceSat), 0, "validation reservations are untouched");
        assertEq(token.availableOf(bobSat), POSITION, "another wallet is untouched");
    }

    /// @dev The headline case: a recall followed by a validation request on the same wallet.
    function test_requestTransferValidation_IsNarrowed_WhenARecallIsOpen() public {
        _recall(aliceSat, alice, 200);

        bytes32 id = _aliceRequests(1, POSITION);

        assertEq(boundCompliance.ticketOf(id).amountMax, POSITION - 200, "capped below the recalled amount");
        assertEq(token.reservedOf(aliceSat), POSITION - 200);
        assertEq(token.availableOf(aliceSat), 0);
    }

    function test_requestTransferValidation_RevertWhen_TheRecallTakesTheWholePosition() public {
        _recall(aliceSat, alice, POSITION);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1, 0));
        _aliceRequests(1, 100);
    }

    function test_requestTransferValidation_RevertWhen_TheMinimumNeedsTheRecalledAmount() public {
        _recall(aliceSat, alice, 200);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 301, 300));
        _aliceRequests(301, POSITION);
    }

    /// @dev A recall is bounded by the position, not by reservations, so the two can together exceed it: the
    ///      available balance floors at zero and nothing more can be issued.
    function test_availableOf_FloorsAtZero_WhenAValidationAndARecallTogetherExceedThePosition() public {
        _aliceRequests(1, 300);
        _recall(aliceSat, alice, 400);

        assertEq(token.availableOf(aliceSat), 0);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1, 0));
        _aliceRequests(1, 1);
    }

    /// @dev A resend repeats the instruction under the same record, so the amount is not held back twice.
    function test_resend_DoesNotReserveTheRecallTwice() public {
        uint256 recallId = _recall(aliceSat, alice, 200);

        vm.prank(agent);
        token.resend(1, recallId, abi.encode(aliceSat));

        assertEq(token.availableOf(aliceSat), POSITION - 200);
    }

    /* ----- Until the proof ----- */

    function test_burnProof_ReleasesTheReservation_WhenTheWholeAmountIsBurned() public {
        uint256 recallId = _recall(aliceSat, alice, 200);

        _prove(recallId, aliceSat, 200);

        assertEq(token.awayBalanceOf(aliceSat), POSITION - 200);
        assertEq(token.availableOf(aliceSat), POSITION - 200, "what is left is free again");
        bytes32 id = _aliceRequests(1, POSITION);
        assertEq(boundCompliance.ticketOf(id).amountMax, POSITION - 200);
    }

    /// @dev The satellite burned less than instructed: the proof closes the recall, so the whole remainder is
    ///      free, the part that was reserved but not burned included.
    function test_burnProof_ReleasesTheReservation_WhenTheSatelliteBurnedLess() public {
        uint256 recallId = _recall(aliceSat, alice, 200);

        _prove(recallId, aliceSat, 150);

        assertEq(token.awayBalanceOf(aliceSat), POSITION - 150);
        assertEq(token.availableOf(aliceSat), POSITION - 150);
    }

    function test_burnProof_ReleasesTheReservation_WhenTheSatelliteBurnedNothing() public {
        uint256 recallId = _recall(aliceSat, alice, 200);

        _prove(recallId, aliceSat, 0);

        assertEq(token.availableOf(aliceSat), POSITION, "a zero proof closes the recall too");
        _aliceRequests(1, POSITION);
    }

    /// @dev A proof that does not settle the recall leaves the reservation in place.
    function test_burnProof_KeepsTheReservation_WhenTheProofIsRefused() public {
        uint256 recallId = _recall(aliceSat, alice, 200);
        uint256 index =
            _liteSends(polygonGateway, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, aliceSat, 201)));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RecallAmountExceeded.selector, recallId, 200, 201));
        polygonGateway.relay(index);

        assertEq(token.availableOf(aliceSat), POSITION - 200);
    }

    /// @dev The order the issue is about, end to end: a recall, a request narrowed below it, the satellite
    ///      burning the recalled amount and executing the validation in full, and both landing.
    function test_recallThenValidation_BothSettle_WhenTheSatelliteExecutesBoth() public {
        uint256 recallId = _recall(aliceSat, alice, 200);
        bytes32 id = _aliceRequests(1, POSITION);

        _prove(recallId, aliceSat, 200);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, POSITION - 200)));

        assertEq(token.awayBalanceOf(aliceSat), 0);
        assertEq(token.awayBalanceOf(bobSat), POSITION + POSITION - 200);
        assertEq(token.availableOf(aliceSat), 0);
        assertEq(token.reservedOf(aliceSat), 0);
        assertFalse(token.paused());
    }

}
