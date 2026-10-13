// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ISettlementHandler } from "contracts/interop/ISettlementHandler.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { TokenLedgerLib } from "contracts/token/TokenLedgerLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import { RecordingModule, TrackerOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { Utils } from "test/unit/helpers/Utils.sol";

/// @dev The two movements that change where a position sits and never who owns it: a holder delegates native
///      balance out to their own satellite wallet, and an agent recalls a satellite position back onto the
///      holder's native wallet through an instruction the satellite answers with a burn proof.
contract DelegationAndRecallTest is InteropSuiteTest {

    uint256 internal constant MINTED = 1000;

    ERC7786GatewayMock polygonGateway;
    ERC7786GatewayMock optimismGateway;
    IComplianceLedger ledger;
    IERC3643IdentityRegistry registry;

    bytes aliceSat;
    bytes aliceOptimism;
    bytes bobSat;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        ledger = IComplianceLedger(address(boundCompliance));
        registry = token.identityRegistry();

        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOnPolygon"));
        aliceOptimism = _linkSatelliteWallet(aliceIdentity, OPTIMISM, makeAccount("aliceOnOptimism"));
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();
    }

    function _delegate(address caller, uint256 amount) private returns (bytes32) {
        vm.prank(caller);
        return token.delegateOut(alice, aliceSat, amount);
    }

    function _instruct(uint256 amount) private returns (uint256) {
        vm.prank(agent);
        return token.instructRecall(aliceSat, amount, alice);
    }

    function _proof(ERC7786GatewayMock gateway, uint256 recallId, bytes memory wallet, uint256 amount)
        private
        returns (uint256)
    {
        return _liteSends(gateway, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, wallet, amount)));
    }

    /// @dev Registry writes never relink a wallet, so a relink is simulated as the owner swapping the registry's
    ///  storage for one that binds `wallet` to `identity`, and the factory not knowing the wallet.
    function _swapStorageAnswer(address wallet, IIdentity identity) private {
        _unbindGlobally(wallet);
        vm.mockCall(
            address(idFactory),
            abi.encodeWithSelector(
                idFactory.getIdentityIncludingRevoked.selector, InteroperableAddress.formatEvmV1(block.chainid, wallet)
            ),
            abi.encode(address(0), IIdentityFactory.AccountStatus.None)
        );
        vm.mockCall(
            address(registry.identityStorage()),
            abi.encodeCall(registry.identityStorage().storedIdentity, (wallet)),
            abi.encode(address(identity))
        );
    }

    /// @dev Makes the global registry forget `wallet`.
    function _unbindGlobally(address wallet) private {
        vm.mockCall(
            address(idFactory),
            abi.encodeWithSelector(
                idFactory.getIdentity.selector, InteroperableAddress.formatEvmV1(block.chainid, wallet)
            ),
            abi.encode(address(0))
        );
    }

    function _assertPartition() private view {
        uint256 bridged = token.bridgedBalanceOf(aliceSat) + token.bridgedBalanceOf(bobSat)
            + token.bridgedBalanceOf(aliceOptimism) + token.totalInTransit();
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + bridged, MINTED, "buckets do not sum to the supply");
        assertEq(token.totalSupply(), MINTED, "the supply moved");
        assertEq(token.totalBridged(), bridged, "totalBridged drifted");
    }

    /* ----- delegateOut ----- */

    function test_delegateOut_Success_WhenTheHolderDelegatesTheirOwnBalance() public {
        vm.expectCall(
            address(boundCompliance),
            abi.encodeCall(IModularCompliance.agentTransferred, (alice, alice, 400, MovementKindLib.DELEGATION)),
            1
        );
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, address(0), 400);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.DelegatedOut(alice, keccak256(aliceSat), 1, aliceSat, 400);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(
            MessageTypesLib.Message.MINT_INSTRUCTION, polygon, polygonGateway.receiveIdFor(0)
        );

        bytes32 sendId = _delegate(alice, 400);

        assertEq(sendId, polygonGateway.receiveIdFor(0));
        assertEq(token.balanceOf(alice), MINTED - 400);
        assertEq(token.bridgedBalanceOf(aliceSat), 400);
        assertEq(token.totalBridged(), 400);
        assertEq(ledger.positionOf(address(aliceIdentity)), MINTED, "location moved, ownership did not");
        _assertPartition();

        (uint8 messageType,, bytes memory body) =
            abi.decode(polygonGateway.queuedMessage(0).payload, (uint8, uint8, bytes));
        assertEq(messageType, uint8(MessageTypesLib.Message.MINT_INSTRUCTION));
        MessageTypesLib.MintInstruction memory instruction = MessageTypesLib.decodeMintInstruction(body);
        assertEq(instruction.delegationId, 1);
        assertEq(instruction.toWallet, aliceSat);
        assertEq(instruction.amount, 400);
        assertEq(instruction.holder, alice);
    }

    function test_delegateOut_Success_WhenTheIdentityDelegatesForItsWallet() public {
        _delegate(address(aliceIdentity), 100);

        assertEq(token.bridgedBalanceOf(aliceSat), 100);
    }

    function test_delegateOut_Success_WhenAnAgentDelegatesForTheHolder() public {
        _delegate(agent, 100);

        assertEq(token.bridgedBalanceOf(aliceSat), 100);
    }

    /// @notice A change of the holder's owner is followed by the delegation hook, which adds the burned amount
    ///         back when it migrates the balance: the whole pre-delegation balance lands on the new owner.
    function test_delegateOut_Success_WhenTheHolderWasRelinkedToAnotherIdentity() public {
        _swapStorageAnswer(alice, charlieIdentity);
        bytes memory charlieSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));

        vm.prank(alice);
        token.delegateOut(alice, charlieSat, 400);

        assertEq(ledger.positionOf(address(charlieIdentity)), MINTED, "the new owner holds the whole position");
        assertEq(ledger.positionOf(address(aliceIdentity)), 0, "nothing stays on the old owner");
        assertEq(token.bridgedBalanceOf(charlieSat), 400);
    }

    function test_delegateOut_RevertWhen_AStrangerDelegatesForAnotherWallet() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        token.delegateOut(alice, aliceSat, 1);
    }

    function test_delegateOut_RevertWhen_Paused() public {
        vm.prank(agent);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.delegateOut(alice, aliceSat, 1);
    }

    /// @notice No more supply goes to a chain whose reports are suspect; the burn is undone with the refusal.
    function test_delegateOut_RevertWhen_TheChainsInboundIsPaused() public {
        vm.prank(agent);
        token.setInboundPaused(polygon, true);
        uint256 nativeBefore = token.balanceOf(alice);
        uint256 bridgedBefore = token.bridgedBalanceOf(aliceSat);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, polygon));
        token.delegateOut(alice, aliceSat, 1);

        assertEq(token.balanceOf(alice), nativeBefore);
        assertEq(token.bridgedBalanceOf(aliceSat), bridgedBefore);
    }

    function test_delegateOut_RevertWhen_TheHolderIsFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, alice));
        token.delegateOut(alice, aliceSat, 1);
    }

    function test_delegateOut_RevertWhen_AmountIsZero() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        token.delegateOut(alice, aliceSat, 0);
    }

    function test_delegateOut_RevertWhen_AmountExceedsTheFreeBalance() public {
        vm.prank(agent);
        token.freezePartialTokens(alice, 700);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 300, 400));
        token.delegateOut(alice, aliceSat, 400);
    }

    function test_delegateOut_RevertWhen_TheSatelliteWalletBelongsToAnotherIdentity() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletsNotLinked.selector, alice, bobSat));
        token.delegateOut(alice, bobSat, 1);
    }

    function test_delegateOut_RevertWhen_TheSatelliteWalletIsNotLinked() public {
        bytes memory stray = _satelliteEnvelope(POLYGON, makeAddr("Stray"));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletsNotLinked.selector, alice, stray));
        token.delegateOut(alice, stray, 1);
    }

    /// @notice A revoked wallet still resolves to its identity, but it is not eligible for new activity.
    function test_delegateOut_RevertWhen_TheSatelliteWalletWasRevoked() public {
        _revokeWallet(aliceIdentity, aliceSat);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, aliceSat));
        token.delegateOut(alice, aliceSat, 1);
    }

    /// @notice A closed chain refuses the send, and the burn goes with it.
    function test_delegateOut_RevertWhen_TheChainIsClosed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        token.delegateOut(alice, aliceOptimism, 100);

        assertEq(token.balanceOf(alice), MINTED);
        assertEq(token.totalBridged(), 0);
    }

    function test_delegateOut_RevertWhen_TheWalletIsNative() public {
        bytes memory native = _satelliteEnvelope(block.chainid, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, native));
        token.delegateOut(alice, native, 1);
    }

    /* ----- instructRecall ----- */

    function test_instructRecall_Success_WhenAnAgentOrdersARecall() public {
        _delegate(alice, 500);

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.RecallInstructed(1, keccak256(aliceSat), alice, aliceSat, 200);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(
            MessageTypesLib.Message.RECALL_INSTRUCTION, polygon, polygonGateway.receiveIdFor(1)
        );

        uint256 recallId = _instruct(200);

        assertEq(recallId, 1);
        TokenLedgerLib.PendingRecall memory recall = token.pendingRecall(1);
        assertEq(recall.walletKey, keccak256(aliceSat));
        assertEq(recall.chainKey, polygon);
        assertEq(recall.nativeWallet, alice);
        assertEq(recall.amount, 200);
        assertEq(recall.gateway, address(polygonGateway), "the dispatch gateway is recorded");
        assertEq(recall.peerKey, keccak256(token.peerFor(polygon)), "and the dispatch peer");

        (uint8 messageType,, bytes memory body) =
            abi.decode(polygonGateway.queuedMessage(1).payload, (uint8, uint8, bytes));
        assertEq(messageType, uint8(MessageTypesLib.Message.RECALL_INSTRUCTION));
        MessageTypesLib.RecallInstruction memory instruction = MessageTypesLib.decodeRecallInstruction(body);
        assertEq(instruction.recallId, 1);
        assertEq(instruction.wallet, aliceSat);
        assertEq(instruction.amount, 200);
        assertEq(instruction.nativeWallet, alice);

        assertEq(token.balanceOf(alice), MINTED - 500, "an instruction moves nothing");
        assertEq(token.bridgedBalanceOf(aliceSat), 500);
    }

    function test_instructRecall_RevertWhen_TheCallerIsNotAnAgent() public {
        _delegate(alice, 500);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        token.instructRecall(aliceSat, 100, alice);
    }

    function test_instructRecall_RevertWhen_AmountIsZero() public {
        _delegate(alice, 500);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        token.instructRecall(aliceSat, 0, alice);
    }

    function test_instructRecall_RevertWhen_TheNativeWalletIsZero() public {
        _delegate(alice, 500);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        token.instructRecall(aliceSat, 100, address(0));
    }

    function test_instructRecall_RevertWhen_AmountExceedsTheBridgedPosition() public {
        _delegate(alice, 500);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, aliceSat, 500, 501));
        token.instructRecall(aliceSat, 501, alice);
    }

    /// @notice Reservations do not bound a recall: the satellite burns what is left and proves that. The reservation
    ///         then exceeds the position until the validation is discarded, and every read of the gap floors at zero.
    function test_instructRecall_Success_WhenPartOfThePositionIsReserved() public {
        _delegate(alice, 500);
        uint256 validationId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 1, 300);
        assertEq(token.availableOf(aliceSat), 200);
        uint256 recallId = _instruct(500);
        assertEq(recallId, 1);

        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 500));

        assertEq(token.bridgedBalanceOf(aliceSat), 0);
        assertEq(token.reservedOf(aliceSat), 300, "the reservation outlives the position");
        assertEq(token.availableOf(aliceSat), 0);
        uint256 settlement = _liteSettles(polygonGateway, token, _settlement(validationId, aliceSat, bobSat, 100));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, aliceSat, 0, 100));
        polygonGateway.relay(settlement);
        _assertPartition();
    }

    /// @notice One recall at a time per wallet: the second waits for the first to be answered or recovered.
    function test_instructRecall_RevertWhen_TheWalletAlreadyHasAnOpenRecall() public {
        _delegate(alice, 500);
        uint256 first = _instruct(100);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RecallPending.selector, keccak256(aliceSat), first));
        token.instructRecall(aliceSat, 100, alice);

        polygonGateway.relay(_proof(polygonGateway, first, aliceSat, 100));
        assertEq(_instruct(100), 2, "answered, so the next one may be issued");
    }

    function test_instructRecall_RevertWhen_TheWalletsAreNotLinked() public {
        _delegate(alice, 500);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletsNotLinked.selector, bob, aliceSat));
        token.instructRecall(aliceSat, 100, bob);
    }

    function test_instructRecall_RevertWhen_TheChainIsClosed() public {
        vm.prank(agent);
        TokenLedgerHarness(address(token)).ledgerDelegateOut(alice, aliceOptimism, 100);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        token.instructRecall(aliceOptimism, 100, alice);

        uint256 amount = token.pendingRecall(1).amount;
        assertEq(amount, 0, "nothing recorded");
    }

    function test_instructRecall_Success_WhilePaused() public {
        _delegate(alice, 500);
        vm.prank(agent);
        token.pause();

        assertEq(_instruct(100), 1);
    }

    /* ----- The burn proof ----- */

    function _instructed() private returns (uint256 recallId) {
        _delegate(alice, 500);
        recallId = _instruct(200);
    }

    function test_handleBurnProof_Success_WhenTheProofAnswersTheInstruction() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId, aliceSat, 200);

        vm.expectCall(address(boundCompliance), abi.encodeWithSelector(ISettlementHandler.handleSettlement.selector), 0);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.BurnProofReceived(polygon, recallId, aliceSat, 200);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.RecallSettled(recallId, polygon, 200);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.Recalled(keccak256(aliceSat), alice, aliceSat, 200);
        polygonGateway.relay(index);

        assertEq(token.balanceOf(alice), MINTED - 500 + 200);
        assertEq(token.bridgedBalanceOf(aliceSat), 300);
        assertEq(token.totalBridged(), 300);
        assertEq(ledger.positionOf(address(aliceIdentity)), MINTED, "location moved, ownership did not");
        uint256 amount = token.pendingRecall(recallId).amount;
        assertEq(amount, 0, "the instruction is consumed");
        assertFalse(token.paused());
        _assertPartition();
    }

    /// @notice The satellite may have had less to burn than instructed; the proof carries what it burned.
    function test_handleBurnProof_Success_WhenTheSatelliteBurnedLess() public {
        uint256 recallId = _instructed();

        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 150));

        assertEq(token.balanceOf(alice), MINTED - 500 + 150);
        assertEq(token.bridgedBalanceOf(aliceSat), 350);
        uint256 amount = token.pendingRecall(recallId).amount;
        assertEq(amount, 0, "one proof closes the instruction whatever it proved");
        _assertPartition();
    }

    function test_handleBurnProof_RevertWhen_TheProofExceedsTheInstruction() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId, aliceSat, 201);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RecallAmountExceeded.selector, recallId, 200, 201));
        polygonGateway.relay(index);

        assertFalse(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)));
        uint256 amount = token.pendingRecall(recallId).amount;
        assertEq(amount, 200, "the instruction stays open");
    }

    /// @notice The satellite had nothing left to burn: a proof of zero closes the instruction and credits nothing.
    function test_handleBurnProof_Success_WhenTheSatelliteHadNothingLeft() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId, aliceSat, 0);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.RecallSettled(recallId, polygon, 0);
        polygonGateway.relay(index);

        assertEq(token.balanceOf(alice), MINTED - 500, "nothing credited");
        assertEq(token.bridgedBalanceOf(aliceSat), 500, "nothing debited");
        uint256 amount = token.pendingRecall(recallId).amount;
        assertEq(amount, 0, "the instruction is closed");
        assertFalse(token.paused());
    }

    function test_handleBurnProof_HaltsTheToken_WhenTheRecallWasNeverIssued() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId + 1, aliceSat, 200);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ReplayedBurnProof(recallId + 1, polygon);
        polygonGateway.relay(index);

        assertTrue(token.paused());
        assertEq(token.balanceOf(alice), MINTED - 500, "nothing minted");
        assertEq(token.bridgedBalanceOf(aliceSat), 500, "nothing debited");
    }

    /// @notice A consumed instruction answered again, under a fresh transport id, is the replay emergency.
    /// @notice The proof that settled a recall, delivered again under a fresh receive id, is a duplicate: it is
    ///         accepted, credits nothing and pauses nothing.
    function test_handleBurnProof_Success_WhenTheSettledProofIsDeliveredAgain() public {
        uint256 recallId = _instructed();
        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 200));
        uint256 duplicate = _proof(polygonGateway, recallId, aliceSat, 200);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.BurnProofDuplicate(recallId, polygon);
        polygonGateway.relay(duplicate);

        assertFalse(token.paused());
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(duplicate)));
        assertEq(token.balanceOf(alice), MINTED - 500 + 200, "credited once");
    }

    /// @notice A different proof for a settled recall is a message the token cannot account for, from a chain it
    ///         can name: that chain's inbound pauses, the token keeps running.
    function test_handleBurnProof_PausesTheChain_WhenAConflictingProofArrivesForASettledRecall() public {
        uint256 recallId = _instructed();
        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 200));
        uint256 conflicting = _proof(polygonGateway, recallId, aliceSat, 150);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ReplayedBurnProof(recallId, polygon);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(conflicting);

        assertTrue(token.isInboundPaused(polygon));
        assertFalse(token.paused());
        assertEq(token.balanceOf(alice), MINTED - 500 + 200, "credited once");
    }

    function test_handleBurnProof_RevertWhen_TheProofNamesAnotherWallet() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId, bobSat, 200);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RecallMismatch.selector, recallId));
        polygonGateway.relay(index);

        assertFalse(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)));
    }

    /// @notice Only the peer the recall was dispatched to may answer it, so a proof from another chain's peer is
    ///         refused at admission.
    function test_handleBurnProof_RevertWhen_TheProofComesFromAnotherChain() public {
        uint256 recallId = _instructed();
        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        uint256 index = _proof(optimismGateway, recallId, aliceSat, 200);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SenderNotPeer.selector, optimism, InteroperableAddress.formatEvmV1(OPTIMISM, address(token))
            )
        );
        optimismGateway.relay(index);
    }

    function test_handleBurnProof_RevertWhen_Paused_ThenAppliesOnceUnpaused() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId, aliceSat, 200);
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        polygonGateway.relay(index);
        assertFalse(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)));

        vm.prank(agent);
        token.unpause();
        polygonGateway.relay(index);

        assertEq(token.balanceOf(alice), MINTED - 500 + 200);
    }

    /// @notice The satellite already burned, so a broken link is repaired in the registry and the proof
    ///         redelivered, never refused for good.
    function test_handleBurnProof_RevertWhen_TheLinkWasBroken_ThenAppliesOnceRepaired() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId, aliceSat, 200);
        _swapStorageAnswer(alice, charlieIdentity);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletsNotLinked.selector, alice, aliceSat));
        polygonGateway.relay(index);

        _swapStorageAnswer(alice, aliceIdentity);
        polygonGateway.relay(index);

        assertEq(token.balanceOf(alice), MINTED - 500 + 200);
    }

    /// @notice Frozen stops onward movement; it does not strand a position the satellite already burned.
    function test_handleBurnProof_Success_WhenTheNativeWalletIsFrozen() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId, aliceSat, 200);
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        polygonGateway.relay(index);

        assertEq(token.balanceOf(alice), MINTED - 500 + 200);
    }

    /// @notice A validation that settled first left the wallet short: the proof waits, deliverable, and a proof
    ///         for what is actually left applies.
    function test_handleBurnProof_RevertWhen_TheBridgedPositionNoLongerCovers_ThenAppliesForWhatIsLeft() public {
        uint256 recallId = _instructed();
        uint256 validationId = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 400, 400);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(validationId, aliceSat, bobSat, 400)));
        assertEq(token.bridgedBalanceOf(aliceSat), 100);
        uint256 tooMuch = _proof(polygonGateway, recallId, aliceSat, 200);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, aliceSat, 100, 200));
        polygonGateway.relay(tooMuch);
        assertFalse(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(tooMuch)));

        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 100));

        assertEq(token.balanceOf(alice), MINTED - 500 + 100);
        assertEq(token.bridgedBalanceOf(aliceSat), 0);
        _assertPartition();

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ReplayedBurnProof(recallId, polygon);
        polygonGateway.relay(tooMuch);
        assertTrue(token.isInboundPaused(polygon), "the stale 200 proof conflicts with the 100 that settled");
        assertFalse(token.paused());
    }

    /* ----- resend ----- */

    function _delegationFields(uint256 amount) private view returns (bytes memory) {
        return abi.encode(aliceSat, amount, alice, token.peerFor(polygon));
    }

    /// @notice A resend repeats the mint instruction byte for byte, moves nothing, and leaves the commitment as is.
    function test_resend_Success_WhenADelegationIsResent() public {
        _delegate(alice, 400);
        bytes32 commitmentSlot = keccak256(abi.encode(uint256(1), _treXSlot(11)));
        bytes32 commitment = vm.load(address(token), commitmentSlot);
        bytes memory fields = _delegationFields(400);

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.InstructionResent(0, 1, polygon, polygonGateway.receiveIdFor(1));
        vm.prank(agent);
        token.resend(0, 1, fields);

        assertEq(polygonGateway.queuedMessage(1).payload, polygonGateway.queuedMessage(0).payload, "byte for byte");
        assertEq(vm.load(address(token), commitmentSlot), commitment, "commitment unchanged");
        assertEq(token.balanceOf(alice), MINTED - 400, "debited once");
        assertEq(token.bridgedBalanceOf(aliceSat), 400);
    }

    function test_resend_RevertWhen_TheDelegationFieldsDiffer() public {
        _delegate(alice, 400);
        bytes memory fields = _delegationFields(401);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DelegationMismatch.selector, 1));
        token.resend(0, 1, fields);
    }

    function test_resend_RevertWhen_TheDelegationWasNeverIssued() public {
        bytes memory fields = _delegationFields(1);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DelegationMismatch.selector, 7));
        token.resend(0, 7, fields);
    }

    /// @notice A resend never retargets: once the chain's peer changed, the delegation cannot be resent.
    function test_resend_RevertWhen_ThePeerChangedSinceTheDelegation() public {
        _delegate(alice, 400);
        bytes memory fields = _delegationFields(400);
        vm.prank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("NewLite")));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PeerChanged.selector, polygon));
        token.resend(0, 1, fields);
    }

    function test_resend_Success_WhenARecallIsResent() public {
        uint256 recallId = _instructed();

        vm.prank(agent);
        token.resend(1, recallId, abi.encode(aliceSat));

        uint256 last = polygonGateway.queueLength() - 1;
        assertEq(polygonGateway.queuedMessage(last).payload, polygonGateway.queuedMessage(last - 1).payload);
        assertEq(token.pendingRecall(recallId).amount, 200);
    }

    function test_resend_RevertWhen_TheRecallIsSettled() public {
        uint256 recallId = _instructed();
        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 200));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RecallNotPending.selector, recallId));
        token.resend(1, recallId, abi.encode(aliceSat));
    }

    function test_resend_RevertWhen_TheRecallWalletDiffers() public {
        uint256 recallId = _instructed();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RecallMismatch.selector, recallId));
        token.resend(1, recallId, abi.encode(bobSat));
    }

    function test_resend_RevertWhen_TheKindIsUnknown() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownResendKind.selector, 2));
        token.resend(2, 1, "");
    }

    function test_resend_RevertWhen_TheCallerIsNotAnAgent() public {
        uint256 recallId = _instructed();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        token.resend(1, recallId, abi.encode(aliceSat));
    }

    /* ----- Owner sync on recall ----- */

    /// @dev Bob holds 900 natively and 100 on his Polygon wallet. Alice's native wallet, holding 1000 and counted
    ///      under Alice's identity, is relinked to Bob's identity. Another wallet of Alice's identity holds 300.
    function _relinkedRecall() private returns (uint256 recallId) {
        vm.startPrank(agent);
        token.mint(bob, 1000);
        registry.registerIdentity(another, aliceIdentity, 0);
        token.mint(another, 300);
        vm.stopPrank();
        vm.prank(bob);
        token.delegateOut(bob, bobSat, 100);

        _swapStorageAnswer(alice, bobIdentity);

        vm.prank(agent);
        recallId = token.instructRecall(bobSat, 100, alice);
    }

    /// @notice The compliance follows the relink before the credit lands: Alice's 1000 moves to Bob's identity, the
    ///         100 coming home stays counted where it already was, and Alice's other 300 stay hers. Positions are
    ///         right now and after the wallet's next movement.
    function test_handleBurnProof_Success_WhenTheNativeWalletWasRelinked() public {
        uint256 recallId = _relinkedRecall();

        polygonGateway.relay(_proof(polygonGateway, recallId, bobSat, 100));

        assertEq(ledger.positionOf(address(aliceIdentity)), 300, "the old owner keeps only its other wallet");
        assertEq(ledger.positionOf(address(bobIdentity)), 900 + 1000 + 100, "the new owner holds everything else");
        assertEq(token.balanceOf(alice), 1100);
        assertEq(ledger.positionGap(), 0);

        vm.prank(alice);
        token.transfer(charlie, 100);

        assertEq(ledger.positionOf(address(aliceIdentity)), 300);
        assertEq(ledger.positionOf(address(bobIdentity)), 1900);
        assertEq(ledger.positionOf(address(charlieIdentity)), 100);
        assertEq(ledger.positionGap(), 0);
    }

    /// @notice A relink of a wallet the old owner held nothing in: the sync moves nothing and the credit lands.
    function test_handleBurnProof_Success_WhenTheRelinkedWalletWasEmpty() public {
        vm.prank(alice);
        token.transfer(charlie, MINTED);
        uint256 recallId = _relinkedRecall();

        polygonGateway.relay(_proof(polygonGateway, recallId, bobSat, 100));

        assertEq(ledger.positionOf(address(aliceIdentity)), 300);
        assertEq(ledger.positionOf(address(bobIdentity)), 1000);
        assertEq(token.balanceOf(alice), 100);
        assertEq(ledger.positionGap(), 0);
    }

    /// @notice The sync is the owner change alone: no movement is counted, so no tracker module is told.
    function test_syncOwner_Success_WithoutCallingAnyModule() public {
        TrackerOnlyModule tracker = TrackerOnlyModule(
            address(new ModuleProxy(address(new TrackerOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(tracker));
        uint256 recallId = _relinkedRecall();
        uint256 callsBefore = tracker.totalHookCalls();

        vm.expectCall(address(boundCompliance), abi.encodeCall(IModularCompliance.syncOwner, (alice)), 1);
        polygonGateway.relay(_proof(polygonGateway, recallId, bobSat, 100));

        assertEq(tracker.totalHookCalls(), callsBefore, "no module was called");
    }

    function test_syncOwner_RevertWhen_TheCallerIsNotTheBoundToken() public {
        vm.prank(alice);
        vm.expectRevert();
        IModularCompliance(address(boundCompliance)).syncOwner(alice);
    }

    /* ----- Admission pinned to the dispatch route and peer ----- */

    /// @notice The route switched while the instruction was out: the proof through the gateway it was dispatched
    ///         through still settles, once.
    function test_handleBurnProof_Success_WhenTheRouteSwitchedAfterTheInstruction() public {
        uint256 recallId = _instructed();
        ERC7786GatewayMock newGateway = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(newGateway));

        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 200));

        assertEq(token.balanceOf(alice), MINTED - 500 + 200);
        assertEq(token.pendingRecall(recallId).amount, 0);
    }

    function test_handleBurnProof_RevertWhen_ItComesThroughAnotherTrustedGateway() public {
        uint256 recallId = _instructed();
        ERC7786GatewayMock newGateway = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(newGateway));
        uint256 index = _proof(newGateway, recallId, aliceSat, 200);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.GatewayNotPinned.selector, address(newGateway), recallId, polygon)
        );
        newGateway.relay(index);
    }

    /// @notice A gateway the network stopped trusting is refused even though the recall was pinned to it.
    function test_handleBurnProof_RevertWhen_ThePinnedGatewayIsNoLongerTrusted() public {
        uint256 recallId = _instructed();
        uint256 index = _proof(polygonGateway, recallId, aliceSat, 200);
        trustedGatewayRegistry.setTrustedGateway(address(polygonGateway), false);

        vm.expectRevert();
        polygonGateway.relay(index);
        assertEq(token.pendingRecall(recallId).amount, 200);
    }

    /// @notice The peer changed after the instruction: the peer it was dispatched to still answers it, any other
    ///         author is refused.
    function test_handleBurnProof_Success_WhenThePeerChangedAfterTheInstruction() public {
        uint256 recallId = _instructed();
        address newLite = makeAddr("NewLite");
        vm.prank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, newLite));
        uint256 fromNewLite = _queue(
            polygonGateway, newLite, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, aliceSat, 200))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SenderNotPeer.selector, polygon, InteroperableAddress.formatEvmV1(POLYGON, newLite)
            )
        );
        polygonGateway.relay(fromNewLite);

        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 200));
        assertEq(token.balanceOf(alice), MINTED - 500 + 200);
    }

    /// @notice A resend after a route switch moves the admitted gateway to the current route, which delivered it.
    function test_resend_Success_WhenTheRouteSwitched_TheAnswerComesThroughTheNewRoute() public {
        uint256 recallId = _instructed();
        ERC7786GatewayMock newGateway = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(newGateway));

        vm.prank(agent);
        token.resend(1, recallId, abi.encode(aliceSat));
        assertEq(token.pendingRecall(recallId).gateway, address(newGateway));

        newGateway.relay(_proof(newGateway, recallId, aliceSat, 200));
        assertEq(token.balanceOf(alice), MINTED - 500 + 200);
    }

    /* ----- Storage ----- */

    /// @dev `lastRecallId` at 7, `settledProofs` at 9, `lastDelegationId` at 10, `delegations` at 11.
    function test_storage_PinsTheCountersCommitmentsAndSettledProofs() public {
        uint256 recallId = _instructed();
        bytes memory body = abi.encode(_burnProof(recallId, aliceSat, 200));
        polygonGateway.relay(_proof(polygonGateway, recallId, aliceSat, 200));

        assertEq(uint256(vm.load(address(token), _treXSlot(7))), 1, "lastRecallId");
        assertEq(uint256(vm.load(address(token), _treXSlot(10))), 1, "lastDelegationId");
        assertEq(
            vm.load(address(token), keccak256(abi.encode(recallId, _treXSlot(9)))),
            keccak256(abi.encode(polygon, body)),
            "settledProofs"
        );
        assertEq(
            vm.load(address(token), keccak256(abi.encode(uint256(1), _treXSlot(11)))),
            keccak256(abi.encode(polygon, keccak256(token.peerFor(polygon)), aliceSat, uint256(500), alice)),
            "delegations"
        );
    }

    function _treXSlot(uint256 offset) private pure returns (bytes32) {
        return bytes32(uint256(Utils.erc7201("erc3643.storage.TREXToken")) + offset);
    }

}
