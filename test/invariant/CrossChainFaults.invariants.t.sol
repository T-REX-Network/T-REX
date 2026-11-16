// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { console } from "@forge-std/console.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { DelegationRecallInvariants } from "test/invariant/DelegationRecall.invariants.t.sol";

/// @title CrossChainFaultsInvariants
/// @notice The delegation-and-recall harness with the transport and the reference chain misbehaving. On top of its
///  transitions the fuzzer reorders deliveries, drops messages, delays them, delivers identical copies under new
///  transport ids, and reorgs the reference chain. Every invariant of the base suite (DR-1 to DR-6) is checked under
///  these faults as well.
///
///  The reorg. `finalize` marks the reference chain's current state final (a state snapshot). `reorg` throws away
///  everything the reference chain did since, by reverting to that snapshot, and keeps everything the satellite did:
///  the satellite's transactions since the snapshot are logged with the messages they consumed, and replayed on top
///  of the reverted state. Time does not go back. What the reference chain did in the reorged window is lost, as when
///  a reorg drops its transactions for good: messages it sent then are gone, messages it received then can be
///  delivered again.
///
///  The relayer waits for finality: a message from the reference chain reaches the satellite only once the state that
///  sent it is final. That is the rule that keeps the invariants true under a reorg; the test
///  `test_aDeliveryBeforeFinalityBreaksTheSatelliteBound` shows what happens without it.
///
///   MF-1  positionOf(identity) == native balance + satellite balance + amounts held in flight: mints instructed and
///         not yet minted, burns done on the satellite whose proof has not settled
///   MF-2  no satellite wallet holds more than the reference chain counts for it
///   MF-3  delivering an identical copy of a message already delivered changes no balance, position, total or pause
contract CrossChainFaultsInvariants is DelegationRecallInvariants {

    uint256 internal constant MAX_DELAY = 7 days;

    /// @dev A satellite transaction since the last final state, replayed after a reorg. `payload` and `sender` are
    ///  those of the message the satellite consumed; `id` is the recall whose proof the satellite resent.
    struct SatelliteAction {
        bool isResend;
        address sender;
        bytes payload;
        uint256 id;
    }

    uint256 internal finalSnapshot;
    /// @dev Queue entries below this index were sent by a final state.
    uint256 internal finalQueueLength;
    SatelliteAction[] internal satelliteLog;
    /// @dev Off in the invariant run: the relayer waits for finality. The demonstration test turns it on.
    bool internal deliverBeforeFinality;

    bool public duplicateChangedState;

    uint256 public callsReorder;
    uint256 public callsDelay;
    uint256 public callsDuplicate;
    uint256 public callsFinalize;
    uint256 public callsReorg;

    function setUp() public override {
        super.setUp();
        _finalize();
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

    /* ----- Transitions: the base ones, made reorg-aware ----- */

    function relay(uint256 indexSeed) external override {
        callsRelay++;
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        _relayOnce(indexSeed % length);
    }

    function liteResendsProof(uint256 idSeed) external override {
        if (recallActor.length == 1) return;
        uint256 id = 1 + idSeed % (recallActor.length - 1);
        try lite.resendProof(id) {
            satelliteLog.push(SatelliteAction({ isResend: true, sender: address(0), payload: "", id: id }));
        } catch { }
    }

    /* ----- Transitions: faults ----- */

    /// @notice Delivers a later message before an earlier one.
    function reorder(uint256 firstSeed, uint256 secondSeed) external {
        uint256 length = gateway.queueLength();
        if (length < 2) return;
        uint256 a = firstSeed % length;
        uint256 b = secondSeed % length;
        if (a == b) return;
        callsReorder++;
        (uint256 earlier, uint256 later) = a < b ? (a, b) : (b, a);
        _relayOnce(later);
        _relayOnce(earlier);
    }

    /// @notice Lets time pass with messages in flight.
    function delay(uint256 secondsSeed) external {
        callsDelay++;
        vm.warp(block.timestamp + bound(secondsSeed, 1, MAX_DELAY));
    }

    /// @notice Delivers an identical copy of a message already delivered, under a new transport id, and records
    ///  whether it changed anything.
    function duplicate(uint256 indexSeed) external {
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(indexSeed % length);
        if (message.deliveries == 0 || message.dropped) return;
        callsDuplicate++;

        bytes32 before = _fingerprint();
        uint256 copy = _requeue(message.sender, message.recipient, message.payload);
        try gateway.relay(copy) {
            if (_toSatellite(message.recipient)) _logDelivery(message.sender, message.payload);
        } catch { }
        if (_fingerprint() != before) duplicateChangedState = true;
    }

    /// @notice The reference chain's current state becomes final.
    function finalize() external {
        callsFinalize++;
        _finalize();
    }

    /// @notice Reorgs the reference chain back to its last final state, keeping what the satellite did since.
    function reorg() external {
        SatelliteAction[] memory log = satelliteLog;
        uint256 snapshot = finalSnapshot;
        uint256 finalLength = finalQueueLength;
        uint256 timestamp = block.timestamp;
        uint256 blockNumber = block.number;
        bool early = deliverBeforeFinality;

        vm.revertToState(snapshot);
        vm.warp(timestamp);
        vm.roll(blockNumber);
        finalSnapshot = snapshot;
        finalQueueLength = finalLength;
        deliverBeforeFinality = early;
        delete satelliteLog;
        callsReorg++;

        for (uint256 i = 0; i < log.length; i++) {
            if (log[i].isResend) {
                try lite.resendProof(log[i].id) {
                    satelliteLog.push(log[i]);
                } catch { }
            } else {
                uint256 index = _requeue(log[i].sender, abi.encodePacked(_liteEnvelope()), log[i].payload);
                try gateway.relay(index) {
                    satelliteLog.push(log[i]);
                } catch { }
            }
        }
    }

    /* ----- Invariants ----- */

    function invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            assertEq(
                ledger.positionOf(address(identities[i])),
                token.balanceOf(actors[i]) + lite.balanceOf(satellites[i]) + _heldFor(i),
                "MF-1"
            );
        }
    }

    function invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            assertLe(lite.balanceOf(satellites[i]), token.bridgedBalanceOf(satellites[i]), "MF-2");
        }
    }

    function invariant_MF3_anIdenticalDuplicateNeverChangesState() public view {
        assertFalse(duplicateChangedState, "MF-3");
    }

    function invariant_faultSummary() public view {
        console.log("reorder, delay, duplicate:", callsReorder, callsDelay, callsDuplicate);
        console.log("finalize, reorg (since the last reorg):", callsFinalize, callsReorg);
    }

    /* ----- Demonstration ----- */

    /// @notice The same reorg, with a relayer that does not wait for finality: the satellite mints a delegation the
    ///  reorg then removes from the reference chain, and holds tokens the reference chain no longer counts.
    function test_aDeliveryBeforeFinalityBreaksTheSatelliteBound() public {
        deliverBeforeFinality = true;
        vm.prank(alice);
        token.delegateOut(alice, satellites[0], 100);
        _relayOnce(gateway.queueLength() - 1);
        assertEq(lite.balanceOf(satellites[0]), 100, "minted on the satellite");

        this.reorg();

        assertEq(token.bridgedBalanceOf(satellites[0]), 0, "the reference chain no longer counts the delegation");
        assertEq(lite.balanceOf(satellites[0]), 100, "the satellite still holds it");
        assertGt(lite.balanceOf(satellites[0]), token.bridgedBalanceOf(satellites[0]), "MF-2 broken");
    }

    /// @notice With the relayer waiting for finality, the delegation lost in the reorg never reached the satellite.
    function test_aDeliveryAfterFinalitySurvivesTheReorg() public {
        vm.prank(alice);
        token.delegateOut(alice, satellites[0], 100);
        _relayOnce(gateway.queueLength() - 1);
        assertEq(lite.balanceOf(satellites[0]), 0, "not final yet: held back");

        this.finalize();
        _relayOnce(gateway.queueLength() - 1);
        this.reorg();

        assertEq(token.bridgedBalanceOf(satellites[0]), 100);
        assertEq(lite.balanceOf(satellites[0]), 100, "replayed on the satellite after the reorg");
        invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts();
        invariant_MF2_noSatelliteHoldsWhatTheReferenceChainDoesNotCount();
    }

    /// @notice A reference-chain receipt in the reorged window is undone, and the message can be delivered again.
    function test_aProofReceivedInTheReorgedWindowIsDeliveredAgain() public {
        vm.prank(alice);
        token.delegateOut(alice, satellites[0], 100);
        this.finalize();
        _relayOnce(gateway.queueLength() - 1);
        vm.prank(agent);
        token.instructRecall(satellites[0], 40, alice);
        this.finalize();
        _relayOnce(gateway.queueLength() - 1);
        uint256 proof = gateway.queueLength() - 1;
        _relayOnce(proof);
        assertEq(token.bridgedBalanceOf(satellites[0]), 60, "the proof settled");

        this.reorg();

        assertEq(token.bridgedBalanceOf(satellites[0]), 100, "the settlement was in the reorged window");
        assertEq(lite.balanceOf(satellites[0]), 60, "the satellite burn stands");
        _relayOnce(gateway.queueLength() - 1);
        assertEq(token.bridgedBalanceOf(satellites[0]), 60, "settled again from the replayed proof");
        invariant_MF1_eachHolderIsTheReferenceSatelliteAndHeldAmounts();
    }

    /* ----- Private ----- */

    function _finalize() internal {
        finalSnapshot = vm.snapshotState();
        finalQueueLength = gateway.queueLength();
        delete satelliteLog;
    }

    /// @dev Delivers a queue entry not yet delivered. A message for the satellite is held back until the state that
    ///  sent it is final, and is logged for replay once delivered.
    function _relayOnce(uint256 index) internal {
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(index);
        if (message.deliveries != 0 || message.dropped) return;
        bool toSatellite = _toSatellite(message.recipient);
        if (toSatellite && index >= finalQueueLength && !deliverBeforeFinality) return;
        try gateway.relay(index) {
            if (toSatellite) _logDelivery(message.sender, message.payload);
        } catch { }
    }

    function _requeue(address sender, bytes memory recipient, bytes memory payload) internal returns (uint256) {
        vm.prank(sender);
        gateway.sendMessage(recipient, payload, new bytes[](0));
        return gateway.queueLength() - 1;
    }

    function _logDelivery(address sender, bytes memory payload) internal {
        satelliteLog.push(SatelliteAction({ isResend: false, sender: sender, payload: payload, id: 0 }));
    }

    function _toSatellite(bytes memory recipient) internal view returns (bool) {
        (, address account) = InteroperableAddress.parseEvmV1(recipient);
        return account == address(lite);
    }

    function _liteEnvelope() internal view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(POLYGON, address(lite));
    }

    /// @dev What actor `actor` holds in flight: mints instructed to its wallet and not yet minted, and burns done on
    ///  its wallet whose proof has not settled.
    function _heldFor(uint256 actor) internal view returns (uint256 held) {
        for (uint256 id = 1; id < delegationAmount.length; id++) {
            if (delegationActor[id] == actor && lite.delegationSeen(id) == 0) held += delegationAmount[id];
        }
        for (uint256 id = 1; id < recallActor.length; id++) {
            if (recallActor[id] == actor && token.pendingRecall(id).amount != 0) held += lite.burnedFor(id);
        }
    }

    /// @dev Every balance, position, total and pause flag a delivery could move. Transport records are left out: a
    ///  copy is expected to be recorded as received.
    function _fingerprint() internal view returns (bytes32 print) {
        print = keccak256(
            abi.encode(
                token.totalSupply(),
                token.totalBridged(),
                token.totalInTransit(),
                token.paused(),
                token.isInboundPaused(polygon),
                lite.mints(),
                lite.burns()
            )
        );
        for (uint256 i = 0; i < ACTORS; i++) {
            print = keccak256(
                abi.encode(
                    print,
                    token.balanceOf(actors[i]),
                    token.bridgedBalanceOf(satellites[i]),
                    ledger.positionOf(address(identities[i])),
                    lite.balanceOf(satellites[i])
                )
            );
        }
        for (uint256 id = 1; id < recallActor.length; id++) {
            print = keccak256(abi.encode(print, token.pendingRecall(id).amount));
        }
    }

}
