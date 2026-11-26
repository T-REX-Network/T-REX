// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Waiting receipts and the block of an away chain. A good receipt that cannot be applied yet waits at home,
///      tagged with the bridge and peer that brought it; anyone applies it later, after the route check runs again
///      on that tag; the pauser may refuse it while its away chain is blocked; and a cancel never races it.
contract WaitingReceiptsTest is InteropSuiteTest {

    uint256 internal constant ALICE_AWAY_BALANCE = 1000;

    ERC7786GatewayMock internal polygonBridge;
    bytes internal aliceOnPolygon;
    bytes internal bobOnPolygon;
    address internal backend = makeAddr("institutionBackend");
    address internal anyone = makeAddr("anyone");

    function setUp() public override {
        super.setUp();
        polygonBridge = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(polygonBridge));
        aliceOnPolygon =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_AWAY_BALANCE);
        bobOnPolygon = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        // A copy from a dropped home block carries at most the per-ticket cap of its away chain.
        vm.prank(deployer);
        boundCompliance.setTicketLimits(polygon, ALICE_AWAY_BALANCE, ALICE_AWAY_BALANCE);
        vm.prank(agent);
        token.unpause();
    }

    /* ----- The route check runs again ----- */

    /// @notice A receipt kept waiting for a ticket not sent yet came through a bridge that was distrusted before
    ///         the ticket was sent: applying it later runs the route check again on that bridge and refuses it.
    function test_applyWaitingReceipt_reverts_when_theBridgeWasDistrustedMeanwhile() public {
        AsyncApprovalModule approval = _bindApprovalModule();
        (bytes32 ticketId, MessageTypesLib.ReceiptMessage memory receipt) = _receiptWaitingForApproval();
        trustedGatewayRegistry.distrustBridge(address(polygonBridge));
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));
        _approve(approval, ticketId);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAReceiptBridge.selector, address(polygonBridge)));
        boundCompliance.applyWaitingReceipt(ticketId, receipt);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open), "nothing applied");
        assertEq(token.awayBalanceOf(bobOnPolygon), 0);
    }

    /// @notice The incident path: receipts from a suspect bridge wait under the block; the bridge is distrusted and
    ///         the route moved before the unblock, so none of them can be applied afterwards, by anyone.
    function test_applyWaitingReceipt_reverts_when_theBridgeWasDistrustedWhileTheChainWasBlocked() public {
        bytes32 ticketId = _ask(10, 50);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        MessageTypesLib.ReceiptMessage memory receipt = _receipt(ticketId, 40);
        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));

        trustedGatewayRegistry.distrustBridge(address(polygonBridge));
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAReceiptBridge.selector, address(polygonBridge)));
        boundCompliance.applyWaitingReceipt(ticketId, receipt);
    }

    /// @notice A waiting receipt is not applied once the receipt route of its away chain was closed.
    function test_applyWaitingReceipt_reverts_when_theReceiptRouteWasClosed() public {
        AsyncApprovalModule approval = _bindApprovalModule();
        (bytes32 ticketId, MessageTypesLib.ReceiptMessage memory receipt) = _receiptWaitingForApproval();
        _approve(approval, ticketId);
        _closeEvmChain(token, POLYGON);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.applyWaitingReceipt(ticketId, receipt);
    }

    /// @notice A receipt that came from the chain's current peer is refused once that peer was replaced: it was
    ///         neither the pinned peer nor the current one any more.
    function test_applyWaitingReceipt_reverts_when_thePeerWasReplacedMeanwhile() public {
        AsyncApprovalModule approval = _bindApprovalModule();
        (bytes32 ticketId, MessageTypesLib.ReceiptMessage memory receipt) = _receiptWaitingForApproval();
        vm.prank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("newPolygonLite")));
        _approve(approval, ticketId);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PeerChanged.selector, polygon));
        boundCompliance.applyWaitingReceipt(ticketId, receipt);
    }

    /// @notice The caller gives the receipt back; any byte other than the one that waits is refused.
    function test_applyWaitingReceipt_reverts_when_theReceiptIsNotTheOneWaiting() public {
        bytes32 ticketId = _ask(10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWaitingUnderABlock(ticketId, 40);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        receipt.amount = 41;

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NoWaitingReceipt.selector, ticketId));
        boundCompliance.applyWaitingReceipt(ticketId, receipt);
    }

    /* ----- Why a receipt waits ----- */

    /// @notice A receipt the sender's away balance no longer covers waits rather than reverting at the bridge, and
    ///         is applied once the balance covers it again.
    function test_receiveReceipt_waits_whenTheAwayBalanceIsTooLow() public {
        bytes32 ticketId = _ask(10, 50);
        _bringEverythingHome();
        MessageTypesLib.ReceiptMessage memory receipt = _receipt(ticketId, 40);
        uint256 index = _liteSettles(polygonBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWaiting(ticketId, polygon, address(polygonBridge), receipt);
        polygonBridge.relay(index);
        assertTrue(token.messageReceived(address(polygonBridge), polygonBridge.receiveIdFor(index)), "consumed");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, aliceOnPolygon, 0, 40));
        boundCompliance.applyWaitingReceipt(ticketId, receipt);

        _fundAliceOnPolygonAgain(40);
        boundCompliance.applyWaitingReceipt(ticketId, receipt);
        assertEq(token.awayBalanceOf(bobOnPolygon), 40);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
    }

    /// @notice Another body for a half whose receipt waits is a bad receipt: refused, and its chain stays blocked.
    function test_receiveReceipt_refusesAnotherBody_whenAReceiptWaitsForTheHalf() public {
        bytes32 ticketId = _ask(10, 50);
        _receiptWaitingUnderABlock(ticketId, 40);
        MessageTypesLib.ReceiptMessage memory another = _receipt(ticketId, 45);

        uint256 index = _liteSettles(polygonBridge, token, another);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(ticketId, polygon, 45, another.askBlockHash);
        polygonBridge.relay(index);

        assertEq(boundCompliance.waitingReceiptOf(ticketId).amount, 40, "the first receipt still waits");
    }

    /* ----- A repeat of a waiting receipt ----- */

    /// @notice A receipt kept waiting for its ticket to be sent, delivered again once it was sent, is applied by
    ///         that repeat instead of being dropped as a duplicate.
    function test_receiveReceipt_appliesTheWaitingReceipt_whenItsRepeatCanNowBePlaced() public {
        AsyncApprovalModule approval = _bindApprovalModule();
        (bytes32 ticketId, MessageTypesLib.ReceiptMessage memory receipt) = _receiptWaitingForApproval();
        _approve(approval, ticketId);
        uint256 repeat = _liteSettles(polygonBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptApplied(ticketId, polygon);
        polygonBridge.relay(repeat);

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobOnPolygon), 40);
        assertEq(boundCompliance.waitingReceiptOf(ticketId).bodyHash, bytes32(0), "taken off the shelf");
    }

    /// @notice A repeat while the chain is still blocked changes nothing: the receipt keeps waiting.
    function test_receiveReceipt_isADuplicate_whenTheWaitingReceiptStillCannotBePlaced() public {
        bytes32 ticketId = _ask(10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWaitingUnderABlock(ticketId, 40);
        uint256 repeat = _liteSettles(polygonBridge, token, receipt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptDuplicate(ticketId, polygon);
        polygonBridge.relay(repeat);

        assertEq(boundCompliance.waitingReceiptOf(ticketId).amount, 40, "still waiting");
        assertEq(token.awayBalanceOf(bobOnPolygon), 0);
    }

    /* ----- Refuse a waiting receipt ----- */

    /// @notice The pauser drops a waiting receipt while its chain is blocked. No hash was written for the half, so
    ///         the honest receipt for it still lands once the block is lifted.
    function test_refuseWaitingReceipt_dropsTheWaitingReceipt() public {
        bytes32 ticketId = _ask(10, 50);
        _receiptWaitingUnderABlock(ticketId, 45);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.WaitingReceiptRefused(ticketId);
        vm.prank(agent);
        boundCompliance.refuseWaitingReceipt(ticketId);
        assertEq(boundCompliance.waitingReceiptOf(ticketId).bodyHash, bytes32(0));

        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        polygonBridge.relay(_liteSettles(polygonBridge, token, _receipt(ticketId, 40)));
        assertEq(token.awayBalanceOf(bobOnPolygon), 40, "the honest receipt is applied");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    function test_refuseWaitingReceipt_reverts_when_theAwayChainIsNotBlocked() public {
        bytes32 ticketId = _ask(10, 50);
        _receiptWaitingUnderABlock(ticketId, 40);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainNotBlocked.selector, polygon));
        boundCompliance.refuseWaitingReceipt(ticketId);
    }

    function test_refuseWaitingReceipt_reverts_when_nothingWaits() public {
        bytes32 ticketId = _ask(10, 50);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NoWaitingReceipt.selector, ticketId));
        boundCompliance.refuseWaitingReceipt(ticketId);
    }

    function test_refuseWaitingReceipt_reverts_when_theCallerIsNotThePauser() public {
        bytes32 ticketId = _ask(10, 50);
        _receiptWaitingUnderABlock(ticketId, 40);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, anyone));
        boundCompliance.refuseWaitingReceipt(ticketId);
    }

    /* ----- Cancel and the waiting receipt ----- */

    /// @notice Once the block is lifted, a cancel is refused while the receipt for the ticket waits and can be
    ///         applied: whoever wants the ticket to move on applies it.
    function test_cancelTickets_reverts_when_aReceiptForTheTicketIsWaitingAndApplicable() public {
        bytes32 ticketId = _ask(10, 50);
        MessageTypesLib.ReceiptMessage memory receipt = _receiptWaitingUnderABlock(ticketId, 40);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        _warpPastThePublicCancel(ticketId);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApplyWaitingReceiptFirst.selector, ticketId, polygon));
        boundCompliance.cancelTickets(_ids(ticketId));

        vm.prank(anyone);
        boundCompliance.applyWaitingReceipt(ticketId, receipt);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
    }

    /// @notice A waiting receipt nobody can apply, here one from a bridge distrusted before the unblock, does not
    ///         hold the cancel: it would lock the ticket open for good.
    function test_cancelTickets_succeeds_when_theWaitingReceiptCannotBeApplied() public {
        bytes32 ticketId = _ask(10, 50);
        _receiptWaitingUnderABlock(ticketId, 40);
        trustedGatewayRegistry.distrustBridge(address(polygonBridge));
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        _warpPastThePublicCancel(ticketId);

        vm.prank(anyone);
        boundCompliance.cancelTickets(_ids(ticketId));

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Cancelled));
        assertEq(token.reservedOf(aliceOnPolygon), 0, "the reservation comes back");
    }

    /// @notice A waiting receipt the sender's away balance no longer covers cannot be applied, so it does not hold
    ///         the cancel either.
    function test_cancelTickets_succeeds_when_theAwayBalanceNoLongerCoversTheWaitingReceipt() public {
        bytes32 ticketId = _ask(10, 50);
        _bringEverythingHome();
        polygonBridge.relay(_liteSettles(polygonBridge, token, _receipt(ticketId, 40)));
        _warpPastThePublicCancel(ticketId);

        vm.prank(anyone);
        boundCompliance.cancelTickets(_ids(ticketId));

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /// @notice A receipt that waits on a receipt route since closed does not hold the cancel: it came through a
    ///         bridge that is neither the half's pinned one nor the chain's current one any more.
    function test_cancelTickets_isNotHeld_byAWaitingReceiptOnAClosedRoute() public {
        bytes32 ticketId = _ask(10, 50);
        ERC7786GatewayMock secondBridge = _newReceiptBridge(POLYGON);
        _openEvmChain(token, POLYGON, address(secondBridge));
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        secondBridge.relay(_liteSettles(secondBridge, token, _receipt(ticketId, 40)));
        _closeEvmChain(token, POLYGON);
        _openEvmChain(token, POLYGON, address(_newReceiptBridge(POLYGON)));
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        _warpPastThePublicCancel(ticketId);

        vm.prank(anyone);
        boundCompliance.cancelTickets(_ids(ticketId));

        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Cancelled));
    }

    /* ----- Cancel under a block or a stop ----- */

    /// @notice A ticket waiting for approval is not cancelled while its away chain is blocked: its receipt may be
    ///         waiting at home.
    function test_cancelTickets_reverts_when_theAwayChainIsBlocked_forATicketWaitingForApproval() public {
        _bindApprovalModule();
        bytes32 ticketId = _ask(10, 50);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        vm.warp(boundCompliance.ticketOf(ticketId).validUntil + 1);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.cancelTickets(_ids(ticketId));
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.WaitingForApproval));
    }

    /// @notice The same holds for a stop of the token.
    function test_cancelTickets_reverts_when_theTokenIsStopped_forATicketWaitingForApproval() public {
        _bindApprovalModule();
        bytes32 ticketId = _ask(10, 50);
        vm.prank(agent);
        token.pause();
        vm.warp(boundCompliance.ticketOf(ticketId).validUntil + 1);

        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.cancelTickets(_ids(ticketId));
    }

    /// @notice The control: a sent ticket is not cancelled under the block either.
    function test_cancelTickets_reverts_when_theAwayChainIsBlocked_forASentTicket() public {
        bytes32 ticketId = _ask(10, 50);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        _warpPastThePublicCancel(ticketId);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        boundCompliance.cancelTickets(_ids(ticketId));
    }

    /* ----- Block an away chain ----- */

    /// @notice The pauser blocks and unblocks an away chain on the compliance; the token's route stays open.
    function test_blockAwayChain_blocksOnlyTheReceiptsOfThatChain() public {
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertFalse(boundCompliance.isAwayChainBlocked(optimism));
        assertTrue(token.isChainOpen(polygon), "the route is not touched");
    }

    function test_blockAwayChain_reverts_when_theCallerIsNotThePauser() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, deployer));
        boundCompliance.blockAwayChain(polygon);
    }

    /* ----- Helpers ----- */

    function _ask(uint256 amountMin, uint256 requestedMax) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceOnPolygon, bobOnPolygon, amountMin, requestedMax);
    }

    /// @dev The receipt of the copy home sent, as the away token reports it.
    function _receipt(bytes32 ticketId, uint256 amount) private view returns (MessageTypesLib.ReceiptMessage memory) {
        return _settlement(ticketId, aliceOnPolygon, bobOnPolygon, amount);
    }

    /// @dev Blocks Polygon, then delivers a receipt for the ticket through its bridge: it waits.
    function _receiptWaitingUnderABlock(bytes32 ticketId, uint256 amount)
        private
        returns (MessageTypesLib.ReceiptMessage memory receipt)
    {
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
        receipt = _receipt(ticketId, amount);
        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));
        assertEq(boundCompliance.waitingReceiptOf(ticketId).amount, amount, "the receipt waits");
    }

    /// @dev An ask waiting for approval, and the receipt of a copy from a dropped home block that executed it,
    ///      delivered through the Polygon bridge: it waits for the ticket to be sent.
    function _receiptWaitingForApproval()
        private
        returns (bytes32 ticketId, MessageTypesLib.ReceiptMessage memory receipt)
    {
        ticketId = _ask(10, 50);
        receipt = _settlementUnder(ticketId, aliceOnPolygon, bobOnPolygon, 40, keccak256("a dropped copy"));
        receipt.seenMax = 50;
        polygonBridge.relay(_liteSettles(polygonBridge, token, receipt));
        assertEq(boundCompliance.waitingReceiptOf(ticketId).amount, 40, "the receipt waits for the ticket");
    }

    function _bindApprovalModule() private returns (AsyncApprovalModule approval) {
        approval = AsyncApprovalModule(
            address(
                new ModuleProxy(
                    address(new AsyncApprovalModule()),
                    abi.encodeCall(AsyncApprovalModule.initialize, (address(suiteManager)))
                )
            )
        );
        address[] memory approvers = new address[](1);
        approvers[0] = backend;
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(AsyncApprovalModule.setApprovers, (approvers));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(approval), settings);
    }

    function _approve(AsyncApprovalModule approval, bytes32 ticketId) private {
        vm.prank(backend);
        approval.approveValidation(address(boundCompliance), ticketId, 50);
        approval.finalize(address(boundCompliance), ticketId);
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Open), "sent");
    }

    /// @dev Brings Alice's whole away balance home through a recall the away token answers.
    function _bringEverythingHome() private {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(aliceOnPolygon, ALICE_AWAY_BALANCE, alice);
        bytes memory proof = MessageTypesLib.encodeBurnProof(_burnProof(recallId, aliceOnPolygon, ALICE_AWAY_BALANCE));
        polygonBridge.relay(_liteSends(polygonBridge, token, proof));
        assertEq(token.awayBalanceOf(aliceOnPolygon), 0);
    }

    function _fundAliceOnPolygonAgain(uint256 amount) private {
        vm.startPrank(alice);
        token.delegateOut(alice, aliceOnPolygon, amount);
        vm.stopPrank();
    }

    function _warpPastThePublicCancel(bytes32 ticketId) private {
        ITickets.Ticket memory issued = boundCompliance.ticketOf(ticketId);
        uint64 waitingTime = issued.waitingEndsAt - issued.validUntil;
        vm.warp(uint256(issued.waitingEndsAt) + waitingTime + 1);
    }

    function _ids(bytes32 ticketId) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = ticketId;
    }

}
