// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
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

/// @dev One-leg settlements through the real messaging layer: a same-chain movement, a native sender, a native
///      recipient, the deadline that never refuses a leg, every mismatch that does, and the two emergencies that
///      halt the token.
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
        uint256 id = _issue(aliceSat, bobSat, 90, 100);
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
        uint256 id = _issue(aliceSat, nativeBob, 10, 100);
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
        uint256 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));

        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1 days);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));

        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertFalse(boundCompliance.isIssuancePaused(polygon));
    }

    // ==== mismatch Tests, every one retryable ====

    function test_handleSettlement_RevertWhen_AmountIsOutsideTheBounds() public {
        uint256 id = _issue(aliceSat, bobSat, 90, 100);

        uint256 below = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 80));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementOutOfBounds.selector, id, 80));
        polygonGateway.relay(below);

        uint256 above = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 101));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementOutOfBounds.selector, id, 101));
        polygonGateway.relay(above);

        _assertNothingApplied(polygonGateway, below);
        _assertNothingApplied(polygonGateway, above);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function test_handleSettlement_RevertWhen_AWalletIsNotTheIssuedOne() public {
        uint256 id = _issue(aliceSat, bobSat, 90, 100);
        bytes memory carolSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("carolOnPolygon"));

        uint256 wrongTo = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, carolSat, 95));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        polygonGateway.relay(wrongTo);

        uint256 wrongFrom = _liteSettles(polygonGateway, token, _settlement(id, carolSat, bobSat, 95));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        polygonGateway.relay(wrongFrom);

        uint256 emptyTo = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, "", 95));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        polygonGateway.relay(emptyTo);

        _assertNothingApplied(polygonGateway, wrongTo);
        _assertNothingApplied(polygonGateway, wrongFrom);
        _assertNothingApplied(polygonGateway, emptyTo);
    }

    function test_handleSettlement_RevertWhen_TheLegComesFromAnotherChain() public {
        uint256 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(optimismGateway, token, _settlement(id, aliceSat, bobSat, 95));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        optimismGateway.relay(index);

        _assertNothingApplied(optimismGateway, index);
    }

    // ==== emergency Tests ====

    /// @notice The same content delivered again as a fresh message applies nothing and halts the token.
    function test_handleSettlement_Success_WhenAReplayedSettlementHaltsTheToken() public {
        uint256 id = _issue(aliceSat, bobSat, 90, 100);
        MessageTypesLib.SettlementNotification memory leg = _settlement(id, aliceSat, bobSat, 95);
        polygonGateway.relay(_liteSettles(polygonGateway, token, leg));
        uint256 replay = _liteSettles(polygonGateway, token, leg);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.expectEmit(false, false, false, true, address(token));
        emit PausableUpgradeable.Paused(address(polygonGateway));
        polygonGateway.relay(replay);

        assertTrue(token.paused());
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(replay)));
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
    }

    /// @notice A notification for an id never issued applies nothing, writes nothing and halts the token.
    function test_handleSettlement_Success_WhenANeverIssuedIdHaltsTheToken() public {
        uint256 index = _liteSettles(polygonGateway, token, _settlement(999, aliceSat, bobSat, 95));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReplayedSettlement(999, polygon);
        polygonGateway.relay(index);

        assertTrue(token.paused());
        assertEq(token.bridgedBalanceOf(bobSat), 0);
        assertEq(boundCompliance.validationOf(999).executedAmount, 0);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, 999));
        boundCompliance.statusOf(999);
    }

    /// @notice While the token is paused a valid leg is refused and stays deliverable; once unpaused it settles.
    function test_handleSettlement_RevertWhen_TheTokenIsPaused() public {
        uint256 id = _issue(aliceSat, bobSat, 90, 100);
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
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(999, aliceSat, bobSat, 95)));
        assertTrue(token.paused());

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, deployer));
        token.unpause();

        vm.prank(agent);
        token.unpause();
        assertFalse(token.paused());
    }

    function _issue(bytes memory from, bytes memory to, uint256 min, uint256 max) private returns (uint256) {
        return _requestValidation(address(aliceIdentity), from, to, min, max);
    }

    function _assertNothingApplied(ERC7786GatewayMock gateway, uint256 index) private view {
        assertFalse(token.messageReceived(address(gateway), gateway.receiveIdFor(index)));
    }

}
