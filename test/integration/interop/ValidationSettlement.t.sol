// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { ReentrantModule } from "test/integration/mocks/ReentrantModule.sol";

/// @dev One-leg settlements through the real messaging layer: a same-chain movement, a native sender, a native
///      recipient, the deadline that never refuses a leg, every mismatch that is rejected or orphans the validation,
///      and the two emergencies: a replay pauses its chain's inbound, a never-issued id parks the leg and pauses the
///      chain that executed it. The token itself is never halted by a settlement.
contract ValidationSettlementTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;
    uint256 internal constant NATIVE_BALANCE = 500;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    CappedRecipientModule internal cappedRule;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal nativeBob;
    uint256 internal issuedAt;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);

        cappedRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(cappedRule));
        vm.stopPrank();

        vm.startPrank(agent);
        token.mint(alice, NATIVE_BALANCE);
        token.unpause();
        vm.stopPrank();
        issuedAt = block.timestamp;
    }

    // ==== happy path Tests ====

    /// @notice A same-chain leg with both wallets settles: ledger, module, status, events.
    function test_handleSettlement_Success_WhenSameChainLegSettles() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(keccak256(aliceSat), keccak256(bobSat), id, aliceSat, bobSat, 95);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationSettled(id, polygon, 95);
        polygonGateway.relay(index);

        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - 95);
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertEq(token.totalBridged(), BALANCE);
        assertEq(token.totalSupply(), BALANCE + NATIVE_BALANCE);
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "released once settled");
        assertEq(ledger.positionOf(address(bobIdentity)), 95, "and became a position");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        ITransferValidation.Validation memory state = boundCompliance.validationOf(id);
        assertEq(state.executedAmount, 95);
        assertFalse(token.paused());
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)));
    }

    /// @notice A satellite sender toward a native wallet settles with one leg from the sender's chain, crediting
    ///         the recipient under the validation it consumed.
    function test_handleSettlement_Success_WhenTheRecipientIsNative() public {
        bytes32 id = _issue(aliceSat, nativeBob, 10, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, nativeBob, 40));

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledToNative(keccak256(aliceSat), bob, id, aliceSat, 40);
        polygonGateway.relay(index);

        assertEq(token.balanceOf(bob), 40);
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - 40);
        assertEq(token.totalBridged(), BALANCE - 40);
        assertEq(token.totalSupply(), BALANCE + NATIVE_BALANCE);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
    }

    /// @notice Past the release deadline but before any discard, a leg settles normally: the slot is still held.
    function test_handleSettlement_Success_WhenTheLegArrivesAfterTheDeadlineBeforeAnyDiscard() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));

        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1 days);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));

        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertFalse(boundCompliance.isIssuancePaused(polygon));
    }

    // ==== mismatch Tests: the leg is consumed, nothing moves, and the chain that executed it is paused ====

    /// @notice A leg outside the issued bounds, carrying the issued hash, is rejected: the validation stays
    ///         `Pending`, nothing moves, and the chain that executed it is paused. Once lifted, the next
    ///         out-of-bounds leg is rejected the same way.
    function test_handleSettlement_Success_WhenAmountIsOutsideTheBoundsTheLegIsRejected() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);

        uint256 below = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 80));
        _relayRejected(polygonGateway, polygon, below, id, 80);

        uint256 above = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 101));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, polygon));
        polygonGateway.relay(above);
        _assertNothingApplied(polygonGateway, above);

        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        _relayRejected(polygonGateway, polygon, above, id, 101);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE);
        assertEq(token.bridgedBalanceOf(bobSat), 0);
    }

    /// @notice A leg naming a wallet other than the issued ones, or leaving one empty on a same-chain validation,
    ///         is rejected under the issued hash: the validation stays `Pending` and the chain is paused.
    function test_handleSettlement_Success_WhenAWalletIsNotTheIssuedOneTheLegIsRejected() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        bytes memory carolSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("carolOnPolygon"));

        uint256 wrongTo = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, carolSat, 95));
        uint256 wrongFrom = _liteSettles(polygonGateway, token, _settlement(id, carolSat, bobSat, 95));
        uint256 emptyTo = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, "", 95));

        _relayRejected(polygonGateway, polygon, wrongTo, id, 95);
        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        _relayRejected(polygonGateway, polygon, wrongFrom, id, 95);
        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        _relayRejected(polygonGateway, polygon, emptyTo, id, 95);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE);
        assertEq(token.bridgedBalanceOf(bobSat), 0);
        assertEq(token.bridgedBalanceOf(carolSat), 0);
    }

    /// @notice A leg from a chain neither wallet lives on is rejected: that chain's inbound is paused, the
    ///         sender's chain is untouched and the validation stays `Pending`.
    function test_handleSettlement_Success_WhenTheLegComesFromAnotherChainItIsRejected() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(optimismGateway, token, _settlement(id, aliceSat, bobSat, 95));

        _relayRejected(optimismGateway, optimism, index, id, 95);

        assertFalse(token.isInboundPaused(polygon));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(token.bridgedBalanceOf(bobSat), 0);
    }

    /// @notice A leg outside the bounds under a hash this chain never issued is the trace of a body a reorg
    ///         orphaned: while nothing had landed the validation ends `Orphaned`, its reservation comes back on
    ///         both sides, nothing moves, and the chain that executed it is paused.
    function test_handleSettlement_Success_WhenAnOutOfBoundsLegUnderAnotherHashOrphansTheValidation() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));
        assertEq(ledger.pendingInOf(address(bobIdentity)), 100, "reserved at the maximum while pending");
        assertEq(token.reservedOf(aliceSat), 100, "and held on the sender's wallet");
        bytes32 orphanedHash = keccak256("orphaned body");
        uint256 index = _liteSettles(polygonGateway, token, _settlementUnder(id, aliceSat, bobSat, 101, orphanedHash));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationOrphaned(id, polygon, 101, orphanedHash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(index);

        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)));
        assertTrue(token.isInboundPaused(polygon));
        assertFalse(token.paused());
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Orphaned));
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "the recipient's reservation is released");
        assertEq(token.reservedOf(aliceSat), 0, "and so is the sender's hold");
        assertEq(boundCompliance.validationOf(id).executedAmount, 0);
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE);
        assertEq(token.bridgedBalanceOf(bobSat), 0);
    }

    /// @notice A leg inside the issued terms under another hash settles as any other, and says so: the body the
    ///         Lite executed diverged from the one issued, but the ledger can absorb what it reports.
    function test_handleSettlement_Success_WhenAnInRangeLegUnderAnotherHashSettlesAndReportsTheDivergence() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        bytes32 otherHash = keccak256("other body");
        uint256 index = _liteSettles(polygonGateway, token, _settlementUnder(id, aliceSat, bobSat, 95, otherHash));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.SettlementBodyDiverged(id, polygon, otherHash);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationSettled(id, polygon, 95);
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(boundCompliance.validationOf(id).executedAmount, 95);
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - 95);
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertFalse(token.isInboundPaused(polygon));
        assertFalse(token.paused());
    }

    // ==== emergency Tests ====

    /// @notice The same content delivered again as a fresh message applies nothing and pauses the inbound of the
    ///         chain it came from; the token itself keeps running. The replay is consumed, not left deliverable.
    function test_handleSettlement_Success_WhenAReplayedSettlementPausesTheChain() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        MessageTypesLib.SettlementNotification memory leg = _settlement(id, aliceSat, bobSat, 95);
        polygonGateway.relay(_liteSettles(polygonGateway, token, leg));
        uint256 replay = _liteSettles(polygonGateway, token, leg);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(replay);

        assertTrue(token.isInboundPaused(polygon));
        assertFalse(token.paused());
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(replay)));
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
    }

    /// @notice Once a chain's inbound is paused its next leg is refused and stays deliverable; the pauser lifts
    ///         the pause and the same delivery settles.
    function test_handleSettlement_RevertWhen_TheChainsInboundIsPaused_ThenSettlesOnceLifted() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));
        vm.prank(agent);
        token.setInboundPaused(polygon, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, polygon));
        polygonGateway.relay(index);
        _assertNothingApplied(polygonGateway, index);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));

        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundUnpaused(polygon);
        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
    }

    /// @notice A notification for an id never issued applies nothing to the ledger: the leg is parked under its
    ///         id for the request that may still issue it, the chain that executed it is paused, and the token
    ///         itself keeps running. A second leg from the same chain for the parked id is a replay.
    function test_handleSettlement_Success_WhenANeverIssuedIdParksTheLegAndPausesTheChain() public {
        bytes32 unknown = bytes32(uint256(999));
        bytes32 hash = keccak256("body");
        uint256 index = _liteSettles(polygonGateway, token, _settlementUnder(unknown, aliceSat, bobSat, 95, hash));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.SettlementParked(unknown, polygon, 95, hash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(index);

        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)));
        assertFalse(token.paused());
        assertTrue(token.isInboundPaused(polygon));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE);
        assertEq(token.bridgedBalanceOf(bobSat), 0);
        ITransferValidation.ParkedLeg memory parked = boundCompliance.parkedLegOf(unknown, polygon);
        assertTrue(parked.exists);
        assertEq(parked.amount, 95);
        assertEq(parked.hash, hash);
        assertEq(parked.from, aliceSat);
        assertEq(parked.to, bobSat);
        assertEq(boundCompliance.validationOf(unknown).executedAmount, 0);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, unknown));
        boundCompliance.statusOf(unknown);

        uint256 replay = _liteSettles(polygonGateway, token, _settlementUnder(unknown, aliceSat, bobSat, 95, hash));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReplayedSettlement(unknown, polygon);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(replay);
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(replay)));
        assertEq(boundCompliance.parkedLegOf(unknown, polygon).amount, 95, "the first leg stays parked");
    }

    /// @notice While the token is paused a valid leg is refused and stays deliverable; once unpaused it settles.
    function test_handleSettlement_RevertWhen_TheTokenIsPaused() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        polygonGateway.relay(index);
        _assertNothingApplied(polygonGateway, index);

        vm.prank(agent);
        token.unpause();
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
    }

    /// @notice Only the pauser lifts a halt.
    function test_unpause_RevertWhen_CallerIsNotThePauser() public {
        vm.prank(agent);
        token.pause();
        assertTrue(token.paused());

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, deployer));
        token.unpause();

        vm.prank(agent);
        token.unpause();
        assertFalse(token.paused());
    }

    // ==== reentrancy Tests ====

    function test_handleSettlement_RevertWhen_ATrackerRelaysAnotherSettlementFromItsHook() public {
        ReentrantModule attacker = _bindReentrantModule();
        bytes32 first = _issue(aliceSat, bobSat, 10, 100);
        bytes32 second = _issue(aliceSat, bobSat, 10, 100);
        uint256 outer = _liteSettles(polygonGateway, token, _settlement(first, aliceSat, bobSat, 40));
        uint256 nested = _liteSettles(polygonGateway, token, _settlement(second, aliceSat, bobSat, 50));
        attacker.armRelay(address(polygonGateway), nested);

        polygonGateway.relay(outer);

        _assertNestedRelayRejected(attacker, nested);
        assertEq(uint8(boundCompliance.statusOf(first)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(uint8(boundCompliance.statusOf(second)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(token.bridgedBalanceOf(bobSat), 40);

        polygonGateway.relay(nested);

        assertEq(uint8(boundCompliance.statusOf(second)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 90);
    }

    function test_handleSettlement_RevertWhen_ATrackerRelaysASettlementFromATransferHook() public {
        ReentrantModule attacker = _bindReentrantModule();
        bytes32 id = _issue(aliceSat, bobSat, 10, 100);
        uint256 nested = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 40));
        attacker.armRelay(address(polygonGateway), nested);

        vm.prank(alice);
        token.transfer(bob, 10);

        _assertNestedRelayRejected(attacker, nested);
        assertEq(token.balanceOf(bob), 10);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(token.bridgedBalanceOf(bobSat), 0);
    }

    function _bindReentrantModule() private returns (ReentrantModule attacker) {
        attacker = ReentrantModule(
            address(new ERC1967Proxy(address(new ReentrantModule()), abi.encodeCall(ReentrantModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(attacker));
    }

    function _assertNestedRelayRejected(ReentrantModule attacker, uint256 nested) private view {
        assertFalse(attacker.lastCallSucceeded());
        assertEq(
            attacker.lastCallReturnData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        _assertNothingApplied(polygonGateway, nested);
    }

    function _issue(bytes memory from, bytes memory to, uint256 min, uint256 max) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), from, to, min, max);
    }

    function _assertNothingApplied(ERC7786GatewayMock gateway, uint256 index) private view {
        assertFalse(token.messageReceived(address(gateway), gateway.receiveIdFor(index)));
    }

    /// @dev Relays a leg carrying the issued hash that fails the substantive gate: it is rejected, consumed, and
    ///  pauses the inbound of `chainKey`.
    function _relayRejected(ERC7786GatewayMock gateway, bytes32 chainKey, uint256 index, bytes32 id, uint256 amount)
        private
    {
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.SettlementRejected(id, chainKey, amount, boundCompliance.validationOf(id).hash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(chainKey);
        gateway.relay(index);

        assertTrue(token.messageReceived(address(gateway), gateway.receiveIdFor(index)), "the leg is consumed");
        assertTrue(token.isInboundPaused(chainKey), "the chain that executed it is paused");
        assertFalse(token.paused(), "the token keeps running");
    }

}
