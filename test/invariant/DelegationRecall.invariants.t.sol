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

import { StdInvariant } from "@forge-std/StdInvariant.sol";
import { console } from "@forge-std/console.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev A tracker that counts the moves between chains it is told about: a ticket's move, a home wallet's move out
///  and a bring home. Native moves are counted apart.
contract MoveCountingTracker is RecordingModule {

    uint256 public movesBetweenChainsTold;

    function afterTransfer(TransferContext calldata context) external override onlyComplianceCall {
        bool aTicketsMove = context.kind == MovementKindLib.CROSS_CHAIN;
        bool aMoveOut = context.kind == MovementKindLib.DELEGATION;
        bool aBringHome = context.kind == MovementKindLib.RECALL;
        if (aTicketsMove || aMoveOut || aBringHome) movesBetweenChainsTold++;
        _countAndRecord(context);
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](1);
        types[0] = ModuleType.AFTER;
    }

    function name() external pure override returns (string memory) {
        return "MoveCountingTracker";
    }

}

/// @title DelegationRecallInvariants
/// @notice Stateful check of tickets, home wallets' move outs and bring homes, through the public entry points, with a
///  mock away token that follows `docs/satellite-lite.md` in the loop.
///
/// Three identities, each with a home wallet and one linked wallet on one away chain. The fuzzer mints, transfers at
/// home, moves out of a home wallet, brings home, asks to move from an away wallet to another away wallet or to a home
/// wallet, has the away token execute a ticket, asks for a receipt, cancels, sends a second half again, has the away
/// token send a stored receipt again, and relays or drops queued messages in any order, so tickets, halves, receipts
/// and duplicates interleave. Every delivery that reverts is recorded: a handler step never hides a broken receipt.
///
///   DR-1  positionOf(identity) == home balance + away balance of its wallet + its money on hold (total owned)
///   DR-2  sum of positions == totalSupply()
///   DR-3  totalAwayBalance == away token balances + what is in flight: move outs on hold not minted yet, burns done
///         on the away token whose receipt home has not applied, tickets to a home wallet executed and not applied
///   DR-4  the away token minted exactly the move outs it answered, once each
///   DR-5  what is away is what moved out less what every finished bring home and ticket to a home wallet took home
///   DR-6  an honest away token never blocks its chain or stops the token (no honest chain is blocked)
///   DR-7  no balance or amount on hold below zero: the totals are the sums of their parts, and no wallet has more
///         reserved than its away balance
///   DR-8  the away chain holds no more than home counts away
///   DR-9  every away balance equals home's record plus what is provably in flight
///   DR-10 a total owned falls only through its own requests
///   DR-11 the trackers are told about each move between chains once
///   DR-12 once nothing is left to deliver, every ticket, move out and bring home ends Done or Cancelled
///   DR-13 once nothing is left to deliver, nothing is reserved and nothing is on hold
contract DelegationRecallInvariants is StdInvariant, InteropSuiteTest {

    uint256 internal constant ACTORS = 3;
    uint256 internal constant MAX_AMOUNT = 400;
    /// @dev Rounds the end of a run takes to let everything arrive: each lets every message through, then moves the
    ///  clock past a waiting time so asks for receipts, cancels and halves sent again come due.
    uint256 internal constant DRAIN_ROUNDS = 12;
    /// @dev What each away wallet holds once `setUp` has moved it out from home.
    uint256 internal constant STARTING_AWAY_BALANCE = 300;

    address[] internal actors;
    IIdentity[] internal identities;
    bytes[] internal satellites;
    /// @dev The address behind each away wallet: the one that executes its tickets on the away token.
    address[] internal satelliteSigners;

    ERC7786GatewayMock internal gateway;
    SatelliteLiteMock internal lite;
    IComplianceLedger internal ledger;
    MoveCountingTracker internal tracker;

    /// @dev Every move out asked, with its actor and amount, every bring home written, with its actor, and every
    ///  ticket asked, with its sender, its receiver and whether that receiver is a home wallet. Entry 0 of each is a
    ///  placeholder written in `setUp`, so a state snapshot taken there holds every array slot and a revert to it
    ///  restores them all; the entries start at 1.
    bytes32[] internal moveOutIds;
    uint256[] internal moveOutActor;
    uint256[] internal moveOutAmount;
    bytes32[] internal bringHomeIds;
    uint256[] internal bringHomeActor;
    bytes32[] internal ticketIds;
    uint256[] internal ticketSender;
    uint256[] internal ticketReceiver;
    bool[] internal ticketToHome;
    /// @dev Move outs the end of a run closed by hand, which sends their money back home: no tracker is told.
    mapping(bytes32 ticketId => bool isClosedByHand) internal closedByHand;

    uint256 public callsMoveOut;
    uint256 public callsBringHome;
    uint256 public callsAskTicket;
    uint256 public callsSendAgain;
    uint256 public callsRelay;

    /// @dev The actor a `transfer` step sends from, plus one; zero outside a transfer. Its total owned may fall.
    uint256 internal transferringActor;
    /// @dev Set once a step lowered a total owned that no request of its own explains.
    bool public positionFellWithoutItsRequest;
    /// @dev Deliveries that reverted, and the reason of the last one: a refused receipt must never hide in a step.
    uint256 public revertedDeliveries;
    bytes public lastRevertReason;
    /// @dev Set once a fault a step injected did not take effect.
    bool public anInjectedFaultDidNotHappen;

    /// @dev Checks DR-10 around a step: an identity whose total owned fell must have a request of its own that moved in
    ///  the step, or be the sender of the step's home transfer.
    modifier positionsFallOnlyThroughOwnRequests() {
        uint256[] memory positionsBefore = _positions();
        bytes32[] memory requestsBefore = _requestStatuses();
        _;
        _checkPositionsFell(positionsBefore, requestsBefore);
        transferringActor = 0;
    }

    function setUp() public virtual override {
        super.setUp();
        ledger = IComplianceLedger(address(boundCompliance));
        gateway = _newReceiptBridge(POLYGON);
        lite = new SatelliteLiteMock(POLYGON, address(token), gateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(lite)));
        vm.stopPrank();
        _openEvmChain(token, POLYGON, address(gateway));
        tracker = MoveCountingTracker(
            address(new ModuleProxy(address(new MoveCountingTracker()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(tracker));

        actors = [alice, bob, charlie];
        identities = [aliceIdentity, bobIdentity, charlieIdentity];
        for (uint256 i = 0; i < ACTORS; i++) {
            Account memory signer = makeAccount(string.concat("sat", vm.toString(i)));
            satelliteSigners.push(signer.addr);
            satellites.push(_linkSatelliteWallet(identities[i], POLYGON, signer));
        }

        // The salt counter is written here too, for the same reason: a reorg replays the asks with the salts they had.
        _salt();
        moveOutIds.push(bytes32(0));
        moveOutActor.push(0);
        moveOutAmount.push(0);
        bringHomeIds.push(bytes32(0));
        bringHomeActor.push(0);
        ticketIds.push(bytes32(0));
        ticketSender.push(0);
        ticketReceiver.push(0);
        ticketToHome.push(false);

        vm.startPrank(agent);
        for (uint256 i = 0; i < ACTORS; i++) {
            token.mint(actors[i], 1000);
        }
        token.unpause();
        vm.stopPrank();

        // Each away wallet starts funded by a real move out, minted and landed, so tickets have something to move.
        for (uint256 i = 0; i < ACTORS; i++) {
            moveOut(i, STARTING_AWAY_BALANCE);
        }
        _letEverythingArrive();

        targetContract(address(this));
        targetSelector(FuzzSelector({ addr: address(this), selectors: _targetSelectors() }));
    }

    /// @dev The transitions the fuzzer calls. A suite built on this one appends its own.
    function _targetSelectors() internal view virtual returns (bytes4[] memory selectors) {
        selectors = new bytes4[](12);
        selectors[0] = this.mint.selector;
        selectors[1] = this.transfer.selector;
        selectors[2] = this.moveOut.selector;
        selectors[3] = this.bringHome.selector;
        selectors[4] = this.sendSecondHalfAgain.selector;
        selectors[5] = this.liteResendsReceipt.selector;
        selectors[6] = this.relay.selector;
        selectors[7] = this.drop.selector;
        selectors[8] = this.askTicket.selector;
        selectors[9] = this.awayTokenExecutes.selector;
        selectors[10] = this.askForTheReceipt.selector;
        selectors[11] = this.cancelTicket.selector;
    }

    /* ----- Transitions ----- */

    function mint(uint256 actorSeed, uint256 amount) public virtual positionsFallOnlyThroughOwnRequests {
        vm.prank(agent);
        token.mint(actors[actorSeed % ACTORS], bound(amount, 1, MAX_AMOUNT));
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount)
        public
        virtual
        positionsFallOnlyThroughOwnRequests
    {
        uint256 fromActor = fromSeed % ACTORS;
        address from = actors[fromActor];
        amount = bound(amount, 0, token.balanceOf(from));
        transferringActor = fromActor + 1;
        vm.prank(from);
        try token.transfer(actors[toSeed % ACTORS], amount) { } catch { }
    }

    /// @notice A home wallet moves out to its identity's away wallet: burned onto hold at once, its move out sent.
    function moveOut(uint256 actorSeed, uint256 amount) public virtual positionsFallOnlyThroughOwnRequests {
        callsMoveOut++;
        uint256 actor = actorSeed % ACTORS;
        amount = bound(amount, 1, MAX_AMOUNT);
        bytes memory homeWallet = _homeWalletOf(actor);
        vm.prank(actors[actor]);
        try boundCompliance.askToMove(homeWallet, satellites[actor], amount, amount, "", _salt()) returns (
            bytes32 ticketId
        ) {
            moveOutIds.push(ticketId);
            moveOutActor.push(actor);
            moveOutAmount.push(amount);
        } catch { }
    }

    /// @notice An agent brings an away wallet's tokens home to its identity's home wallet.
    function bringHome(uint256 actorSeed, uint256 amount) public virtual positionsFallOnlyThroughOwnRequests {
        callsBringHome++;
        uint256 actor = actorSeed % ACTORS;
        amount = bound(amount, 1, _mostThatCanLeave(actor));
        vm.prank(agent);
        try boundCompliance.bringHome(satellites[actor], amount, actors[actor], _salt()) returns (bytes32 ticketId) {
            bringHomeIds.push(ticketId);
            bringHomeActor.push(actor);
        } catch { }
    }

    /// @notice An identity asks to move from its away wallet to another identity's away wallet, or to a home wallet.
    function askTicket(uint256 fromSeed, uint256 toSeed, uint256 amount, bool toHome)
        public
        virtual
        positionsFallOnlyThroughOwnRequests
    {
        callsAskTicket++;
        uint256 sender = fromSeed % ACTORS;
        uint256 receiver = toSeed % ACTORS;
        amount = bound(amount, 1, _mostThatCanLeave(sender));
        bytes memory receiverWallet = satellites[receiver];
        if (toHome) receiverWallet = _homeWalletOf(receiver);
        vm.prank(address(identities[sender]));
        try boundCompliance.askToMove(satellites[sender], receiverWallet, 1, amount, "", _salt()) returns (
            bytes32 ticketId
        ) {
            ticketIds.push(ticketId);
            ticketSender.push(sender);
            ticketReceiver.push(receiver);
            ticketToHome.push(toHome);
        } catch { }
    }

    /// @notice The sender executes a ticket the away token holds, for an amount inside its range. The ticket is
    ///  picked among those the away token holds, so the step is not spent on tickets still on their way.
    function awayTokenExecutes(uint256 idSeed, uint256 amountSeed) public virtual positionsFallOnlyThroughOwnRequests {
        (bool found, uint256 index) = _aTicketTheAwayTokenHolds(idSeed);
        if (!found) return;
        bytes32 ticketId = ticketIds[index];
        MessageTypesLib.TicketMessage memory heldCopy = lite.ticketOf(ticketId);
        uint256 amount = bound(amountSeed, heldCopy.amountMin, heldCopy.amountMax);
        address executor = satelliteSigners[ticketSender[index]];
        vm.prank(executor);
        try lite.execute(ticketId, amount) {
            _afterTheAwayTokenExecuted(ticketId, amount, executor);
        } catch { }
    }

    /// @notice Anyone asks for the receipt of an open ticket once it is due.
    function askForTheReceipt(uint256 idSeed) public virtual positionsFallOnlyThroughOwnRequests {
        if (ticketIds.length == 1) return;
        _askForTheReceipt(1 + idSeed % (ticketIds.length - 1));
    }

    /// @notice Anyone cancels an open ticket once an ask for its receipt went unanswered.
    function cancelTicket(uint256 idSeed) public virtual positionsFallOnlyThroughOwnRequests {
        if (ticketIds.length == 1) return;
        _cancel(ticketIds[1 + idSeed % (ticketIds.length - 1)]);
    }

    /// @notice Anyone sends a second half again, or a new one when the last was answered expired.
    function sendSecondHalfAgain(uint256 idSeed, bool aBringHome) public virtual positionsFallOnlyThroughOwnRequests {
        callsSendAgain++;
        uint256 actor;
        bytes32 ticketId;
        if (aBringHome) {
            if (bringHomeIds.length == 1) return;
            uint256 index = 1 + idSeed % (bringHomeIds.length - 1);
            ticketId = bringHomeIds[index];
            actor = bringHomeActor[index];
        } else {
            if (moveOutIds.length == 1) return;
            uint256 index = 1 + idSeed % (moveOutIds.length - 1);
            ticketId = moveOutIds[index];
            actor = moveOutActor[index];
        }
        try boundCompliance.sendSecondHalf(ticketId, satellites[actor]) { } catch { }
    }

    /// @notice The away token sends a stored receipt again, byte for byte.
    function liteResendsReceipt(uint256 idSeed, uint8 halfSeed) external virtual positionsFallOnlyThroughOwnRequests {
        (bool found, bytes32 ticketId) = _anyTicket(idSeed);
        if (!found) return;
        _resendReceipt(ticketId, halfSeed);
    }

    function relay(uint256 indexSeed) external virtual positionsFallOnlyThroughOwnRequests {
        callsRelay++;
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        uint256 index = indexSeed % length;
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(index);
        if (message.deliveries != 0 || message.dropped) return;
        _deliver(index);
    }

    /// @notice The transport loses a message not delivered yet.
    function drop(uint256 indexSeed) public virtual positionsFallOnlyThroughOwnRequests {
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        uint256 index = indexSeed % length;
        if (gateway.queuedMessage(index).deliveries != 0) return;
        gateway.drop(index);
        if (!gateway.queuedMessage(index).dropped) anInjectedFaultDidNotHappen = true;
    }

    /* ----- Invariants ----- */

    function invariant_DR1_positionsFollowTheWallets() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            assertEq(
                ledger.positionOf(address(identities[i])),
                token.balanceOf(actors[i]) + token.awayBalanceOf(satellites[i]) + _onHoldFor(i),
                "DR-1"
            );
        }
    }

    function invariant_DR2_positionsSumToTheSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < ACTORS; i++) {
            sum += ledger.positionOf(address(identities[i]));
        }
        assertEq(sum, token.totalSupply(), "DR-2");
    }

    function invariant_DR3_awayMatchesTheAwayTokenPlusWhatIsInFlight() public view {
        uint256 liteBalances;
        uint256 inFlight;
        for (uint256 i = 0; i < ACTORS; i++) {
            liteBalances += lite.balanceOf(satellites[i]);
            inFlight += _inFlightFor(i);
        }
        assertEq(token.totalAwayBalance(), liteBalances + inFlight, "DR-3");
    }

    function invariant_DR4_theAwayTokenMintedEachMoveOutOnce() public view {
        uint256 minted;
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            if (_mintedOnTheAwayToken(moveOutIds[i])) minted += moveOutAmount[i];
        }
        assertEq(lite.mints(), minted, "DR-4");
    }

    function invariant_DR5_awayIsWhatMovedOutLessWhatCameHome() public view {
        uint256 movedOut;
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            movedOut += moveOutAmount[i];
        }
        uint256 cameHome;
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            ITickets.Ticket memory bringHomeTicket = boundCompliance.ticketOf(bringHomeIds[i]);
            if (bringHomeTicket.status == ITickets.TicketStatus.Done) cameHome += bringHomeTicket.moved;
        }
        for (uint256 i = 1; i < ticketIds.length; i++) {
            if (ticketToHome[i]) cameHome += _movedHomeBy(ticketIds[i]);
        }
        assertEq(token.totalAwayBalance(), movedOut - cameHome, "DR-5");
    }

    function invariant_DR6_anHonestAwayTokenNeverBlocksItsChainOrStopsTheToken() public view {
        assertFalse(token.paused(), "DR-6");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "DR-6");
    }

    function invariant_DR7_noBalanceOrAmountOnHoldBelowZero() public view {
        uint256 awayBalances;
        for (uint256 i = 0; i < ACTORS; i++) {
            uint256 awayBalance = token.awayBalanceOf(satellites[i]);
            awayBalances += awayBalance;
            assertLe(token.reservedOf(satellites[i]), awayBalance, "reserved above the away balance");
        }
        assertEq(awayBalances + token.totalOnHold(), token.totalAwayBalance(), "away total");
        assertEq(_everyHold(), token.totalOnHold(), "on hold total");
    }

    function invariant_DR8_theAwayChainHoldsNoMoreThanHomeCounts() public view {
        uint256 liteBalances;
        for (uint256 i = 0; i < ACTORS; i++) {
            liteBalances += lite.balanceOf(satellites[i]);
        }
        assertLe(liteBalances, token.totalAwayBalance(), "the away chain holds more than home counts");
    }

    /// @dev What the away token holds for a wallet, plus what it moved or burned out of it that home has not applied,
    ///  is home's away balance plus what it moved or minted into it that home has not applied.
    function invariant_DR9_eachAwayBalanceIsHomesRecordPlusWhatIsInFlight() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            uint256 awayTokenSide = lite.balanceOf(satellites[i]) + _leftNotApplied(i);
            uint256 homeSide = token.awayBalanceOf(satellites[i]) + _arrivedNotApplied(i);
            assertEq(awayTokenSide, homeSide, "away balance against home's record plus what is in flight");
        }
    }

    function invariant_DR10_aTotalOwnedFallsOnlyThroughItsOwnRequests() public view {
        assertFalse(positionFellWithoutItsRequest, "a total owned fell without its own request");
    }

    function invariant_DR11_theTrackersAreToldAboutEachMoveOnce() public view {
        assertEq(
            tracker.movesBetweenChainsTold(),
            _movesDone(),
            "the trackers were told a move between chains more or less than once"
        );
    }

    /// @dev A delivery that reverts stays deliverable, so a step that swallowed it would hide a receipt home cannot
    ///  take. None may revert.
    function invariant_noDeliveryReverts() public view {
        assertEq(revertedDeliveries, 0, "a delivery reverted: lastRevertReason holds its reason");
    }

    function invariant_everyInjectedFaultHappened() public view {
        assertFalse(anInjectedFaultDidNotHappen, "a fault the run injected did not take effect");
    }

    function invariant_callSummary() public view {
        console.log("move out calls / landed:", callsMoveOut, moveOutIds.length - 1);
        console.log("bring home calls / landed:", callsBringHome, bringHomeIds.length - 1);
        console.log("ticket calls / landed:", callsAskTicket, ticketIds.length - 1);
        console.log("sends again, relays:", callsSendAgain, callsRelay);
    }

    /// @notice DR-12 and DR-13: at the end of each run every message is let through, the clock moves on and every due ask,
    ///  cancel and half is sent, until nothing is left to deliver. A move out out of new halves is closed by hand, the
    ///  designed way out. Then every request has ended and nothing stays reserved or on hold.
    function afterInvariant() public virtual {
        for (uint256 round = 0; round < DRAIN_ROUNDS; round++) {
            _letEverythingArrive();
            vm.warp(block.timestamp + POLYGON_WINDOW + 1);
            _sendEverythingDue();
        }
        _letEverythingArrive();
        _closeByHandWhatCannotEnd();

        for (uint256 i = 1; i < ticketIds.length; i++) {
            ITickets.TicketStatus status = boundCompliance.ticketOf(ticketIds[i]).status;
            bool ended = status == ITickets.TicketStatus.Done || status == ITickets.TicketStatus.Cancelled;
            assertTrue(ended, "a ticket ended");
        }
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            _assertDone(moveOutIds[i], "a move out ended");
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            _assertDone(bringHomeIds[i], "a bring home ended");
        }
        for (uint256 i = 0; i < ACTORS; i++) {
            assertEq(token.reservedOf(satellites[i]), 0, "nothing reserved");
        }
        assertEq(token.totalOnHold(), 0, "nothing on hold");
        invariant_noDeliveryReverts();
    }

    /* ----- Internal: steps ----- */

    /// @dev A satellite transaction happened; a suite that replays them after a reorg logs it.
    function _afterTheAwayTokenExecuted(bytes32 ticketId, uint256 amount, address executor) internal virtual { }

    /// @dev Delivers a queue entry and records it when it reverts.
    /// @return delivered whether the delivery went through
    function _deliver(uint256 index) internal virtual returns (bool delivered) {
        try gateway.relay(index) {
            delivered = true;
        } catch (bytes memory reason) {
            _noteRevertedDelivery(reason);
        }
    }

    function _noteRevertedDelivery(bytes memory reason) internal {
        revertedDeliveries++;
        lastRevertReason = reason;
    }

    function _askForTheReceipt(uint256 index) internal {
        bytes32 ticketId = ticketIds[index];
        bytes memory receiverWallet = satellites[ticketReceiver[index]];
        if (ticketToHome[index]) receiverWallet = _homeWalletOf(ticketReceiver[index]);
        try boundCompliance.sendTicket(ticketId, receiverWallet, "") { } catch { }
    }

    function _cancel(bytes32 ticketId) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ticketId;
        try boundCompliance.cancelTickets(ids) { } catch { }
    }

    /// @dev Sends the stored receipt of one half of `ticketId` again; a half never answered sends nothing.
    function _resendReceipt(bytes32 ticketId, uint8 halfSeed) internal virtual {
        uint8 latestHalf = boundCompliance.ticketOf(ticketId).half;
        if (latestHalf == 0) return;
        uint8 half = 1 + halfSeed % latestHalf;
        try lite.resendReceipt(ticketId, half) { } catch { }
    }

    /// @dev Has the away token send a stored receipt again, for the end of a run.
    function _resendStoredReceiptAtTheEnd(bytes32 ticketId, uint8 half) internal virtual {
        try lite.resendReceipt(ticketId, half) { } catch { }
    }

    /* ----- Internal: the end of a run ----- */

    /// @dev Delivers every entry not delivered and not dropped, until a pass delivers nothing new.
    function _letEverythingArrive() internal virtual {
        uint256 delivered = 1;
        while (delivered != 0) {
            delivered = 0;
            for (uint256 i = 0; i < gateway.queueLength(); i++) {
                ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(i);
                if (message.deliveries != 0 || message.dropped) continue;
                if (_deliver(i)) delivered++;
            }
        }
    }

    /// @dev Every ask for a receipt, cancel and half that is due goes out. A ticket home cancelled while the away
    ///  token had executed it gets its stored receipt sent again, as a relayer would fetch it.
    function _sendEverythingDue() internal {
        for (uint256 i = 1; i < ticketIds.length; i++) {
            ITickets.TicketStatus status = boundCompliance.ticketOf(ticketIds[i]).status;
            if (status == ITickets.TicketStatus.Open) {
                _askForTheReceipt(i);
                _cancel(ticketIds[i]);
            }
            bool executedThere = lite.storedReceipt(ticketIds[i], 0).amount != 0;
            if (status == ITickets.TicketStatus.Cancelled && executedThere) {
                _resendStoredReceiptAtTheEnd(ticketIds[i], 0);
            }
        }
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            try boundCompliance.sendSecondHalf(moveOutIds[i], satellites[moveOutActor[i]]) { } catch { }
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            try boundCompliance.sendSecondHalf(bringHomeIds[i], satellites[bringHomeActor[i]]) { } catch { }
        }
    }

    /// @dev A move out still on hold once everything arrived has no send left: it is closed by hand on the away
    ///  chain's clock, which sends its money back home.
    function _closeByHandWhatCannotEnd() internal {
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            bytes32 ticketId = moveOutIds[i];
            if (boundCompliance.ticketOf(ticketId).status != ITickets.TicketStatus.OnHold) continue;
            _closeEvmChain(token, POLYGON);
            ITickets.AwayChainReading memory reading;
            reading.blockNumber = uint64(block.number);
            reading.awayClockTime = uint64(block.timestamp);
            vm.prank(deployer);
            boundCompliance.closeByHand(ticketId, satellites[moveOutActor[i]], reading);
            _openEvmChain(token, POLYGON, address(gateway));
            closedByHand[ticketId] = true;
        }
    }

    function _assertDone(bytes32 ticketId, string memory message) internal view {
        assertTrue(boundCompliance.ticketOf(ticketId).status == ITickets.TicketStatus.Done, message);
    }

    /* ----- Internal: reading the state ----- */

    /// @dev The `idSeed`-th ticket, counted round, among those the away token holds unanswered.
    function _aTicketTheAwayTokenHolds(uint256 idSeed) internal view returns (bool found, uint256 index) {
        uint256 heldCount;
        for (uint256 i = 1; i < ticketIds.length; i++) {
            if (_heldUnanswered(ticketIds[i])) heldCount++;
        }
        if (heldCount == 0) return (false, 0);
        uint256 wanted = idSeed % heldCount;
        for (uint256 i = 1; i < ticketIds.length; i++) {
            if (!_heldUnanswered(ticketIds[i])) continue;
            if (wanted == 0) return (true, i);
            wanted--;
        }
    }

    function _heldUnanswered(bytes32 ticketId) internal view returns (bool) {
        bool held = lite.known(ticketId);
        bool answered = lite.answered(MessageTypesLib.halfKeyOf(ticketId, 0));
        return held && !answered;
    }

    /// @dev What actor `actor`'s away wallet has free, at least 1 so an empty wallet still tries and is refused.
    function _mostThatCanLeave(uint256 actor) internal view returns (uint256) {
        uint256 free = token.availableOf(satellites[actor]);
        if (free == 0) return 1;
        return free;
    }

    function _homeWalletOf(uint256 actor) internal view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(block.chainid, actors[actor]);
    }

    /// @dev A move out, a bring home or a ticket picked by `idSeed`.
    function _anyTicket(uint256 idSeed) internal view returns (bool found, bytes32 ticketId) {
        uint256 moveOuts = moveOutIds.length - 1;
        uint256 bringHomes = bringHomeIds.length - 1;
        uint256 tickets = ticketIds.length - 1;
        uint256 count = moveOuts + bringHomes + tickets;
        if (count == 0) return (false, bytes32(0));
        uint256 index = idSeed % count;
        if (index < moveOuts) return (true, moveOutIds[1 + index]);
        index -= moveOuts;
        if (index < bringHomes) return (true, bringHomeIds[1 + index]);
        return (true, ticketIds[1 + index - bringHomes]);
    }

    /// @dev Whether the away token minted one of the halves of the move out `ticketId`.
    function _mintedOnTheAwayToken(bytes32 ticketId) internal view returns (bool) {
        uint8 latestHalf = boundCompliance.ticketOf(ticketId).half;
        for (uint8 half = 1; half <= latestHalf; half++) {
            MessageTypesLib.ReceiptMessage memory receipt = lite.storedReceipt(ticketId, half);
            bool minted = receipt.answer == MessageTypesLib.ReceiptAnswer.Executed && receipt.amount != 0;
            if (minted) return true;
        }
        return false;
    }

    /// @dev What the away token burned for the bring home `ticketId`, while home has not applied its receipt yet.
    function _burnedNotApplied(bytes32 ticketId) internal view returns (uint256 burned) {
        ITickets.Ticket memory bringHomeTicket = boundCompliance.ticketOf(ticketId);
        if (bringHomeTicket.status == ITickets.TicketStatus.Done) return 0;
        for (uint8 half = 1; half <= bringHomeTicket.half; half++) {
            MessageTypesLib.ReceiptMessage memory receipt = lite.storedReceipt(ticketId, half);
            if (receipt.answer == MessageTypesLib.ReceiptAnswer.Executed) burned += receipt.amount;
        }
    }

    /// @dev What the away token moved for the ticket `ticketId` and home has not applied: it executed the ticket and
    ///  its receipt has not landed, the ticket still open or cancelled meanwhile.
    function _executedNotApplied(bytes32 ticketId) internal view returns (uint256) {
        ITickets.TicketStatus status = boundCompliance.ticketOf(ticketId).status;
        bool applied = status == ITickets.TicketStatus.OnHold || status == ITickets.TicketStatus.Done;
        if (applied) return 0;
        MessageTypesLib.ReceiptMessage memory receipt = lite.storedReceipt(ticketId, 0);
        if (receipt.answer != MessageTypesLib.ReceiptAnswer.Executed) return 0;
        return receipt.amount;
    }

    /// @dev What a move out minted on the away token while home still holds it: its receipt has not landed.
    function _mintedNotApplied(uint256 index) internal view returns (uint256) {
        bytes32 ticketId = moveOutIds[index];
        bool stillOnHold = boundCompliance.ticketOf(ticketId).status == ITickets.TicketStatus.OnHold;
        if (stillOnHold && _mintedOnTheAwayToken(ticketId)) return moveOutAmount[index];
        return 0;
    }

    /// @dev What a ticket took to its home wallet, once done: a forward move ends there.
    function _movedHomeBy(bytes32 ticketId) internal view returns (uint256) {
        ITickets.Ticket memory homeTicket = boundCompliance.ticketOf(ticketId);
        bool done = homeTicket.status == ITickets.TicketStatus.Done;
        bool forward = homeTicket.secondHalfToKey == homeTicket.toKey;
        if (done && forward) return homeTicket.moved;
        return 0;
    }

    /// @dev What left actor `actor`'s away wallet on the away token that home has not applied: tickets it executed
    ///  and burns of its bring homes.
    function _leftNotApplied(uint256 actor) internal view returns (uint256 left) {
        for (uint256 i = 1; i < ticketIds.length; i++) {
            if (ticketSender[i] == actor) left += _executedNotApplied(ticketIds[i]);
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            if (bringHomeActor[i] == actor) left += _burnedNotApplied(bringHomeIds[i]);
        }
    }

    /// @dev What tickets executed toward actor `actor`'s away wallet moved into it that home has not applied.
    function _ticketsIntoNotApplied(uint256 actor) internal view returns (uint256 arrived) {
        for (uint256 i = 1; i < ticketIds.length; i++) {
            bool towardItsAwayWallet = !ticketToHome[i] && ticketReceiver[i] == actor;
            if (towardItsAwayWallet) arrived += _executedNotApplied(ticketIds[i]);
        }
    }

    /// @dev What reached actor `actor`'s away wallet on the away token that home has not applied: tickets executed
    ///  toward it and its move outs minted.
    function _arrivedNotApplied(uint256 actor) internal view returns (uint256 arrived) {
        arrived = _ticketsIntoNotApplied(actor);
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            if (moveOutActor[i] == actor) arrived += _mintedNotApplied(i);
        }
    }

    /// @dev What actor `actor` has in flight toward home's away total: move outs on hold not minted on the away token
    ///  yet, burns done on the away token whose receipt home has not applied, and tickets to a home wallet it executed
    ///  that home has not applied.
    function _inFlightFor(uint256 actor) internal view returns (uint256 held) {
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            bool onHold = boundCompliance.ticketOf(moveOutIds[i]).status == ITickets.TicketStatus.OnHold;
            bool notMinted = !_mintedOnTheAwayToken(moveOutIds[i]);
            if (moveOutActor[i] == actor && onHold && notMinted) held += moveOutAmount[i];
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            if (bringHomeActor[i] == actor) held += _burnedNotApplied(bringHomeIds[i]);
        }
        for (uint256 i = 1; i < ticketIds.length; i++) {
            bool toAHomeWallet = ticketToHome[i] && ticketSender[i] == actor;
            if (toAHomeWallet) held += _executedNotApplied(ticketIds[i]);
        }
    }

    /// @dev The money home holds between two halves for actor `actor`'s move outs and tickets.
    function _onHoldFor(uint256 actor) internal view returns (uint256 held) {
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            if (moveOutActor[i] == actor) held += token.onHoldOf(moveOutIds[i]);
        }
        for (uint256 i = 1; i < ticketIds.length; i++) {
            if (ticketSender[i] == actor) held += token.onHoldOf(ticketIds[i]);
        }
    }

    /// @dev Every amount on hold the harness knows of.
    function _everyHold() internal view returns (uint256 held) {
        for (uint256 i = 0; i < ACTORS; i++) {
            held += _onHoldFor(i);
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            held += token.onHoldOf(bringHomeIds[i]);
        }
    }

    /// @dev The moves between chains done with something moved, each of which tells the trackers once: a move out
    ///  minted and landed, a bring home minted at home, a ticket applied forward.
    function _movesDone() internal view returns (uint256 count) {
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            bool done = boundCompliance.ticketOf(moveOutIds[i]).status == ITickets.TicketStatus.Done;
            if (done && !closedByHand[moveOutIds[i]]) count++;
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            ITickets.Ticket memory bringHomeTicket = boundCompliance.ticketOf(bringHomeIds[i]);
            bool done = bringHomeTicket.status == ITickets.TicketStatus.Done;
            if (done && bringHomeTicket.moved != 0) count++;
        }
        for (uint256 i = 1; i < ticketIds.length; i++) {
            ITickets.Ticket memory homeTicket = boundCompliance.ticketOf(ticketIds[i]);
            bool done = homeTicket.status == ITickets.TicketStatus.Done;
            bool returned = homeTicket.secondHalfToKey == homeTicket.fromKey;
            if (done && homeTicket.moved != 0 && !returned) count++;
        }
    }

    function _positions() internal view returns (uint256[] memory positions) {
        positions = new uint256[](ACTORS);
        for (uint256 i = 0; i < ACTORS; i++) {
            positions[i] = ledger.positionOf(address(identities[i]));
        }
    }

    /// @dev For each actor, a fingerprint of where its own requests stand: the tickets it sent, its move outs and its
    ///  bring homes.
    function _requestStatuses() internal view returns (bytes32[] memory statuses) {
        statuses = new bytes32[](ACTORS);
        for (uint256 i = 1; i < ticketIds.length; i++) {
            uint256 sender = ticketSender[i];
            statuses[sender] = keccak256(abi.encode(statuses[sender], boundCompliance.ticketOf(ticketIds[i]).status));
        }
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            uint256 actor = moveOutActor[i];
            statuses[actor] = keccak256(abi.encode(statuses[actor], boundCompliance.ticketOf(moveOutIds[i]).status));
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            uint256 actor = bringHomeActor[i];
            statuses[actor] = keccak256(abi.encode(statuses[actor], boundCompliance.ticketOf(bringHomeIds[i]).status));
        }
    }

    function _checkPositionsFell(uint256[] memory positionsBefore, bytes32[] memory requestsBefore) internal {
        uint256[] memory positionsAfter = _positions();
        bytes32[] memory requestsAfter = _requestStatuses();
        for (uint256 i = 0; i < ACTORS; i++) {
            bool fell = positionsAfter[i] < positionsBefore[i];
            bool ownRequestMoved = requestsAfter[i] != requestsBefore[i];
            bool ownTransfer = transferringActor == i + 1;
            if (fell && !ownRequestMoved && !ownTransfer) positionFellWithoutItsRequest = true;
        }
    }

}
