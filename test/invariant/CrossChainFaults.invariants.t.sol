// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { console } from "@forge-std/console.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { DelegationRecallInvariants } from "test/invariant/DelegationRecall.invariants.t.sol";

/// @title CrossChainFaultsInvariants
/// @notice The move-out-and-bring-home harness with the transport and the reference chain misbehaving. On top of its
///  transitions the fuzzer reorders deliveries, drops messages, delays them, delivers identical copies under new
///  transport ids, and reorgs the reference chain. Every invariant of the base suite (DR-1 to DR-6) is checked under
///  these faults as well.
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
///   MF-1  positionOf(identity) == native balance + satellite balance + amounts held in flight: move outs not minted
///         yet, burns done on the satellite whose receipt home has not applied
///   MF-2  no satellite wallet holds more than the reference chain counts for it: its away balance and its move outs on
///         hold
///   MF-3  delivering an identical copy of a message already delivered changes no balance, position, total or pause
contract CrossChainFaultsInvariants is DelegationRecallInvariants {

    uint256 internal constant MAX_DELAY = 7 days;

    /// @dev A satellite transaction since the last final state, replayed after a reorg. `payload` and `sender` are
    ///  those of the message the satellite consumed and `queueIndex` the queue entry it was delivered from;
    ///  `ticketId` and `half` name the receipt the satellite sent again; `at` is the satellite's clock when it acted,
    ///  since what an away token does with a half depends on it.
    struct SatelliteAction {
        bool isResend;
        address sender;
        bytes payload;
        uint256 queueIndex;
        bytes32 ticketId;
        uint8 half;
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

    function sendSecondHalfAgain(uint256 idSeed, bool aBringHome) public override journaled {
        super.sendSecondHalfAgain(idSeed, aBringHome);
    }

    function drop(uint256 indexSeed) public override journaled {
        super.drop(indexSeed);
    }

    function relay(uint256 indexSeed) external override journaled {
        callsRelay++;
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        _relayOnce(indexSeed % length);
    }

    function liteResendsReceipt(uint256 idSeed, uint8 halfSeed) external override journaled {
        (bool found, bytes32 ticketId) = _anyTicket(idSeed);
        if (!found) return;
        _resendReceipt(ticketId, halfSeed);
    }

    /* ----- Transitions: faults ----- */

    /// @notice Delivers a later message before an earlier one. Counted only when both were delivered, in that order.
    function reorder(uint256 firstSeed, uint256 secondSeed) external journaled {
        uint256 length = gateway.queueLength();
        if (length < 2) return;
        uint256 firstIndex = firstSeed % length;
        uint256 secondIndex = secondSeed % length;
        if (firstIndex == secondIndex) return;
        (uint256 earlier, uint256 later) =
            firstIndex < secondIndex ? (firstIndex, secondIndex) : (secondIndex, firstIndex);
        bool laterDelivered = _relayOnce(later);
        bool earlierDelivered = _relayOnce(earlier);
        if (laterDelivered && earlierDelivered) faults.reorders++;
    }

    /// @notice Lets time pass with messages in flight.
    function delay(uint256 secondsSeed) external journaled {
        faults.delays++;
        vm.warp(block.timestamp + bound(secondsSeed, 1, MAX_DELAY));
    }

    /// @notice Delivers an identical copy of a message already delivered, under a new transport id, and records
    ///  whether it changed anything. Counted only when the copy was delivered.
    function duplicate(uint256 indexSeed) external journaled {
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(indexSeed % length);
        if (message.deliveries == 0 || message.dropped) return;

        bytes32 before = _fingerprint();
        uint256 copy = _requeue(message.sender, message.recipient, message.payload);
        try gateway.relay(copy) {
            faults.duplicates++;
            if (_toSatellite(message.recipient)) _logDelivery(message.sender, message.payload, copy);
        } catch { }
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
        } catch { }
        vm.warp(currentTime);
    }

    /// @notice The satellite resent this receipt before the reorg and resends it again after it.
    function replayedReceiptResend(bytes32 ticketId, uint8 half) external journaled {
        _resendStoredReceipt(ticketId, half);
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
                ledger.positionOf(address(identities[i])),
                token.balanceOf(actors[i]) + lite.balanceOf(satellites[i]) + _heldFor(i),
                "MF-1"
            );
        }
    }

    /// @dev The reference chain counts a move out on hold until its receipt lands, so what a satellite minted is
    ///  covered by the wallet's away balance plus its move outs on hold.
    function invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            uint256 counted = token.awayBalanceOf(satellites[i]) + _onHoldFor(i);
            assertLe(lite.balanceOf(satellites[i]), counted, "MF-2");
        }
    }

    function invariant_MF3_anIdenticalDuplicateNeverChangesState() public view {
        assertFalse(duplicateChangedState, "MF-3");
    }

    function invariant_faultSummary() public view {
        console.log("reorder, delay, duplicate:", faults.reorders, faults.delays, faults.duplicates);
        console.log("finalize, reorg:", faults.finalizations, faults.reorgs);
    }

    /* ----- Demonstration ----- */

    /// @notice The same reorg, with a relayer that does not wait for finality: the satellite mints a move out the
    ///  reorg then removes from the reference chain, and holds tokens the reference chain no longer counts. MF-2 itself
    ///  catches it, which is the negative control of the invariant run.
    function test_aDeliveryBeforeFinalityBreaksTheSatelliteBound() public {
        deliverBeforeFinality = true;
        this.moveOut(0, 100);
        this.relay(gateway.queueLength() - 1);
        assertEq(lite.balanceOf(satellites[0]), 100, "minted on the satellite");

        _reorg();

        assertFalse(reorgMissedTheFinalState);
        assertEq(token.awayBalanceOf(satellites[0]), 0, "the reference chain no longer counts the move out");
        assertEq(lite.balanceOf(satellites[0]), 100, "the satellite still holds it");
        vm.expectRevert();
        this.invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount();
    }

    /// @notice With the relayer waiting for finality, the move out lost in the reorg never reached the satellite.
    function test_aDeliveryAfterFinalitySurvivesTheReorg() public {
        this.moveOut(0, 100);
        uint256 moveOutEntry = gateway.queueLength() - 1;
        this.relay(moveOutEntry);
        assertEq(lite.balanceOf(satellites[0]), 0, "not final yet: held back");

        this.finalize();
        this.relay(moveOutEntry);
        uint256 bobBalance = token.balanceOf(bob);
        this.transfer(0, 1, 1);
        assertEq(token.balanceOf(bob), bobBalance + 1);
        _reorg();

        assertFalse(reorgMissedTheFinalState);
        assertEq(token.balanceOf(bob), bobBalance, "the reorg went back: what the reference chain did since is gone");
        assertEq(lite.balanceOf(satellites[0]), 100, "replayed on the satellite after the reorg");
        assertEq(gateway.queuedMessage(moveOutEntry).deliveries, 1, "replayed from its own entry, delivered once");
        this.relay(gateway.queueLength() - 1);
        assertEq(token.awayBalanceOf(satellites[0]), 100, "the replayed receipt lands the move out");
        invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts();
        invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount();
    }

    /// @notice A reference-chain receipt in the reorged window is undone, and the message can be delivered again.
    function test_aReceiptReceivedInTheReorgedWindowIsDeliveredAgain() public {
        this.moveOut(0, 100);
        this.finalize();
        this.relay(gateway.queueLength() - 1);
        this.relay(gateway.queueLength() - 1);
        assertEq(token.awayBalanceOf(satellites[0]), 100, "the move out landed");
        this.bringHome(0, 40);
        this.finalize();
        this.relay(gateway.queueLength() - 1);
        this.relay(gateway.queueLength() - 1);
        assertEq(token.awayBalanceOf(satellites[0]), 60, "the receipt landed");

        _reorg();

        assertFalse(reorgMissedTheFinalState);
        assertEq(token.awayBalanceOf(satellites[0]), 100, "the settlement was in the reorged window");
        assertEq(lite.balanceOf(satellites[0]), 60, "the satellite burn stands");
        this.relay(gateway.queueLength() - 1);
        assertEq(token.awayBalanceOf(satellites[0]), 60, "landed again from the replayed receipt");
        invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts();
    }

    /// @notice A second reorg goes back to the same final state as the first, and a reorg after it to the state made
    ///  final in between: what the satellite did is carried through each of them.
    function test_aReorgAfterAReorgGoesBackToTheLastFinalState() public {
        this.moveOut(0, 100);
        this.finalize();
        this.relay(gateway.queueLength() - 1);
        this.relay(gateway.queueLength() - 1);
        this.finalize();
        _reorg();
        this.mint(1, 7);
        _reorg();
        assertEq(lite.balanceOf(satellites[0]), 100, "carried through both reorgs");
        assertEq(token.balanceOf(bob), 1000, "the mint was in the second reorged window");

        this.finalize();
        this.mint(1, 7);
        _reorg();

        assertFalse(reorgMissedTheFinalState);
        assertEq(faults.reorgs, 3);
        assertEq(token.balanceOf(bob), 1000);
        assertEq(token.awayBalanceOf(satellites[0]), 100);
        assertEq(lite.balanceOf(satellites[0]), 100);
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
            if (actions[i].isResend) this.replayedReceiptResend(actions[i].ticketId, actions[i].half);
            else this.replayedDelivery(actions[i].sender, actions[i].payload, actions[i].queueIndex, actions[i].at);
        }
    }

    /// @dev Delivers a queue entry not yet delivered. A message for the satellite is held back until the state that
    ///  sent it is final, and is logged for replay once delivered.
    /// @return delivered whether the entry was delivered by this call
    function _relayOnce(uint256 index) internal returns (bool delivered) {
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(index);
        if (message.deliveries != 0 || message.dropped) return false;
        bool toSatellite = _toSatellite(message.recipient);
        if (toSatellite && index >= finalQueueLength && !deliverBeforeFinality) return false;
        try gateway.relay(index) {
            delivered = true;
            if (toSatellite) _logDelivery(message.sender, message.payload, index);
        } catch { }
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
                    isResend: true,
                    sender: address(0),
                    payload: "",
                    queueIndex: 0,
                    ticketId: ticketId,
                    half: half,
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
                isResend: false,
                sender: sender,
                payload: payload,
                queueIndex: queueIndex,
                ticketId: bytes32(0),
                half: 0,
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

    /// @dev What actor `actor` holds in flight: move outs not minted on the satellite yet, and burns done on its
    ///  wallet whose receipt home has not applied.
    function _heldFor(uint256 actor) internal view returns (uint256) {
        return _inFlightFor(actor);
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
    }

}
