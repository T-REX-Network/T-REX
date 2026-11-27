// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";

import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { DelegationRecallInvariants } from "test/invariant/DelegationRecall.invariants.t.sol";

/// @title CrossChainFaultsInvariants
/// @notice The harness of tickets, move outs and bring homes with the transport and the reference chain misbehaving.
///  On top of its transitions the fuzzer reorders deliveries, drops messages, delays them, delivers identical copies
///  under new transport ids, and reorgs the reference chain, so lost, late, repeated and reordered messages and reorgs
///  reach tickets, their receipts, asks for receipts, cancels, second halves and bring homes. Every invariant of the
///  base suite is checked under these faults as well, and at the end of each run everything left is delivered and
///  every request must end (L1, L3). Each fault a step injects must take effect: a reorder delivers both messages, a
///  copy is delivered, a drop drops.
///
///  The reorg. `finalize` marks the reference chain's current state final. `reorg` throws away everything the
///  reference chain did since and keeps everything the satellite did. A state snapshot taken by one call of an
///  invariant run does not outlive that call, so the only snapshot is the one `setUp` takes, and the final state is
///  rebuilt from it: every transition is journaled, the reorg reverts to the `setUp` state, runs the journal again up
///  to the last `finalize`, and checks it arrived at the state that was final (MF-0). The satellite's transactions
///  since then, logged with the messages they consumed, are replayed on top. A message sent by a final state is
///  replayed from its own queue entry, so it stays delivered once; one sent in the reorged window no longer exists
///  and is replayed from a copy. Time does not go back. What the reference chain did in the reorged window is lost,
///  as when a reorg drops its transactions for good: messages it sent then are gone, messages it received then can be
///  delivered again.
///
///  The relayer waits for finality: a message from the reference chain reaches the satellite only once the state that
///  sent it is final. That is the rule that keeps the invariants true under a reorg; the test
///  `test_aDeliveryBeforeFinalityBreaksTheSatelliteBound` shows what happens without it.
///
///   MF-0  every reorg went back to the state that was final
///   MF-1  positionOf(identity) + tickets executed into its away wallet not applied == native balance + satellite
///         balance + amounts held in flight: move outs on hold not minted yet, what left its away wallet on the
///         satellite whose receipt home has not applied, and its tickets on hold
///   MF-2  no satellite wallet holds more than the reference chain counts for it: its away balance, its move outs on
///         hold and the tickets executed into it whose receipt home has not applied
///   MF-3  delivering an identical copy of a message already delivered changes no balance, position, total or pause
contract CrossChainFaultsInvariants is DelegationRecallInvariants {

    uint256 internal constant MAX_DELAY = 7 days;
    /// @dev Half the delays stay this short, so a ticket can still be executed and a half minted inside its window.
    uint256 internal constant MAX_SHORT_DELAY = 10 minutes;

    /// @dev What a satellite transaction was: a message it consumed, a receipt it sent again, or a ticket its holder
    ///  executed.
    enum SatelliteActionKind {
        Delivery,
        Resend,
        Execution
    }

    /// @dev A satellite transaction since the last final state, replayed after a reorg. `payload` and `sender` are
    ///  those of the message the satellite consumed and `queueIndex` the queue entry it was delivered from;
    ///  `ticketId` and `half` name the receipt the satellite sent again; `ticketId`, `amount` and `sender` name the
    ///  ticket executed, for how much and by whom; `at` is the satellite's clock when it acted, since what an away
    ///  token does with a ticket or a half depends on it.
    struct SatelliteAction {
        SatelliteActionKind kind;
        address sender;
        bytes payload;
        uint256 queueIndex;
        bytes32 ticketId;
        uint8 half;
        uint256 amount;
        uint256 at;
    }

    /// @dev How many times each fault took effect. Kept across a reorg, which would otherwise roll the counts back
    ///  with the rest of the state.
    struct FaultCounts {
        uint256 reorders;
        uint256 delays;
        uint256 duplicates;
        uint256 finalizations;
        uint256 reorgs;
    }

    /// @dev The state `setUp` ends in, the only snapshot a reorg reverts to, with the clock it was taken at.
    uint256 internal genesisSnapshot;
    uint256 internal genesisTimestamp;
    uint256 internal genesisBlock;
    /// @dev Every transition since `setUp`, in order, as `abi.encode(time it ran, calldata)`: a reorg runs it again at
    ///  that time, since what the token decides depends on its clock. Entries below `finalJournalLength` led to the
    ///  final state, whose fingerprint is `finalFingerprint`.
    bytes[] internal journal;
    uint256 internal finalJournalLength;
    bytes32 internal finalFingerprint;
    /// @dev Queue entries below this index were sent by a final state.
    uint256 internal finalQueueLength;
    SatelliteAction[] internal satelliteLog;
    /// @dev On while a reorg runs the journal again, so the transitions are not journaled a second time.
    bool internal replaying;
    /// @dev Off in the invariant run: the relayer waits for finality. The demonstration test turns it on.
    bool internal deliverBeforeFinality;

    bool public duplicateChangedState;
    bool public reorgMissedTheFinalState;

    FaultCounts internal faults;

    /// @dev Journals the transition, see {_reorg}.
    modifier journaled() {
        if (!replaying) journal.push(abi.encode(block.timestamp, msg.data));
        _;
    }

    function setUp() public override {
        super.setUp();
        // The funding move outs of the base `setUp` are part of the genesis state, not transitions to replay.
        delete journal;
        genesisTimestamp = block.timestamp;
        genesisBlock = block.number;
        _finalize();
        genesisSnapshot = vm.snapshotState();
    }

    function _targetSelectors() internal view override returns (bytes4[] memory selectors) {
        bytes4[] memory base = super._targetSelectors();
        selectors = new bytes4[](base.length + 5);
        for (uint256 i = 0; i < base.length; i++) {
            selectors[i] = base[i];
        }
        selectors[base.length] = this.reorder.selector;
        selectors[base.length + 1] = this.delay.selector;
        selectors[base.length + 2] = this.duplicate.selector;
        selectors[base.length + 3] = this.finalize.selector;
        selectors[base.length + 4] = this.reorg.selector;
    }

    /* ----- Transitions: the base ones, journaled and made reorg-aware ----- */

    function mint(uint256 actorSeed, uint256 amount) public override journaled {
        super.mint(actorSeed, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public override journaled {
        super.transfer(fromSeed, toSeed, amount);
    }

    function moveOut(uint256 actorSeed, uint256 amount) public override journaled {
        super.moveOut(actorSeed, amount);
    }

    function bringHome(uint256 actorSeed, uint256 amount) public override journaled {
        super.bringHome(actorSeed, amount);
    }

    function askTicket(uint256 fromSeed, uint256 toSeed, uint256 amount, bool toHome) public override journaled {
        super.askTicket(fromSeed, toSeed, amount, toHome);
    }

    function awayTokenExecutes(uint256 idSeed, uint256 amountSeed) public override journaled {
        super.awayTokenExecutes(idSeed, amountSeed);
    }

    function askForTheReceipt(uint256 idSeed) public override journaled {
        super.askForTheReceipt(idSeed);
    }

    function cancelTicket(uint256 idSeed) public override journaled {
        super.cancelTicket(idSeed);
    }

    function sendSecondHalfAgain(uint256 idSeed, bool aBringHome) public override journaled {
        super.sendSecondHalfAgain(idSeed, aBringHome);
    }

    function drop(uint256 indexSeed) public override journaled {
        super.drop(indexSeed);
    }

    function relay(uint256 indexSeed) external override journaled positionsFallOnlyThroughOwnRequests {
        callsRelay++;
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        _relayOnce(indexSeed % length);
    }

    function liteResendsReceipt(uint256 idSeed, uint8 halfSeed)
        external
        override
        journaled
        positionsFallOnlyThroughOwnRequests
    {
        (bool found, bytes32 ticketId) = _anyTicket(idSeed);
        if (!found) return;
        _resendReceipt(ticketId, halfSeed);
    }

    /* ----- Transitions: faults ----- */

    /// @notice Delivers a later message before an earlier one. Injected when both can be delivered now; then both
    ///  must be, in that order.
    function reorder(uint256 firstSeed, uint256 secondSeed) external journaled positionsFallOnlyThroughOwnRequests {
        uint256 length = gateway.queueLength();
        if (length < 2) return;
        uint256 firstIndex = firstSeed % length;
        uint256 secondIndex = secondSeed % length;
        if (firstIndex == secondIndex) return;
        uint256 earlier = firstIndex;
        uint256 later = secondIndex;
        if (secondIndex < firstIndex) {
            earlier = secondIndex;
            later = firstIndex;
        }
        bool injected = _canBeDeliveredNow(earlier) && _canBeDeliveredNow(later);
        bool laterDelivered = _relayOnce(later);
        bool earlierDelivered = _relayOnce(earlier);
        bool happened = laterDelivered && earlierDelivered;
        if (happened) faults.reorders++;
        if (injected && !happened) anInjectedFaultDidNotHappen = true;
    }

    /// @notice Lets time pass with messages in flight: up to ten minutes or up to seven days, half the time each.
    function delay(uint256 secondsSeed) external journaled {
        faults.delays++;
        uint256 longestDelay = MAX_DELAY;
        if (secondsSeed % 2 == 0) longestDelay = MAX_SHORT_DELAY;
        vm.warp(block.timestamp + bound(secondsSeed, 1, longestDelay));
    }

    /// @notice Delivers an identical copy of a message already delivered, under a new transport id, and records
    ///  whether it changed anything. Injected for any message delivered and not dropped; the copy must be delivered.
    function duplicate(uint256 indexSeed) external journaled positionsFallOnlyThroughOwnRequests {
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(indexSeed % length);
        if (message.deliveries == 0 || message.dropped) return;

        bytes32 before = _fingerprint();
        uint256 copy = _requeue(message.sender, message.recipient, message.payload);
        try gateway.relay(copy) {
            faults.duplicates++;
            if (_toSatellite(message.recipient)) _logDelivery(message.sender, message.payload, copy);
        } catch (bytes memory reason) {
            _noteRevertedDelivery(reason);
            anInjectedFaultDidNotHappen = true;
        }
        if (_fingerprint() != before) duplicateChangedState = true;
    }

    /// @notice The reference chain's current state becomes final.
    function finalize() external journaled {
        _finalize();
    }

    /// @notice Reorgs the reference chain back to its last final state, keeping what the satellite did since.
    function reorg() external {
        _reorg();
    }

    /* ----- The satellite's transactions, replayed by a reorg. Not fuzzed. ----- */

    /// @notice The satellite consumed this message before the reorg and consumes it again after it: from the queue
    ///  entry it came from when a final state sent it, from a copy when the entry went with the reorged window.
    ///  The satellite's transaction is final at the time it ran, so it runs again on the satellite's clock of then.
    function replayedDelivery(address sender, bytes calldata payload, uint256 queueIndex, uint256 at)
        external
        journaled
    {
        uint256 index = queueIndex < finalQueueLength
            ? queueIndex
            : _requeue(sender, abi.encodePacked(_liteEnvelope()), payload);
        uint256 currentTime = block.timestamp;
        vm.warp(at);
        try gateway.relay(index) {
            _logDelivery(sender, payload, index);
        } catch (bytes memory reason) {
            _noteRevertedDelivery(reason);
        }
        vm.warp(currentTime);
    }

    /// @notice The satellite resent this receipt before the reorg and resends it again after it.
    function replayedReceiptResend(bytes32 ticketId, uint8 half) external journaled {
        _resendStoredReceipt(ticketId, half);
    }

    /// @notice The holder executed this ticket on the satellite before the reorg and executes it again after it, on
    ///  the satellite's clock of then.
    function replayedExecution(bytes32 ticketId, uint256 amount, address executor, uint256 at) external journaled {
        uint256 currentTime = block.timestamp;
        vm.warp(at);
        vm.prank(executor);
        try lite.execute(ticketId, amount) {
            _afterTheAwayTokenExecuted(ticketId, amount, executor);
        } catch { }
        vm.warp(currentTime);
    }

    /* ----- Invariants ----- */

    /// @dev A reorg that did not go back, or went back to another state, would leave every other invariant checked
    ///  against a chain that was never reorged.
    function invariant_MF0_everyReorgWentBackToTheFinalState() public view {
        assertFalse(reorgMissedTheFinalState, "MF-0");
    }

    function invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            assertEq(
                ledger.positionOf(address(identities[i])) + _ticketsIntoNotApplied(i),
                token.balanceOf(actors[i]) + lite.balanceOf(satellites[i]) + _heldFor(i),
                "MF-1"
            );
        }
    }

    /// @dev The reference chain counts a move out on hold until its receipt lands, and a ticket's move until its
    ///  receipt lands, so what a satellite wallet holds is covered by its away balance, its move outs on hold and the
    ///  tickets executed into it.
    function invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            uint256 counted = token.awayBalanceOf(satellites[i]) + _onHoldFor(i) + _ticketsIntoNotApplied(i);
            assertLe(lite.balanceOf(satellites[i]), counted, "MF-2");
        }
    }

    function invariant_MF3_anIdenticalDuplicateNeverChangesState() public view {
        assertFalse(duplicateChangedState, "MF-3");
    }

    /* ----- Demonstration ----- */

    /// @notice The same reorg, with a relayer that does not wait for finality: the satellite mints a move out the
    ///  reorg then removes from the reference chain, and holds tokens the reference chain no longer counts. MF-2 itself
    ///  catches it, which is the negative control of the invariant run.
    function test_aDeliveryBeforeFinalityBreaksTheSatelliteBound() public {
        deliverBeforeFinality = true;
        this.moveOut(0, 100);
        this.relay(gateway.queueLength() - 1);
        assertEq(lite.balanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100, "minted on the satellite");

        _reorg();

        assertFalse(reorgMissedTheFinalState);
        assertEq(
            token.awayBalanceOf(satellites[0]),
            STARTING_AWAY_BALANCE,
            "the reference chain no longer counts the move out"
        );
        assertEq(lite.balanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100, "the satellite still holds it");
        vm.expectRevert();
        this.invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount();
    }

    /// @notice With the relayer waiting for finality, the move out lost in the reorg never reached the satellite.
    function test_aDeliveryAfterFinalitySurvivesTheReorg() public {
        this.moveOut(0, 100);
        uint256 moveOutEntry = gateway.queueLength() - 1;
        this.relay(moveOutEntry);
        assertEq(lite.balanceOf(satellites[0]), STARTING_AWAY_BALANCE, "not final yet: held back");

        this.finalize();
        this.relay(moveOutEntry);
        uint256 bobBalance = token.balanceOf(bob);
        this.transfer(0, 1, 1);
        assertEq(token.balanceOf(bob), bobBalance + 1);
        _reorg();

        assertFalse(reorgMissedTheFinalState);
        assertEq(token.balanceOf(bob), bobBalance, "the reorg went back: what the reference chain did since is gone");
        assertEq(
            lite.balanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100, "replayed on the satellite after the reorg"
        );
        assertEq(gateway.queuedMessage(moveOutEntry).deliveries, 1, "replayed from its own entry, delivered once");
        this.relay(gateway.queueLength() - 1);
        assertEq(
            token.awayBalanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100, "the replayed receipt lands the move out"
        );
        invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts();
        invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount();
    }

    /// @notice A reference-chain receipt in the reorged window is undone, and the message can be delivered again.
    function test_aReceiptReceivedInTheReorgedWindowIsDeliveredAgain() public {
        this.moveOut(0, 100);
        this.finalize();
        this.relay(gateway.queueLength() - 1);
        this.relay(gateway.queueLength() - 1);
        assertEq(token.awayBalanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100, "the move out landed");
        this.bringHome(0, 40);
        this.finalize();
        this.relay(gateway.queueLength() - 1);
        this.relay(gateway.queueLength() - 1);
        assertEq(token.awayBalanceOf(satellites[0]), STARTING_AWAY_BALANCE + 60, "the receipt landed");

        _reorg();

        assertFalse(reorgMissedTheFinalState);
        assertEq(
            token.awayBalanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100, "the settlement was in the reorged window"
        );
        assertEq(lite.balanceOf(satellites[0]), STARTING_AWAY_BALANCE + 60, "the satellite burn stands");
        this.relay(gateway.queueLength() - 1);
        assertEq(
            token.awayBalanceOf(satellites[0]), STARTING_AWAY_BALANCE + 60, "landed again from the replayed receipt"
        );
        invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts();
    }

    /// @notice A second reorg goes back to the same final state as the first, and a reorg after it to the state made
    ///  final in between: what the satellite did is carried through each of them.
    function test_aReorgAfterAReorgGoesBackToTheLastFinalState() public {
        uint256 bobHomeBalance = token.balanceOf(bob);
        this.moveOut(0, 100);
        this.finalize();
        this.relay(gateway.queueLength() - 1);
        this.relay(gateway.queueLength() - 1);
        this.finalize();
        _reorg();
        this.mint(1, 7);
        _reorg();
        assertEq(lite.balanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100, "carried through both reorgs");
        assertEq(token.balanceOf(bob), bobHomeBalance, "the mint was in the second reorged window");

        this.finalize();
        this.mint(1, 7);
        _reorg();

        assertFalse(reorgMissedTheFinalState);
        assertEq(faults.reorgs, 3);
        assertEq(token.balanceOf(bob), bobHomeBalance);
        assertEq(token.awayBalanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100);
        assertEq(lite.balanceOf(satellites[0]), STARTING_AWAY_BALANCE + 100);
        invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts();
        invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount();
    }

    /* ----- Private ----- */

    function _finalize() internal {
        faults.finalizations++;
        finalJournalLength = journal.length;
        finalFingerprint = _fingerprint();
        finalQueueLength = gateway.queueLength();
        delete satelliteLog;
    }

    /// @dev See the contract's notice. Everything that must survive the revert is read before it and written back
    ///  after it. The journal is run again up to the last `finalize`, which leaves the harness's own records as they
    ///  were then, and the state arrived at is compared with the one that was final: a reorg that did not go back, or
    ///  not there, is recorded for MF-0 rather than left to pass unnoticed.
    function _reorg() internal {
        bytes[] memory finalTransitions = new bytes[](finalJournalLength);
        for (uint256 i = 0; i < finalTransitions.length; i++) {
            finalTransitions[i] = journal[i];
        }
        SatelliteAction[] memory actions = satelliteLog;
        FaultCounts memory counts = faults;
        bytes32 finalState = finalFingerprint;
        uint256 finalLength = finalQueueLength;
        uint256 snapshot = genesisSnapshot;
        uint256 timestamp = block.timestamp;
        uint256 blockNumber = block.number;
        bool beforeFinality = deliverBeforeFinality;
        bool missedBefore = reorgMissedTheFinalState;

        bool wentBack = vm.revertToState(snapshot);
        genesisSnapshot = snapshot;
        vm.warp(genesisTimestamp);
        vm.roll(genesisBlock);
        replaying = true;
        for (uint256 i = 0; i < finalTransitions.length; i++) {
            journal.push(finalTransitions[i]);
            (uint256 ranAt, bytes memory transition) = abi.decode(finalTransitions[i], (uint256, bytes));
            vm.warp(ranAt);
            (bool success,) = address(this).call(transition);
            wentBack = wentBack && success;
        }
        replaying = false;
        wentBack = wentBack && _fingerprint() == finalState && gateway.queueLength() == finalLength;

        vm.warp(timestamp);
        vm.roll(blockNumber);
        deliverBeforeFinality = beforeFinality;
        reorgMissedTheFinalState = missedBefore || !wentBack;
        counts.reorgs++;
        faults = counts;

        for (uint256 i = 0; i < actions.length; i++) {
            _replay(actions[i]);
        }
    }

    function _replay(SatelliteAction memory action) internal {
        if (action.kind == SatelliteActionKind.Resend) {
            this.replayedReceiptResend(action.ticketId, action.half);
            return;
        }
        if (action.kind == SatelliteActionKind.Execution) {
            this.replayedExecution(action.ticketId, action.amount, action.sender, action.at);
            return;
        }
        this.replayedDelivery(action.sender, action.payload, action.queueIndex, action.at);
    }

    /// @dev Delivers a queue entry not yet delivered. A message for the satellite is held back until the state that
    ///  sent it is final, and is logged for replay once delivered.
    /// @return delivered whether the entry was delivered by this call
    function _relayOnce(uint256 index) internal returns (bool delivered) {
        if (!_canBeDeliveredNow(index)) return false;
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(index);
        delivered = _deliver(index);
        if (delivered && _toSatellite(message.recipient)) _logDelivery(message.sender, message.payload, index);
    }

    /// @dev Whether a queue entry can be delivered now: not delivered, not dropped, and, for the satellite, sent by a
    ///  final state.
    function _canBeDeliveredNow(uint256 index) internal view returns (bool) {
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(index);
        if (message.deliveries != 0 || message.dropped) return false;
        bool toSatellite = _toSatellite(message.recipient);
        bool heldBackForFinality = toSatellite && index >= finalQueueLength && !deliverBeforeFinality;
        return !heldBackForFinality;
    }

    /// @dev At the end of a run every state is final: the relayer lets everything through, a pass at a time, until
    ///  a pass delivers nothing new.
    function _letEverythingArrive() internal override {
        uint256 delivered = 1;
        while (delivered != 0) {
            _finalize();
            delivered = 0;
            for (uint256 i = 0; i < gateway.queueLength(); i++) {
                if (_relayOnce(i)) delivered++;
            }
        }
    }

    function _afterTheAwayTokenExecuted(bytes32 ticketId, uint256 amount, address executor) internal override {
        satelliteLog.push(
            SatelliteAction({
                kind: SatelliteActionKind.Execution,
                sender: executor,
                payload: "",
                queueIndex: 0,
                ticketId: ticketId,
                half: 0,
                amount: amount,
                at: block.timestamp
            })
        );
    }

    function _resendStoredReceiptAtTheEnd(bytes32 ticketId, uint8 half) internal override {
        _resendStoredReceipt(ticketId, half);
    }

    /// @dev Sends a stored receipt again and logs it for replay, see {_resendStoredReceipt}.
    function _resendReceipt(bytes32 ticketId, uint8 halfSeed) internal override {
        uint8 latestHalf = boundCompliance.ticketOf(ticketId).half;
        if (latestHalf == 0) return;
        _resendStoredReceipt(ticketId, 1 + halfSeed % latestHalf);
    }

    function _resendStoredReceipt(bytes32 ticketId, uint8 half) internal {
        try lite.resendReceipt(ticketId, half) {
            satelliteLog.push(
                SatelliteAction({
                    kind: SatelliteActionKind.Resend,
                    sender: address(0),
                    payload: "",
                    queueIndex: 0,
                    ticketId: ticketId,
                    half: half,
                    amount: 0,
                    at: block.timestamp
                })
            );
        } catch { }
    }

    function _requeue(address sender, bytes memory recipient, bytes memory payload) internal returns (uint256) {
        vm.prank(sender);
        gateway.sendMessage(recipient, payload, new bytes[](0));
        return gateway.queueLength() - 1;
    }

    function _logDelivery(address sender, bytes memory payload, uint256 queueIndex) internal {
        satelliteLog.push(
            SatelliteAction({
                kind: SatelliteActionKind.Delivery,
                sender: sender,
                payload: payload,
                queueIndex: queueIndex,
                ticketId: bytes32(0),
                half: 0,
                amount: 0,
                at: block.timestamp
            })
        );
    }

    function _toSatellite(bytes memory recipient) internal view returns (bool) {
        (, address account) = InteroperableAddress.parseEvmV1(recipient);
        return account == address(lite);
    }

    function _liteEnvelope() internal view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(POLYGON, address(lite));
    }

    /// @dev What actor `actor` holds in flight: move outs on hold not minted on the satellite yet, what left its away
    ///  wallet on the satellite whose receipt home has not applied, and its tickets on hold.
    function _heldFor(uint256 actor) internal view returns (uint256 held) {
        held = _leftNotApplied(actor);
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            bool onHold = boundCompliance.ticketOf(moveOutIds[i]).status == ITickets.TicketStatus.OnHold;
            bool notMinted = !_mintedOnTheAwayToken(moveOutIds[i]);
            if (moveOutActor[i] == actor && onHold && notMinted) held += moveOutAmount[i];
        }
        for (uint256 i = 1; i < ticketIds.length; i++) {
            if (ticketSender[i] == actor) held += token.onHoldOf(ticketIds[i]);
        }
    }

    /// @dev Every balance, position, total and pause flag a delivery could move. Transport records are left out: a
    ///  copy is expected to be recorded as received.
    function _fingerprint() internal view returns (bytes32 print) {
        print = keccak256(
            abi.encode(
                token.totalSupply(),
                token.totalAwayBalance(),
                token.totalOnHold(),
                token.paused(),
                boundCompliance.isAwayChainBlocked(polygon),
                lite.mints(),
                lite.burns()
            )
        );
        for (uint256 i = 0; i < ACTORS; i++) {
            print = keccak256(
                abi.encode(
                    print,
                    token.balanceOf(actors[i]),
                    token.awayBalanceOf(satellites[i]),
                    ledger.positionOf(address(identities[i])),
                    lite.balanceOf(satellites[i])
                )
            );
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            print = keccak256(abi.encode(print, boundCompliance.ticketOf(bringHomeIds[i]).status));
        }
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            print = keccak256(abi.encode(print, boundCompliance.ticketOf(moveOutIds[i]).status));
        }
        for (uint256 i = 1; i < ticketIds.length; i++) {
            print = keccak256(abi.encode(print, boundCompliance.ticketOf(ticketIds[i]).status));
        }
    }

}
