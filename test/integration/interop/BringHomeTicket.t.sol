// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC7786Recipient } from "@openzeppelin/contracts/crosschain/ERC7786Recipient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";

import { SecondHalvesSuiteTest } from "test/integration/helpers/SecondHalvesSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import { NativeLedgerModule, RecordingModule, TrackerOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A bring home is a ticket whose first half is home's: it reserves the away wallet, is bounded by what is free
///      there, one at a time per wallet, and its receipt mints at home what was burned, or sends it back to the away
///      wallet when the home wallet is no longer the identity's.
contract BringHomeTicketTest is SecondHalvesSuiteTest {

    uint256 internal constant BROUGHT = 300;
    uint256 internal constant FREE_AFTER_IT = ALICE_ON_A - BROUGHT;

    /* ----- The ask ----- */

    function test_bringHome_reservesTheAwayWallet() public {
        bytes32 id = _bringHome(BROUGHT);

        ITickets.Ticket memory ticket = boundCompliance.ticketOf(id);
        assertEq(token.reservedOf(aliceOnA), BROUGHT);
        assertEq(token.availableOf(aliceOnA), FREE_AFTER_IT);
        assertEq(uint8(ticket.status), uint8(ITickets.TicketStatus.Open));
        assertEq(uint8(ticket.kind), uint8(ITickets.TicketKind.BRING_HOME));
        assertEq(ticket.homeWallet, alice);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A, "nothing moves before the receipt");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BringHomeAlreadyOpen.selector, keccak256(aliceOnA), id));
        boundCompliance.bringHome(aliceOnA, 1, alice, _salt());
    }

    function test_askToMove_reverts_when_itWouldSpendTokensABringHomeReserved() public {
        _bringHome(BROUGHT);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceOnA, FREE_AFTER_IT, FREE_AFTER_IT + 1)
        );
        boundCompliance.askToMove(aliceOnA, bobOnA, FREE_AFTER_IT + 1, FREE_AFTER_IT + 1, "", _salt());

        _requestValidation(address(aliceIdentity), aliceOnA, bobOnA, FREE_AFTER_IT, FREE_AFTER_IT);
        assertEq(token.availableOf(aliceOnA), 0);
    }

    /// @notice A bring home reserves its amount, so a ticket asked later cannot overtake it: the ticket gets what is
    ///         free, the away token executes it first, and the bring home still burns its whole amount.
    function test_askToMove_cannotOvertakeAnEarlierBringHome_whenTheAwayTokenExecutesTheTicketFirst() public {
        bytes32 bringHomeId = _bringHome(BROUGHT);
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceOnA, bobOnA, FREE_AFTER_IT, FREE_AFTER_IT);

        _aSendsTheTicketsReceipt(ticketId, bobOnA, FREE_AFTER_IT);
        _deliver(polygonGateway, _burned(bringHomeId, 1, BROUGHT));

        _assertStatus(ticketId, ITickets.TicketStatus.Done);
        _assertStatus(bringHomeId, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT, "the whole bring home landed");
        assertEq(token.awayBalanceOf(aliceOnA), 0);
        assertEq(token.awayBalanceOf(bobOnA), FREE_AFTER_IT);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        _assertTotalOwned();
    }

    function test_bringHome_givesTheSameId_whenTheSameRequestIsMinedInAnotherBlock() public {
        bytes32 salt = keccak256("bring home salt");
        uint256 beforeTheBlock = vm.snapshotState();
        vm.prank(agent);
        bytes32 idInTheFirstBlock = boundCompliance.bringHome(aliceOnA, BROUGHT, alice, salt);

        vm.revertToState(beforeTheBlock);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        vm.prank(agent);
        bytes32 idInTheNextBlock = boundCompliance.bringHome(aliceOnA, BROUGHT, alice, salt);
        assertEq(idInTheNextBlock, idInTheFirstBlock, "the id is the request's");

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.BringHomeAlreadyOpen.selector, keccak256(aliceOnA), idInTheNextBlock)
        );
        boundCompliance.bringHome(aliceOnA, BROUGHT, alice, salt);

        uint256 nothingBurned = 0;
        _deliver(polygonGateway, _burned(idInTheNextBlock, 1, nothingBurned));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TicketAlreadyWritten.selector, idInTheNextBlock));
        boundCompliance.bringHome(aliceOnA, BROUGHT, alice, salt);
    }

    /* ----- Refusals ----- */

    function test_bringHome_reverts_when_theAwayWalletIsAHomeWallet() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, aliceHome));
        boundCompliance.bringHome(aliceHome, BROUGHT, alice, _salt());
    }

    function test_bringHome_reverts_while_aHostilePeerChangeRuns() public {
        vm.prank(deployer);
        token.replaceHostilePeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("replacementPeer")));
        uint64 endsAt = token.hostileChangeEndsAt(polygon);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.HostileChangeNotOver.selector, polygon, endsAt));
        boundCompliance.bringHome(aliceOnA, BROUGHT, alice, _salt());
    }

    function test_bringHome_reverts_when_theAwayChainHasNoWaitingTime() public {
        uint256 base = 8453;
        bytes32 baseKey = _evmChainKey(base);
        _openEvmChain(token, base, address(_newReceiptBridge(base)));
        bytes memory aliceOnBase = _linkSatelliteWallet(aliceIdentity, base, makeAccount("aliceOnBase"));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WaitingTimeNotSet.selector, baseKey));
        boundCompliance.bringHome(aliceOnBase, BROUGHT, alice, _salt());
    }

    function test_bringHome_reverts_when_theHomeWalletIsNotLinkedToAnyIdentity() public {
        address stranger = makeAddr("stranger");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletsNotLinked.selector, stranger, aliceOnA));
        boundCompliance.bringHome(aliceOnA, BROUGHT, stranger, _salt());

        assertEq(token.reservedOf(aliceOnA), 0, "nothing reserved");
    }

    /// @notice A bring home counts as one of the identity's open tickets and gives it back at its end.
    function test_bringHome_countsOneOpenTicket_andGivesItBackAtItsEnd() public {
        ITickets.AskLimits memory oneOpenTicket = _askLimits();
        oneOpenTicket.openTicketsPerIdentity = 1;
        vm.prank(deployer);
        boundCompliance.setAskLimits(oneOpenTicket);
        bytes32 id = _bringHome(BROUGHT);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TooManyOpenTickets.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceOnA, bobOnA, 1, 1, "", _salt());

        _deliver(polygonGateway, _burned(id, 1, BROUGHT));
        _requestValidation(address(aliceIdentity), aliceOnA, bobOnA, 1, 1);
    }

    function test_blockAwayChain_reverts_when_theBoundTokenCallsIt() public {
        vm.prank(address(token));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(token)));
        boundCompliance.blockAwayChain(polygon);
    }

    /* ----- The receipt ----- */

    function test_receiveReceipt_mintsAtHomeAndTellsTheTrackersOnce_whenTheWholeAmountIsBurned() public {
        TrackerOnlyModule tracker = _bindTracker();
        bytes32 id = _bringHome(BROUGHT);
        uint256 index = _liteSettles(polygonGateway, token, _burned(id, 1, BROUGHT));

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(0), alice, BROUGHT);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledToNative(keccak256(aliceOnA), alice, id, aliceOnA, BROUGHT);
        polygonGateway.relay(index);

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.totalSupply(), MINTED, "the supply never moves");
        assertEq(token.reservedOf(aliceOnA), 0);
        assertEq(tracker.transferActionCalls(), 1, "told once");
        (,,, bytes32 fromWallet, bytes32 toWallet,,, uint8 kind,,,) = tracker.lastContext();
        assertEq(kind, MovementKindLib.RECALL);
        assertEq(fromWallet, WalletKeyLib.walletId(alice), "the home wallet on both sides");
        assertEq(toWallet, WalletKeyLib.walletId(alice));
        _assertTotalOwned();
    }

    function test_receiveReceipt_mintsWhatWasBurned_whenTheAwayTokenBurnedOneLess() public {
        bytes32 id = _bringHome(BROUGHT);

        _deliver(polygonGateway, _burned(id, 1, BROUGHT - 1));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(boundCompliance.ticketOf(id).moved, BROUGHT - 1);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT - 1);
        assertEq(token.reservedOf(aliceOnA), 0);
        _assertTotalOwned();
    }

    /// @notice A half that arrived after its valid until burned nothing: the bring home ends with nothing moved, is
    ///         not sent again, tells nobody, and the wallet may be brought home anew.
    function test_receiveReceipt_endsTheBringHomeWithNothingMoved_whenItsHalfExpired() public {
        TrackerOnlyModule tracker = _bindTracker();
        bytes32 id = _bringHome(BROUGHT);
        uint256 queued = polygonGateway.queueLength();

        _deliver(polygonGateway, _bringHomeReceipt(id, 1, aliceOnA, 0, MessageTypesLib.ReceiptAnswer.Expired));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.reservedOf(aliceOnA), 0, "the reservation is released");
        assertEq(token.awayBalanceOf(aliceOnA), ALICE_ON_A);
        assertEq(polygonGateway.queueLength(), queued + 1, "nothing sent but the receipt itself");
        assertEq(tracker.transferActionCalls(), 0, "a zero bring home tells nobody");
        _bringHome(BROUGHT);
    }

    function test_receiveReceipt_tellsNoTracker_whenNothingWasBurned() public {
        TrackerOnlyModule tracker = _bindTracker();
        bytes32 id = _bringHome(BROUGHT);

        _deliver(polygonGateway, _burned(id, 1, 0));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(tracker.transferActionCalls(), 0);
    }

    /// @notice The home wallet is no longer the identity's verified wallet: what was burned goes on hold and back to
    ///         the away wallet as half 2, a move out; its receipt gives the away wallet its tokens back and tells
    ///         nobody.
    function test_receiveReceipt_sendsTheBurnedAmountBack_whenTheHomeWalletIsNoLongerLinked() public {
        TrackerOnlyModule tracker = _bindTracker();
        bytes32 id = _bringHome(BROUGHT);
        _revokeWallet(aliceIdentity, aliceHome);
        uint256 alicePosition = ledger.positionOf(address(aliceIdentity));
        uint256 index = _liteSettles(polygonGateway, token, _burned(id, 1, BROUGHT));

        vm.expectEmit(true, true, true, true, address(boundCompliance));
        emit EventsLib.SecondHalfSent(id, 2, polygon, aliceOnA, BROUGHT, uint64(block.timestamp) + POLYGON_WINDOW);
        polygonGateway.relay(index);

        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(token.onHoldOf(id), BROUGHT);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A, "nothing minted at home");
        MessageTypesLib.MoveOutMessage memory back = _queuedMoveOut(polygonGateway, _lastIndex(polygonGateway));
        assertEq(back.half, 2);
        assertEq(back.toWallet, aliceOnA);

        _deliver(polygonGateway, _minted(id, 2, aliceOnA, BROUGHT));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(aliceOnA), ALICE_ON_A, "the away wallet has it back");
        assertEq(ledger.positionOf(address(aliceIdentity)), alicePosition, "positions unchanged");
        assertEq(tracker.transferActionCalls(), 0, "a return tells nobody");
        _assertTotalOwned();
    }

    /// @notice Frozen stops onward movement; it does not strand what the away token already burned.
    function test_receiveReceipt_mintsAtHome_whenTheHomeWalletIsFrozen() public {
        bytes32 id = _bringHome(BROUGHT);
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        _deliver(polygonGateway, _burned(id, 1, BROUGHT));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT);
    }

    /// @notice A receipt for a bring home id home never wrote stops nothing and blocks nobody.
    function test_receiveReceipt_stopsNothing_whenTheBringHomeIdIsUnknown() public {
        bytes32 unknownId = keccak256("never written");
        uint256 index = _liteSettles(polygonGateway, token, _burned(unknownId, 1, BROUGHT));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptUnknown(MessageTypesLib.halfKeyOf(unknownId, 1), polygon);
        polygonGateway.relay(index);

        assertFalse(token.paused());
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /* ----- Bad receipts: each refused, the away chain blocked, nothing moved ----- */

    function test_receiveReceipt_refusesABringHomeReceipt_forHalfZero() public {
        bytes32 id = _bringHome(BROUGHT);

        _assertRefused(id, _burned(id, 0, BROUGHT));
    }

    function test_receiveReceipt_refusesABringHomeReceipt_whenItNamesAReceiver() public {
        bytes32 id = _bringHome(BROUGHT);
        MessageTypesLib.ReceiptMessage memory receipt = _burned(id, 1, BROUGHT);
        receipt.to = aliceHome;

        _assertRefused(id, receipt);
    }

    function test_receiveReceipt_refusesAMoveOutShapedReceipt_whileTheBringHomeIsOpen() public {
        bytes32 id = _bringHome(BROUGHT);

        _assertRefused(id, _minted(id, 1, aliceOnA, BROUGHT));
    }

    function test_receiveReceipt_refusesASecondBodyForTheSameHalf() public {
        bytes32 id = _bringHome(BROUGHT);
        _deliver(polygonGateway, _burned(id, 1, BROUGHT));
        uint256 index = _liteSettles(polygonGateway, token, _burned(id, 1, BROUGHT - 1));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, polygon, BROUGHT - 1, bytes32(0));
        polygonGateway.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT, "minted once");
    }

    /* ----- Sending the half again ----- */

    function test_sendSecondHalf_resendsTheBringHomeAtFixedTimes_thenIsNoLongerOwed() public {
        bytes32 id = _bringHome(BROUGHT);
        uint64 validUntil = boundCompliance.ticketOf(id).secondHalfValidUntil;

        vm.warp(validUntil + POLYGON_WINDOW);
        vm.expectEmit(true, true, true, true, address(boundCompliance));
        emit EventsLib.SecondHalfSent(id, 1, polygon, aliceOnA, BROUGHT, validUntil);
        boundCompliance.sendSecondHalf(id, aliceOnA);

        vm.warp(validUntil + 3 * POLYGON_WINDOW);
        boundCompliance.sendSecondHalf(id, aliceOnA);
        assertEq(_queuedBringHome(polygonGateway, _lastIndex(polygonGateway)).half, 1, "the same half");

        vm.warp(validUntil + 10 * POLYGON_WINDOW);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SecondHalfNotOwed.selector, id));
        boundCompliance.sendSecondHalf(id, aliceOnA);
        assertEq(token.reservedOf(aliceOnA), BROUGHT, "still reserved until its receipt");
    }

    function test_sendTicket_reverts_forABringHome() public {
        bytes32 id = _bringHome(BROUGHT);
        vm.warp(block.timestamp + 10 * POLYGON_WINDOW);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationNotResendable.selector, id, uint8(ITickets.TicketStatus.Open))
        );
        boundCompliance.sendTicket(id, aliceHome, "");
    }

    /// @notice The bring home was pinned to a peer the chain replaced as planned. At its due time the same half goes
    ///         again to the former peer that holds it, never a second burn order; its receipt mints at home.
    function test_sendSecondHalf_sendsABringHomePinnedToAReplacedPeerToTheFormerPeer() public {
        bytes32 id = _bringHome(BROUGHT);
        bytes memory formerPeer = token.peerFor(polygon);
        vm.prank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("newPolygonPeer")));
        vm.warp(boundCompliance.ticketOf(id).secondHalfValidUntil + POLYGON_WINDOW);

        boundCompliance.sendSecondHalf(id, aliceOnA);

        assertEq(boundCompliance.ticketOf(id).half, 1, "the same half");
        uint256 lastIndex = polygonGateway.queueLength() - 1;
        assertEq(polygonGateway.queuedMessage(lastIndex).recipient, formerPeer, "to the former peer");
        _deliver(polygonGateway, _burned(id, 1, BROUGHT));
        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT, "minted once at home");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(token.reservedOf(aliceOnA), 0);
    }

    /// @notice A hostile replacement keeps no former pair: once the freeze is over, the pinned bring home is still
    ///         never sent to the new peer, which does not hold it.
    function test_sendSecondHalf_reverts_when_theBringHomesPeerWasReplacedAsHostile() public {
        bytes32 id = _bringHome(BROUGHT);
        vm.prank(deployer);
        token.replaceHostilePeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("replacementPeer")));
        vm.warp(token.hostileChangeEndsAt(polygon) + 1);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PeerChanged.selector, polygon));
        boundCompliance.sendSecondHalf(id, aliceOnA);
        assertEq(boundCompliance.ticketOf(id).half, 1, "no new half");
    }

    /// @notice The bridge the half was pinned to is distrusted: its receipt is refused, and once due the same half
    ///         goes again to the same peer through the chain's new route, whose receipt mints at home.
    function test_sendSecondHalf_sendsTheSameHalfThroughTheNewRoute_whenThePinnedBridgeIsDistrusted() public {
        bytes32 id = _bringHome(BROUGHT);
        uint256 throughTheOldBridge = _liteSettles(polygonGateway, token, _burned(id, 1, BROUGHT));
        trustedGatewayRegistry.setTrustedGateway(address(polygonGateway), false, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7786Recipient.ERC7786RecipientUnauthorizedGateway.selector,
                address(polygonGateway),
                InteroperableAddress.formatEvmV1(POLYGON, address(token))
            )
        );
        polygonGateway.relay(throughTheOldBridge);

        ERC7786GatewayMock newGateway = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(newGateway));
        vm.warp(boundCompliance.ticketOf(id).secondHalfValidUntil + POLYGON_WINDOW);
        boundCompliance.sendSecondHalf(id, aliceOnA);
        assertEq(boundCompliance.ticketOf(id).half, 1, "the same half");
        assertEq(newGateway.queueLength(), 1, "sent through the new route");

        _deliver(newGateway, _burned(id, 1, BROUGHT));
        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT);
    }

    /// @notice The route switched while the half was out: its receipt through the bridge it was pinned to still lands.
    function test_receiveReceipt_landsThroughThePinnedBridge_whenTheRouteSwitchedAfterTheBringHome() public {
        bytes32 id = _bringHome(BROUGHT);
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));

        _deliver(polygonGateway, _burned(id, 1, BROUGHT));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT);
    }

    /* ----- Receipts that wait ----- */

    function test_applyWaitingReceipt_appliesABringHomeReceiptThatWaitedForTheUnpause() public {
        bytes32 id = _bringHome(BROUGHT);
        vm.prank(agent);
        token.pause();
        MessageTypesLib.ReceiptMessage memory receipt = _burned(id, 1, BROUGHT);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(id, 1);
        uint256 index = _liteSettles(polygonGateway, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWaiting(halfKey, polygon, address(polygonGateway), receipt);
        polygonGateway.relay(index);
        _assertStatus(id, ITickets.TicketStatus.Open);

        vm.prank(agent);
        token.unpause();
        boundCompliance.applyWaitingReceipt(halfKey, receipt);

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT);
    }

    function test_applyWaitingReceipt_appliesABringHomeReceiptThatWaitedForTheUnblock() public {
        bytes32 id = _bringHome(BROUGHT);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        MessageTypesLib.ReceiptMessage memory receipt = _burned(id, 1, BROUGHT);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(id, 1);

        _deliver(polygonGateway, receipt);
        _assertStatus(id, ITickets.TicketStatus.Open);

        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        boundCompliance.applyWaitingReceipt(halfKey, receipt);

        _assertStatus(id, ITickets.TicketStatus.Done);
    }

    /* ----- Home reorgs ----- */

    /// @notice Two bring homes in one block mined again in the other order keep their ids: ids come from the request.
    function test_bringHome_keepsItsId_whenAReorgOfNoDepthSwapsTwoBringHomes() public {
        uint256 bobOnAFunds = 200;
        vm.startPrank(agent);
        token.mint(bob, bobOnAFunds);
        TokenLedgerHarness(address(token)).ledgerMoveOut(bob, bobOnA, bobOnAFunds);
        vm.stopPrank();
        bytes32 aliceSalt = keccak256("alice");
        bytes32 bobSalt = keccak256("bob");
        uint256 beforeTheBlock = vm.snapshotState();
        vm.startPrank(agent);
        bytes32 aliceFirst = boundCompliance.bringHome(aliceOnA, BROUGHT, alice, aliceSalt);
        bytes32 bobFirst = boundCompliance.bringHome(bobOnA, bobOnAFunds, bob, bobSalt);
        vm.stopPrank();

        vm.revertToState(beforeTheBlock);
        vm.startPrank(agent);
        bytes32 bobSecond = boundCompliance.bringHome(bobOnA, bobOnAFunds, bob, bobSalt);
        bytes32 aliceSecond = boundCompliance.bringHome(aliceOnA, BROUGHT, alice, aliceSalt);
        vm.stopPrank();

        assertEq(aliceSecond, aliceFirst);
        assertEq(bobSecond, bobFirst);
    }

    /// @notice A reorg of k blocks or fewer drops the bring home after the away token burned for it; mined again a few
    ///         blocks later it takes the same id, and the away token's receipt for the first copy mints at home.
    function test_receiveReceipt_appliesToTheBringHomeMinedAgain_afterAShallowReorg() public {
        bytes32 salt = keccak256("bring home salt");
        uint256 beforeTheReorg = vm.snapshotState();
        vm.prank(agent);
        bytes32 firstCopy = boundCompliance.bringHome(aliceOnA, BROUGHT, alice, salt);

        vm.revertToState(beforeTheReorg);
        vm.roll(block.number + 3);
        vm.warp(block.timestamp + 36);
        vm.prank(agent);
        bytes32 minedAgain = boundCompliance.bringHome(aliceOnA, BROUGHT, alice, salt);
        assertEq(minedAgain, firstCopy);

        _deliver(polygonGateway, _burned(firstCopy, 1, BROUGHT));

        _assertStatus(minedAgain, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    /// @notice A reorg deeper than k drops the bring home while its receipt is already home: the receipt answers an id
    ///         home has no record of, stops nothing and is not kept. Mined again under the same id, the away token's
    ///         repeated answer lands and mints at home.
    function test_receiveReceipt_appliesTheRepeatedAnswer_afterADeepReorgDroppedTheBringHome() public {
        bytes32 salt = keccak256("bring home salt");
        uint256 beforeTheReorg = vm.snapshotState();
        vm.prank(agent);
        bytes32 droppedId = boundCompliance.bringHome(aliceOnA, BROUGHT, alice, salt);

        vm.revertToState(beforeTheReorg);
        vm.roll(block.number + 100);
        uint256 early = _liteSettles(polygonGateway, token, _burned(droppedId, 1, BROUGHT));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptUnknown(MessageTypesLib.halfKeyOf(droppedId, 1), polygon);
        polygonGateway.relay(early);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));

        vm.prank(agent);
        bytes32 minedAgain = boundCompliance.bringHome(aliceOnA, BROUGHT, alice, salt);
        assertEq(minedAgain, droppedId);
        _deliver(polygonGateway, _burned(droppedId, 1, BROUGHT));

        _assertStatus(minedAgain, ITickets.TicketStatus.Done);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A + BROUGHT);
    }

    /* ----- Modules that keep a ledger of their own ----- */

    /// @notice A module keeping its own record of home balances follows a move out and the bring home back without
    ///         being reseeded: the move out debits it, the bring home credits it.
    function test_receiveReceipt_letsAHomeLedgerModuleFollowTheRoundTrip() public {
        NativeLedgerModule module = _bindNativeLedger();
        bytes32 bobKey = WalletKeyLib.walletId(bob);
        uint256 bobMinted = 500;
        uint256 movedOut = 300;
        vm.prank(agent);
        token.mint(bob, bobMinted);
        vm.prank(bob);
        bytes32 moveOutId = boundCompliance.askToMove(bobHome, bobOnA, movedOut, movedOut, "", _salt());
        _deliver(polygonGateway, _minted(moveOutId, 1, bobOnA, movedOut));
        assertEq(module.recorded(bobKey), bobMinted - movedOut, "the move out debited the record");

        vm.prank(agent);
        bytes32 bringHomeId = boundCompliance.bringHome(bobOnA, movedOut, bob, _salt());
        _deliver(
            polygonGateway, _bringHomeReceipt(bringHomeId, 1, bobOnA, movedOut, MessageTypesLib.ReceiptAnswer.Executed)
        );

        assertEq(token.balanceOf(bob), bobMinted);
        assertEq(module.recorded(bobKey), token.balanceOf(bob), "the record equals the live balance");
    }

    /// @notice A cap kept in a module's own ledger holds across the away chain: Charlie moves out, hands the tokens to
    ///         Bob on A, Bob brings them home, and the module counted what landed on him, so a mint over the cap is
    ///         refused.
    function test_receiveReceipt_keepsAHomeLedgerCap_throughTheAwayChain() public {
        NativeLedgerModule module = _bindNativeLedger();
        uint256 cap = 150;
        uint256 moved = 100;
        module.setCap(cap);
        bytes32 bobKey = WalletKeyLib.walletId(bob);
        bytes memory charlieHome = InteroperableAddress.formatEvmV1(block.chainid, charlie);
        bytes memory charlieOnA = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        vm.prank(agent);
        token.mint(charlie, moved);
        vm.prank(charlie);
        bytes32 moveOutId = boundCompliance.askToMove(charlieHome, charlieOnA, moved, moved, "", _salt());
        _deliver(polygonGateway, _minted(moveOutId, 1, charlieOnA, moved));
        bytes32 ticketId = _requestValidation(address(charlieIdentity), charlieOnA, bobOnA, moved, moved);
        _deliver(polygonGateway, _settlement(ticketId, charlieOnA, bobOnA, moved));
        vm.prank(agent);
        bytes32 bringHomeId = boundCompliance.bringHome(bobOnA, moved, bob, _salt());

        _deliver(
            polygonGateway, _bringHomeReceipt(bringHomeId, 1, bobOnA, moved, MessageTypesLib.ReceiptAnswer.Executed)
        );

        assertEq(module.recorded(bobKey), moved, "the bring home credited Bob's record");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(NativeLedgerModule.CapExceeded.selector, bobKey, 2 * moved, cap));
        token.mint(bob, moved);
    }

    /* ----- Inbound types ----- */

    /// @notice The retired burn proof code no longer decodes: its delivery reverts without data.
    function test_receiveMessage_reverts_forTheRetiredBurnProofCode() public {
        uint8 retiredBurnProof = 4;
        bytes memory payload = abi.encode(retiredBurnProof, MessageTypesLib.VERSION, abi.encode(uint256(1)));
        uint256 index = _liteSends(polygonGateway, token, payload);

        vm.expectRevert(bytes(""));
        polygonGateway.relay(index);
    }

    /* ----- Helpers ----- */

    function _bringHome(uint256 amount) private returns (bytes32) {
        vm.prank(agent);
        return boundCompliance.bringHome(aliceOnA, amount, alice, _salt());
    }

    /// @dev The receipt of a bring home half that burned `amount` from Alice's wallet on A.
    function _burned(bytes32 id, uint8 half, uint256 amount)
        private
        view
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return _bringHomeReceipt(id, half, aliceOnA, amount, MessageTypesLib.ReceiptAnswer.Executed);
    }

    /// @dev A sends `receipt`: refused, A blocked, the bring home still open and reserved.
    function _assertRefused(bytes32 id, MessageTypesLib.ReceiptMessage memory receipt) private {
        uint256 index = _liteSettles(polygonGateway, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, polygon, receipt.amount, bytes32(0));
        polygonGateway.relay(index);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "A is blocked");
        _assertStatus(id, ITickets.TicketStatus.Open);
        assertEq(token.reservedOf(aliceOnA), BROUGHT, "still reserved");
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A, "nothing minted");
    }

    function _bindNativeLedger() private returns (NativeLedgerModule module) {
        module = NativeLedgerModule(
            address(new ModuleProxy(address(new NativeLedgerModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(module));
    }

}
