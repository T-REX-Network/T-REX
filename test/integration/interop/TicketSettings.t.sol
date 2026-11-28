// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";

/// @dev The settings of the clock and their floors and ceilings: the waiting time of an away chain, the two validity
///      windows, the times measured for an away chain that give the waiting time's floor, and the unbind that waits
///      until home stopped waiting for every ticket it wrote. The suite sets Polygon's times to a clock lead of 30
///      seconds, a full finality delivery of 20 minutes and a reorg slot shift of 1 minute. Every other sizing
///      condition is checked off chain.
contract TicketSettingsTest is InteropSuiteTest {

    uint64 internal constant ONE_HOUR = 1 hours;
    uint64 internal constant ONE_DAY = 1 days;

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
        ITickets.MeasuredTimes memory times = _measuredTimes();
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

    /// @notice The ask's round trip and the clock lag are sized off chain: one hour is taken on a chain whose full
    ///         finality delivery plus clock lead is below it, whatever its round trip is.
    function test_setWaitingTime_takesOneHour_aboveTheSecondHalfFloor() public {
        vm.startPrank(deployer);
        boundCompliance.setMeasuredTimes(base, _measuredTimes());
        boundCompliance.setWaitingTime(base, ONE_HOUR);
        vm.stopPrank();

        assertEq(boundCompliance.waitingTimeOf(base), ONE_HOUR);
    }

    /* ----- The validity windows ----- */

    /// @notice How old the rules may be when an away token executes is bounded: a window of ten years is refused.
    function test_setValidityWindows_reverts_when_itIsAboveTheLongestAllowed() public {
        uint64 tenYears = 3650 days;
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidityWindowOutOfRange.selector, tenYears, ONE_DAY));
        boundCompliance.setValidityWindows(15 minutes, tenYears);
    }

    /// @notice A window's floor is sized off chain: a window below the full finality delivery plus the clock lead
    ///         measured for an away chain is taken.
    function test_setValidityWindows_takesAWindowBelowTheMeasuredDelivery() public {
        uint64 oneMinute = 1 minutes;
        vm.prank(deployer);
        boundCompliance.setValidityWindows(oneMinute, oneMinute);

        assertEq(boundCompliance.validityWindows().onTicketRoute, oneMinute);
        assertEq(boundCompliance.validityWindows().onReceiptRoute, oneMinute);
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

    /// @notice New times never check the validity windows already set: a full finality delivery longer than the
    ///         receipt route's window is taken.
    function test_setMeasuredTimes_leavesTheValidityWindowsAlone() public {
        ITickets.MeasuredTimes memory times = _measuredTimes();
        times.fullFinalityDelivery = VALIDITY_WINDOW + 1;

        vm.prank(deployer);
        boundCompliance.setMeasuredTimes(polygon, times);

        assertEq(boundCompliance.measuredTimesOf(polygon).fullFinalityDelivery, VALIDITY_WINDOW + 1);
        assertEq(boundCompliance.validityWindows().onReceiptRoute, VALIDITY_WINDOW);
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

}
