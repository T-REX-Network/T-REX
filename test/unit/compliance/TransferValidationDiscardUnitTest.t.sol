// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
import { IToken } from "contracts/token/IToken.sol";
import { Token } from "contracts/token/Token.sol";
import { RecordingModule, TrackerOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { TokenReservationStub } from "test/unit/compliance/helpers/TokenReservationStub.sol";

contract TransferValidationDiscardUnitTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;
    uint256 internal constant OPTIMISM = 10;
    uint64 internal constant VALIDITY_WINDOW = 1 hours;
    uint64 internal constant POLYGON_WINDOW = 30 minutes;
    uint64 internal constant OPTIMISM_WINDOW = 45 minutes;
    uint256 internal constant ISSUED_AT = 1_700_000_000;
    uint256 internal constant BRIDGED_BALANCE = 100;

    bytes32 internal polygon = _evmChainKey(POLYGON);
    bytes32 internal optimism = _evmChainKey(OPTIMISM);
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");
    address internal aliceId;
    address internal bobId;
    bytes internal fromSat;
    bytes internal toSat;
    bytes internal toOptimism;

    function setUp() public override {
        super.setUp();
        fromSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
        toSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
        toOptimism = InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("bobOnOptimism"));
        aliceId = aliceIdentity;
        bobId = bobIdentity;

        mc.setDefaultValidityWindow(VALIDITY_WINDOW);
        mc.setReconciliationWindow(polygon, POLYGON_WINDOW);
        mc.setReconciliationWindow(optimism, OPTIMISM_WINDOW);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        // The wallet's room lives on the token now, so the mocked token address gets a stub with real
        // arithmetic for those few selectors; `vm.mockCall` still wins for everything mocked explicitly.
        vm.etch(token, address(new TokenReservationStub()).code);
        TokenReservationStub(token).setBridgedBalance(fromSat, BRIDGED_BALANCE);
        vm.mockCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), abi.encode(bytes32(0)));
        _bind(fromSat, aliceIdentity);
        _bind(toSat, bobIdentity);
        _bind(toOptimism, bobIdentity);

        vm.warp(ISSUED_AT);
    }

    /* ----- Status ----- */

    function test_statusOf_Success_WhenFreshlyIssued() public {
        uint256 id = _issue();

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        ITransferValidation.Validation memory state = mc.validationOf(id);
        assertEq(uint8(state.status), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(state.executedAmount, 0);
        assertEq(state.legWallet.length, 0);
    }

    function test_statusOf_Success_WhenPastExpiryButNotPastReleaseAt() public {
        uint256 id = _issue();

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + 1);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW);
        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function test_statusOf_Success_WhenPastReleaseAtItDerivesExpired() public {
        uint256 id = _issue();

        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));
        assertEq(uint8(mc.validationOf(id).status), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function test_statusOf_Success_WhenAwaitingTheMintLegNeverDerivesExpired() public {
        uint256 id = _issueCrossChainWithBurnLeg();

        vm.warp(ISSUED_AT + 10 * VALIDITY_WINDOW);

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
    }

    function test_statusOf_RevertWhen_IdWasNeverIssued() public {
        uint256 id = _issue();

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, 0));
        mc.statusOf(0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, id + 1));
        mc.statusOf(id + 1);
    }

    function test_stateOf_Success_WhenIdWasNeverIssued() public view {
        ITransferValidation.Validation memory state = mc.validationOf(42);

        assertEq(uint8(state.status), 0);
        assertEq(state.executedAmount, 0);
    }

    /* ----- Discard ----- */

    function test_discardExpiredValidations_Success_WhenExpired() public {
        _track();
        address recorder = _bindAfterTransferModule();
        uint256 id = _issue();
        assertEq(mc.pendingInOf(bobId), 90);
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectCall(token, abi.encodeCall(IToken.releaseFromValidation, (fromSat, 90)), 1);
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationDiscarded(id);
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(mc.pendingInOf(bobId), 0, "the reservation is released");
        assertEq(mc.pendingOutOf(aliceId), 0);
        assertEq(mc.positionOf(aliceId), BRIDGED_BALANCE, "nothing moved");
        assertEq(mc.positionOf(bobId), 0);
        assertEq(RecordingModule(recorder).transferActionCalls(), 0, "a discard involves no module");
    }

    function test_discardExpiredValidations_Success_WhenTheReleaseFreesTheRoomForTheNext() public {
        _track();
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.prank(keeperAccount);
        mc.discardExpiredValidations(_ids(id));

        vm.expectCall(token, abi.encodeCall(IToken.reserveForValidation, (fromSat, 90)), 1);
        vm.prank(aliceIdentity);
        uint256 next = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
        assertEq(mc.validationOf(next).amountMax, 90, "issued as if the discarded one never happened");
    }

    /// @notice A relocation between one identity's wallets reserves nothing against the identity, so its
    ///         discard has nothing to give back there. The wallet's share is still released.
    function test_discardExpiredValidations_Success_WhenNothingWasReservedAgainstTheIdentities() public {
        _track();
        _bind(toSat, aliceIdentity);
        uint256 id = _issue();
        assertTrue(mc.validationOf(id).relocation, "nothing was reserved against the identities");
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectCall(token, abi.encodeCall(IToken.releaseFromValidation, (fromSat, 90)), 1);
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(mc.pendingInOf(bobId), 0);
    }

    function test_discardExpiredValidations_Success_WhenBatchingSeveralIds() public {
        _track();
        uint256 first = _issue();
        uint256 second = _issue();
        assertEq(mc.pendingInOf(bobId), 100, "both reserved, the second capped by the wallet");
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationDiscarded(first);
        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.ValidationDiscarded(second);
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(ids);

        assertEq(uint8(mc.statusOf(first)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(uint8(mc.statusOf(second)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(mc.pendingInOf(bobId), 0);
        assertEq(mc.pendingOutOf(aliceId), 0);
    }

    function test_discardExpiredValidations_RevertWhen_CallerIsNotTheKeeper() public {
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.prank(agentAccount);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agentAccount));
        mc.discardExpiredValidations(_ids(id));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        mc.discardExpiredValidations(_ids(id));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        mc.discardExpiredValidations(_ids(id));
    }

    function test_discardExpiredValidations_RevertWhen_IdWasNeverIssued() public {
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, 7));
        mc.discardExpiredValidations(_ids(7));
    }

    function test_discardExpiredValidations_RevertWhen_NotYetReleasable() public {
        uint256 id = _issue();
        uint64 releaseAt = uint64(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW);

        vm.warp(releaseAt);
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotReleasable.selector, id, releaseAt));
        mc.discardExpiredValidations(_ids(id));

        assertEq(uint8(mc.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function test_discardExpiredValidations_RevertWhen_AlreadyDiscarded() public {
        uint256 id = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        vm.prank(keeperAccount);
        mc.discardExpiredValidations(_ids(id));

        vm.prank(keeperAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotDiscardable.selector, id, uint8(ITransferValidation.ValidationStatus.Discarded)
            )
        );
        mc.discardExpiredValidations(_ids(id));
    }

    function test_discardExpiredValidations_RevertWhen_AwaitingTheMintLegWhateverTheClock() public {
        _track();
        uint256 id = _issueCrossChainWithBurnLeg();
        vm.warp(ISSUED_AT + 10 * VALIDITY_WINDOW);

        vm.prank(keeperAccount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotDiscardable.selector,
                id,
                uint8(ITransferValidation.ValidationStatus.AwaitingMint)
            )
        );
        mc.discardExpiredValidations(_ids(id));

        assertEq(mc.pendingInOf(bobId), 90, "a pinned validation keeps its reservation");
    }

    function test_discardExpiredValidations_RevertWhen_OneIdOfTheBatchIsRefused() public {
        _track();
        uint256 expired = _issue();
        vm.warp(ISSUED_AT + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        uint256 pending = _issue();
        uint64 pendingReleaseAt = uint64(block.timestamp + VALIDITY_WINDOW + POLYGON_WINDOW);

        uint256[] memory ids = new uint256[](2);
        ids[0] = expired;
        ids[1] = pending;
        vm.prank(keeperAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotReleasable.selector, pending, pendingReleaseAt));
        mc.discardExpiredValidations(ids);

        assertEq(uint8(mc.statusOf(expired)), uint8(ITransferValidation.ValidationStatus.Expired));
        assertEq(mc.pendingInOf(bobId), 100, "the whole batch is rolled back");
    }

    function _issue() private returns (uint256 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toSat, 10, 90, "");
    }

    function _issueCrossChainWithBurnLeg() private returns (uint256 id) {
        vm.prank(aliceIdentity);
        id = mc.requestTransferValidation(fromSat, toOptimism, 10, 90, "");
        vm.prank(token);
        mc.handleSettlement(
            polygon, MessageTypesLib.SettlementNotification({ validationId: id, from: fromSat, to: "", amount: 50 })
        );
    }

    function _ids(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _bind(bytes memory wallet, address identity) private {
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", wallet), abi.encode(identity));
        vm.mockCall(
            registry, abi.encodeWithSignature("isWalletVerified(bytes)", wallet), abi.encode(identity != address(0))
        );
    }

    /// @dev Gives alice's identity the position her satellite wallet holds, the way a real deployment does:
    ///  through the token's mint hook. The compliance keeps positions from the token's first mint, so there
    ///  is nothing to turn on.
    function _track() private {
        address aliceNative = makeAddr("aliceNative");
        vm.mockCall(registry, abi.encodeWithSignature("identity(address)", aliceNative), abi.encode(aliceIdentity));
        vm.prank(token);
        mc.created(aliceNative, BRIDGED_BALANCE);
    }

    function _bindAfterTransferModule() private returns (address module) {
        module = address(
            new ModuleProxy(address(new TrackerOnlyModule()), abi.encodeCall(RecordingModule.initialize, ()))
        );
        mc.addModule(module);
    }

    function _evmChainKey(uint256 chainId) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
