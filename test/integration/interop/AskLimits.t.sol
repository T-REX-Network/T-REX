// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The limits on asks, counted per identity so one identity uses up only its own share of what home pays to
///      send: its open tickets, its asks in a window, an identity's own limit, the smallest amount, and the pause of
///      new asks for the whole token, under which the tickets already out still end.
contract AskLimitsTest is InteropSuiteTest {

    uint256 internal constant AWAY_BALANCE = 1000;
    uint64 internal constant ASK_WINDOW = 1 days;

    ERC7786GatewayMock internal polygonBridge;
    bytes internal aliceSat;
    bytes internal aliceOtherSat;
    bytes internal bobSat;
    bytes internal charlieSat;

    function setUp() public override {
        super.setUp();
        polygonBridge = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(polygonBridge));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), AWAY_BALANCE);
        aliceOtherSat = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));
        bobSat = _fundSatelliteWallet(bobIdentity, bob, POLYGON, makeAccount("bobOnPolygon"), AWAY_BALANCE);
        charlieSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));

        vm.prank(agent);
        token.unpause();
    }

    /* ----- Asks per window ----- */

    /// @notice Two asks per window: the third in the window is refused, and the next window opens again.
    function test_askToMove_reverts_when_theIdentityUsedItsAskLimit() public {
        uint32 asksPerWindow = 2;
        _setLimits(100, asksPerWindow, 1);
        uint256 windowStartedAt = block.timestamp;
        _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);
        _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);

        vm.warp(windowStartedAt + ASK_WINDOW - 1);
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AskLimitReached.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceSat, charlieSat, 1, 10, "", _salt());

        vm.warp(windowStartedAt + ASK_WINDOW);
        bytes32 nextWindowAsk = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);
        assertEq(uint8(boundCompliance.statusOf(nextWindowAsk)), uint8(ITickets.TicketStatus.Open));
    }

    /// @notice Alice moving between her own two wallets until her limit uses up her asks only: Bob still asks, and a
    ///         cancel of Bob's ticket still passes.
    function test_askToMove_stillWorksForOthers_whenOneIdentityAsksRepeatedly() public {
        uint32 asksPerWindow = 3;
        _setLimits(100, asksPerWindow, 1);
        _requestValidation(address(aliceIdentity), aliceSat, aliceOtherSat, 1, 10);
        _requestValidation(address(aliceIdentity), aliceSat, aliceOtherSat, 1, 10);
        _requestValidation(address(aliceIdentity), aliceSat, aliceOtherSat, 1, 10);
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AskLimitReached.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceSat, aliceOtherSat, 1, 10, "", _salt());

        bytes32 bobsTicket = _requestValidation(address(bobIdentity), bobSat, charlieSat, 1, 10);
        _cancelUnanswered(bobsTicket, charlieSat, "");

        assertEq(uint8(boundCompliance.statusOf(bobsTicket)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice An identity that moves often gets its own limit; zero gives it the token's limit again.
    function test_setAskLimitOf_givesOneIdentityItsOwnLimit() public {
        uint32 tokenLimit = 1;
        uint32 alicesOwnLimit = 2;
        _setLimits(100, tokenLimit, 1);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AskLimitOfSet(address(aliceIdentity), alicesOwnLimit);
        vm.prank(deployer);
        boundCompliance.setAskLimitOf(address(aliceIdentity), alicesOwnLimit);
        assertEq(boundCompliance.askLimitOf(address(aliceIdentity)), alicesOwnLimit);
        assertEq(boundCompliance.askLimitOf(address(bobIdentity)), tokenLimit, "others keep the token's limit");

        _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);
        _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AskLimitReached.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceSat, charlieSat, 1, 10, "", _salt());

        vm.prank(deployer);
        boundCompliance.setAskLimitOf(address(aliceIdentity), 0);
        assertEq(boundCompliance.askLimitOf(address(aliceIdentity)), tokenLimit);
    }

    /* ----- Open tickets ----- */

    /// @notice One open ticket per identity: a second ask is refused; a cancel frees the slot, and so does a receipt
    ///         that ends a ticket `Done`.
    function test_askToMove_reverts_when_theIdentityHasTooManyOpenTickets() public {
        uint32 openTicketsPerIdentity = 1;
        _setLimits(openTicketsPerIdentity, 1000, 1);
        bytes32 first = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TooManyOpenTickets.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceSat, charlieSat, 1, 10, "", _salt());

        _cancelUnanswered(first, charlieSat, "");
        bytes32 second = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);

        polygonBridge.relay(_liteSettles(polygonBridge, token, _settlement(second, aliceSat, charlieSat, 10)));
        assertEq(uint8(boundCompliance.statusOf(second)), uint8(ITickets.TicketStatus.Done));
        bytes32 third = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);
        assertEq(uint8(boundCompliance.statusOf(third)), uint8(ITickets.TicketStatus.Open));
    }

    /// @notice Limits of zero refuse every ask, as an unset window does.
    function test_askToMove_reverts_when_theAskLimitsAreZero() public {
        _setLimits(0, 0, 0);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TooManyOpenTickets.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceSat, charlieSat, 1, 10, "", _salt());
    }

    /// @notice An ask window of zero would count nothing: refused.
    function test_setAskLimits_reverts_when_theAskWindowIsZero() public {
        ITickets.AskLimits memory limits = _askLimits();
        limits.askWindow = 0;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroDuration.selector);
        boundCompliance.setAskLimits(limits);
    }

    /* ----- The smallest amount ----- */

    /// @notice An asked maximum below the smallest amount is refused, so a send home pays for always moves enough.
    function test_askToMove_reverts_when_theAmountIsBelowTheSmallestAmount() public {
        uint256 smallestAmount = 10;
        uint256 askedMax = smallestAmount - 1;
        _setLimits(100, 1000, smallestAmount);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BelowSmallestAmount.selector, askedMax, smallestAmount));
        boundCompliance.askToMove(aliceSat, charlieSat, 1, askedMax, "", _salt());

        bytes32 atTheSmallest = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, smallestAmount);
        assertEq(boundCompliance.ticketOf(atTheSmallest).amountMax, smallestAmount);
    }

    /* ----- A stopped token and paused asks ----- */

    /// @notice Nothing goes out while the token is stopped: an ask is refused.
    function test_askToMove_reverts_when_theTokenIsStopped() public {
        vm.prank(agent);
        token.pause();

        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.askToMove(aliceSat, charlieSat, 1, 10, "", _salt());
    }

    /// @notice Every receipt waits under the stop, and the one that answers the ticket may be among them: a cancel
    ///         otherwise due is refused.
    function test_cancelTickets_reverts_when_theTokenIsStopped() public {
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);
        _askAndLetTheAskGoUnanswered(ticketId, charlieSat, "");
        vm.prank(agent);
        token.pause();

        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.cancelTickets(_ids(ticketId));

        vm.prank(agent);
        token.unpause();
        boundCompliance.cancelTickets(_ids(ticketId));
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice With asks paused no new ask is taken, while the tickets already out still end: a receipt lands, an ask
    ///         for a receipt goes out, and a cancel passes.
    function test_askToMove_reverts_when_asksArePaused() public {
        bytes32 answered = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);
        bytes32 unanswered = _requestValidation(address(aliceIdentity), aliceSat, charlieSat, 1, 10);

        vm.expectEmit(false, false, false, true, address(boundCompliance));
        emit EventsLib.AsksPausedSet(true);
        vm.prank(deployer);
        boundCompliance.setAsksPaused(true);
        assertTrue(boundCompliance.areAsksPaused());

        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.AsksPaused.selector);
        boundCompliance.askToMove(aliceSat, charlieSat, 1, 10, "", _salt());

        polygonBridge.relay(_liteSettles(polygonBridge, token, _settlement(answered, aliceSat, charlieSat, 10)));
        _cancelUnanswered(unanswered, charlieSat, "");

        assertEq(uint8(boundCompliance.statusOf(answered)), uint8(ITickets.TicketStatus.Done));
        assertEq(uint8(boundCompliance.statusOf(unanswered)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /* ----- Helpers ----- */

    function _setLimits(uint32 openTicketsPerIdentity, uint32 asksPerWindow, uint256 smallestAmount) private {
        ITickets.AskLimits memory limits = ITickets.AskLimits({
            openTicketsPerIdentity: openTicketsPerIdentity,
            asksPerIdentityPerWindow: asksPerWindow,
            askWindow: ASK_WINDOW,
            smallestAmount: smallestAmount
        });
        vm.prank(deployer);
        boundCompliance.setAskLimits(limits);
    }

    function _ids(bytes32 one) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = one;
    }

}
