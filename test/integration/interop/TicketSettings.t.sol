// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";

/// @dev The settings of the clock and their floors and ceilings: the waiting time of an away chain, the two validity
///      windows, the times measured for an away chain that give their floors, and the unbind that waits until home
///      stopped waiting for every ticket it wrote. The suite sets Polygon's times to a shortest validity window of 10
///      minutes, a shortest waiting time of 80 minutes, a lead and a lag of 30 seconds, a full finality delivery of 20
///      minutes and a reorg slot shift of 1 minute.
contract TicketSettingsTest is InteropSuiteTest {

    uint64 internal constant ONE_HOUR = 1 hours;
    uint64 internal constant ONE_DAY = 1 days;
    /// @dev The suite's floor of the ticket route's window: Polygon's shortest validity window.
    uint64 internal constant TICKET_ROUTE_FLOOR = 10 minutes;
    /// @dev The suite's floor of the receipt route's window: Polygon's full finality delivery plus its clock lead.
    uint64 internal constant RECEIPT_ROUTE_FLOOR = 20 minutes + 30 seconds;

    /// @dev An away chain no test opened, to measure from scratch.
    bytes32 internal base = _evmChainKey(8453);

    /* ----- The waiting time ----- */

    /// @notice A waiting time of one second would let home cancel an executed ticket before its receipt could land:
    ///         nothing below one hour is taken.
    function test_setWaitingTime_reverts_when_itIsBelowOneHour() public {
        uint64 oneSecond = 1;
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WaitingTimeTooShort.selector, polygon, oneSecond, ONE_HOUR - 1)
        );
        boundCompliance.setWaitingTime(polygon, oneSecond);
    }

    /// @notice A waiting time must outlast a second half's full finality delivery on a clock that runs ahead:
    ///         equality is refused, one second more is taken.
    function test_setWaitingTime_reverts_when_itIsNotAboveTheSecondHalfFloor() public {
        uint64 delivery = 3000;
        uint64 lead = 600;
        uint64 secondHalfFloor = delivery + lead;
        _openTheWindowsWide();
        ITickets.MeasuredTimes memory times = _measuredTimes();
        times.shortestWaitingTime = 50 minutes;
        times.fullFinalityDelivery = delivery;
        times.clockLead = lead;
        vm.startPrank(deployer);
        boundCompliance.setMeasuredTimes(base, times);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WaitingTimeTooShort.selector, base, secondHalfFloor, secondHalfFloor)
        );
        boundCompliance.setWaitingTime(base, secondHalfFloor);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.WaitingTimeSet(base, secondHalfFloor + 1);
        boundCompliance.setWaitingTime(base, secondHalfFloor + 1);
        vm.stopPrank();

        assertEq(boundCompliance.waitingTimeOf(base), secondHalfFloor + 1);
    }

    /// @notice An away chain whose ask for the receipt takes 5,485 seconds at full finality refuses a waiting time
    ///         of 80 minutes: the answer could land after the cancel.
    function test_setWaitingTime_reverts_when_itIsNotAboveTheAskRoundTrip() public {
        uint64 askRoundTrip = 5485;
        uint64 eightyMinutes = 80 minutes;
        ITickets.MeasuredTimes memory times = _measuredTimes();
        times.shortestWaitingTime = askRoundTrip;
        vm.startPrank(deployer);
        boundCompliance.setMeasuredTimes(base, times);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WaitingTimeTooShort.selector, base, eightyMinutes, askRoundTrip)
        );
        boundCompliance.setWaitingTime(base, eightyMinutes);
        vm.stopPrank();
    }

    /* ----- The validity windows ----- */

    /// @notice How old the rules may be when an away token executes is bounded: a window of ten years is refused.
    function test_setValidityWindows_reverts_when_itIsAboveTheLongestAllowed() public {
        uint64 tenYears = 3650 days;
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidityWindowOutOfRange.selector, tenYears, RECEIPT_ROUTE_FLOOR, ONE_DAY)
        );
        boundCompliance.setValidityWindows(15 minutes, tenYears);
    }

    /// @notice A window at its floor is refused on either route: a holder acting at the last moment the floor allows
    ///         would reach the away token at valid until, and be refused there.
    function test_setValidityWindows_reverts_when_itIsNotAboveTheFloor() public {
        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidityWindowOutOfRange.selector, TICKET_ROUTE_FLOOR, TICKET_ROUTE_FLOOR, ONE_DAY
            )
        );
        boundCompliance.setValidityWindows(TICKET_ROUTE_FLOOR, VALIDITY_WINDOW);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidityWindowOutOfRange.selector, RECEIPT_ROUTE_FLOOR, RECEIPT_ROUTE_FLOOR, ONE_DAY
            )
        );
        boundCompliance.setValidityWindows(TICKET_ROUTE_WINDOW, RECEIPT_ROUTE_FLOOR);

        boundCompliance.setValidityWindows(TICKET_ROUTE_FLOOR + 1, RECEIPT_ROUTE_FLOOR + 1);
        vm.stopPrank();

        assertEq(boundCompliance.validityWindows().onTicketRoute, TICKET_ROUTE_FLOOR + 1);
        assertEq(boundCompliance.validityWindows().onReceiptRoute, RECEIPT_ROUTE_FLOOR + 1);
    }

    /// @notice The longest allowed window, one day, is taken on both routes.
    function test_setValidityWindows_succeeds_atTheLongest() public {
        vm.expectEmit(false, false, false, true, address(boundCompliance));
        emit EventsLib.ValidityWindowsSet(ONE_DAY, ONE_DAY);
        vm.prank(deployer);
        boundCompliance.setValidityWindows(ONE_DAY, ONE_DAY);

        assertEq(boundCompliance.validityWindows().onTicketRoute, ONE_DAY);
        assertEq(boundCompliance.validityWindows().onReceiptRoute, ONE_DAY);
    }

    /* ----- The measured times ----- */

    /// @notice New times whose ask round trip is the waiting time already set are refused.
    function test_setMeasuredTimes_reverts_when_theWaitingTimeNoLongerClearsTheAskRoundTrip() public {
        ITickets.MeasuredTimes memory times = _measuredTimes();
        times.shortestWaitingTime = POLYGON_WINDOW;

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WaitingTimeTooShort.selector, polygon, POLYGON_WINDOW, POLYGON_WINDOW)
        );
        boundCompliance.setMeasuredTimes(polygon, times);
    }

    /// @notice New times whose full finality delivery plus clock lead reach the waiting time already set are refused.
    function test_setMeasuredTimes_reverts_when_theWaitingTimeNoLongerClearsTheSecondHalfFloor() public {
        ITickets.MeasuredTimes memory times = _measuredTimes();
        times.fullFinalityDelivery = POLYGON_WINDOW - times.clockLead;

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WaitingTimeTooShort.selector, polygon, POLYGON_WINDOW, POLYGON_WINDOW)
        );
        boundCompliance.setMeasuredTimes(polygon, times);
    }

    /// @notice New times whose clock lag plus reorg slot shift reach the waiting time already set are refused.
    function test_setMeasuredTimes_reverts_when_theWaitingTimeNoLongerClearsTheClockLagAndReorgSlotShift() public {
        ITickets.MeasuredTimes memory times = _measuredTimes();
        times.clockLag = POLYGON_WINDOW - times.reorgSlotShift;

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WaitingTimeTooShort.selector, polygon, POLYGON_WINDOW, POLYGON_WINDOW)
        );
        boundCompliance.setMeasuredTimes(polygon, times);
    }

    /// @notice New times that raise a validity window's floor to the window already set are refused, on either route.
    function test_setMeasuredTimes_reverts_when_theWindowsNoLongerClearTheFloors() public {
        ITickets.MeasuredTimes memory ticketRouteTimes = _measuredTimes();
        ticketRouteTimes.shortestValidityWindow = TICKET_ROUTE_WINDOW;
        ITickets.MeasuredTimes memory receiptRouteTimes = _measuredTimes();
        receiptRouteTimes.fullFinalityDelivery = VALIDITY_WINDOW - receiptRouteTimes.clockLead;

        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidityWindowOutOfRange.selector, TICKET_ROUTE_WINDOW, TICKET_ROUTE_WINDOW, ONE_DAY
            )
        );
        boundCompliance.setMeasuredTimes(polygon, ticketRouteTimes);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidityWindowOutOfRange.selector, VALIDITY_WINDOW, VALIDITY_WINDOW, ONE_DAY
            )
        );
        boundCompliance.setMeasuredTimes(polygon, receiptRouteTimes);
        vm.stopPrank();
    }

    /// @notice The floors of the validity windows only rise: lower times measured for one chain leave the floor
    ///         another chain's times asked for.
    function test_setMeasuredTimes_neverLowersTheValidityWindowFloors() public {
        ITickets.MeasuredTimes memory lowerTimes = _measuredTimes();
        lowerTimes.shortestValidityWindow = 1 minutes;
        lowerTimes.fullFinalityDelivery = 1 minutes;

        vm.startPrank(deployer);
        boundCompliance.setMeasuredTimes(polygon, lowerTimes);
        boundCompliance.setMeasuredTimes(optimism, lowerTimes);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidityWindowOutOfRange.selector, RECEIPT_ROUTE_FLOOR, RECEIPT_ROUTE_FLOOR, ONE_DAY
            )
        );
        boundCompliance.setValidityWindows(TICKET_ROUTE_WINDOW, RECEIPT_ROUTE_FLOOR);
        vm.stopPrank();

        assertEq(boundCompliance.measuredTimesOf(polygon).fullFinalityDelivery, 1 minutes, "the times are taken");
    }

    /* ----- The unbind ----- */

    /// @notice A ticket's late receipt can land until its stop waiting time, and a new compliance would meet it with
    ///         no record: the token leaves only once home stopped waiting, even with nothing reserved and no supply.
    function test_unbindToken_reverts_before_theLatestStopWaitingAt() public {
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));
        uint256 awayBalance = 100;
        bytes memory aliceSat =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), awayBalance);
        bytes memory bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        vm.prank(agent);
        token.unpause();
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 50);
        uint64 stopWaitingAt = boundCompliance.ticketOf(ticketId).stopWaitingAt;
        assertEq(stopWaitingAt, boundCompliance.ticketOf(ticketId).validUntil + 4 * POLYGON_WINDOW);

        _cancelUnanswered(ticketId, bobSat, "");
        vm.startPrank(agent);
        TokenLedgerHarness(address(token)).ledgerBringHome(aliceSat, alice, awayBalance);
        token.burn(alice, awayBalance);
        vm.stopPrank();
        assertEq(token.totalSupply(), 0, "no supply left");
        assertEq(token.reservedOf(aliceSat), 0, "nothing reserved");
        ModularCompliance fresh = _newUnboundComplianceProxy(address(trexImplementationAuthority));

        vm.warp(stopWaitingAt - 1);
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TicketsStillReserved.selector);
        token.setCompliance(address(fresh));

        vm.warp(stopWaitingAt);
        vm.prank(deployer);
        token.setCompliance(address(fresh));
        assertEq(address(token.compliance()), address(fresh));
    }

    /* ----- Helpers ----- */

    /// @dev Windows of two hours on both routes, so new times with a long full finality delivery can be measured.
    function _openTheWindowsWide() private {
        vm.prank(deployer);
        boundCompliance.setValidityWindows(2 hours, 2 hours);
    }

}
