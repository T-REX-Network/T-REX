// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A lost validation leg sent again through the real messaging layer: who may, what goes out, that it is the
///      issued leg byte for byte, that it still settles, and every refusal.
contract ValidationResendTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 100;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal bobOptimism;
    address internal stranger = makeAddr("stranger");
    bytes32 internal id;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        vm.prank(agent);
        token.unpause();

        id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);
        polygonGateway.drop(0);
    }

    /* ----- Success ----- */

    /// @notice The identity resends the lost leg: a second queue entry with the first one's payload, announced,
    ///         and the route pinned at issuance is not pinned again.
    function test_resendValidation_Success_WhenTheIdentityResendsTheLostLeg() public {
        vm.recordLogs();
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationResent(id, polygon);
        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(polygonGateway.queuedMessage(1).payload, polygonGateway.queuedMessage(0).payload);
        assertEq(token.pinnedRouteFor(id, polygon), address(polygonGateway));
        _assertNotPinnedAgain();
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function test_resendValidation_Success_WhenAnAgentResendsForTheWallet() public {
        vm.prank(agent);
        boundCompliance.resendValidation(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(_decodeQueuedValidation(polygonGateway, 1).validationId, id);
    }

    /// @notice The resent leg is the one the Lite executes against: relayed, it settles like the original would.
    function test_resendValidation_Success_WhenTheResentLegSettles() public {
        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(id, polygon, bobSat, "");

        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 50));
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - 50);
        assertEq(token.bridgedBalanceOf(bobSat), 50);
    }

    /// @notice On two legs each chain's leg is resent on its own; the other queue is untouched.
    function test_resendValidation_Success_WhenOnlyTheMintLegIsResent() public {
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);
        optimismGateway.drop(0);

        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(crossChain, optimism, bobOptimism, "");

        assertEq(optimismGateway.queueLength(), 2);
        assertEq(optimismGateway.queuedMessage(1).payload, optimismGateway.queuedMessage(0).payload);
        assertEq(polygonGateway.queueLength(), 2, "the burn leg's queue holds the two issued legs only");
    }

    /// @notice Once the burn landed the receiving Lite still needs its leg to check the burn message against, so the
    ///         recipient's leg goes again past `expiry`, until `releaseAt`; the mint it then reports settles the pair.
    function test_resendValidation_Success_WhenTheRecipientsLegIsResentAfterTheBurnLanded() public {
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);
        optimismGateway.drop(0);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(crossChain, token, aliceSat, 10)));
        assertEq(uint8(boundCompliance.statusOf(crossChain)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        vm.warp(boundCompliance.validationOf(crossChain).expiry + 1);

        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(crossChain, optimism, bobOptimism, "");

        assertEq(optimismGateway.queueLength(), 2);
        assertEq(optimismGateway.queuedMessage(1).payload, optimismGateway.queuedMessage(0).payload);

        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(crossChain, token, bobOptimism, 10)));
        assertEq(uint8(boundCompliance.statusOf(crossChain)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobOptimism), 10);
    }

    /// @notice After the burn the recipient is the one left waiting, so their identity may resend the leg toward
    ///         their chain; the sender's leg stays the sender's.
    function test_resendValidation_Success_WhenTheRecipientResendsTheLegTowardTheirChain() public {
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);
        optimismGateway.drop(0);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(crossChain, token, aliceSat, 10)));

        vm.prank(address(bobIdentity));
        boundCompliance.resendValidation(crossChain, optimism, bobOptimism, "");

        assertEq(optimismGateway.queueLength(), 2);
        assertEq(optimismGateway.queuedMessage(1).payload, optimismGateway.queuedMessage(0).payload);
    }

    /// @notice A spender travels with the object, so it is part of what must be supplied again.
    function test_resendValidation_Success_WhenTheSpenderIsSuppliedAgain() public {
        bytes memory spender = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));
        vm.prank(address(aliceIdentity));
        bytes32 withSpender = boundCompliance.requestTransferValidation(aliceSat, bobSat, 1, 5, spender, _salt());

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, withSpender));
        boundCompliance.resendValidation(withSpender, polygon, bobSat, "");

        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(withSpender, polygon, bobSat, spender);
        assertEq(_decodeQueuedValidation(polygonGateway, 2).spender, spender);
    }

    /* ----- Refusals ----- */

    function test_resendValidation_RevertWhen_IdWasNeverIssued() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, bytes32(uint256(999))));
        boundCompliance.resendValidation(bytes32(uint256(999)), polygon, bobSat, "");
    }

    function test_resendValidation_RevertWhen_TheRecipientDiffersFromTheIssued() public {
        bytes memory other = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("charlieOnPolygon"));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationBodyMismatch.selector, id));
        boundCompliance.resendValidation(id, polygon, other, "");
    }

    function test_resendValidation_RevertWhen_TheChainIsNotPartOfTheValidation() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotPartOfValidation.selector, id, optimism));
        boundCompliance.resendValidation(id, optimism, bobSat, "");
    }

    function test_resendValidation_RevertWhen_AStrangerAsks() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, stranger, aliceSat));
        boundCompliance.resendValidation(id, polygon, bobSat, "");
    }

    function test_resendValidation_RevertWhen_TheRecipientAsksForTheSendersLeg() public {
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);

        vm.prank(address(bobIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, address(bobIdentity), aliceSat)
        );
        boundCompliance.resendValidation(crossChain, polygon, aliceSat, "");
    }

    /// @notice A leg resent from `releaseAt` on could land after the pair was resolved and the burned amount
    ///         returned, and mint it a second time; the resend stops one window ahead of the resolution.
    function test_resendValidation_RevertWhen_TheRecipientsLegIsResentFromReleaseAtOn() public {
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);
        optimismGateway.drop(0);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(crossChain, token, aliceSat, 10)));
        uint64 releaseAt = boundCompliance.validationOf(crossChain).releaseAt;
        vm.warp(releaseAt);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationExpired.selector, crossChain, releaseAt));
        boundCompliance.resendValidation(crossChain, optimism, bobOptimism, "");
        assertEq(optimismGateway.queueLength(), 1);
    }

    /// @notice A burn that lands after a discard is past `releaseAt` by definition, so the discarded pair is out of
    ///         the resend's reach; only `resolveStuckValidation` ends it.
    function test_resendValidation_RevertWhen_TheBurnLandedAfterADiscard() public {
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);
        optimismGateway.drop(0);
        uint256 burn = _liteSettles(polygonGateway, token, _burnLeg(crossChain, token, aliceSat, 10));
        vm.warp(boundCompliance.validationOf(crossChain).releaseAt + 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = crossChain;
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(ids);
        polygonGateway.relay(burn);
        assertEq(
            uint8(boundCompliance.statusOf(crossChain)),
            uint8(ITransferValidation.ValidationStatus.DiscardedAwaitingMint)
        );

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotResendable.selector,
                crossChain,
                uint8(ITransferValidation.ValidationStatus.DiscardedAwaitingMint)
            )
        );
        boundCompliance.resendValidation(crossChain, optimism, bobOptimism, "");
    }

    /// @notice Once the keeper resolved the pair the burned amount is back with the sender; a leg sent now could
    ///         only make the receiving chain mint against it.
    function test_resendValidation_RevertWhen_ThePairWasResolved() public {
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);
        optimismGateway.drop(0);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(crossChain, token, aliceSat, 10)));
        ITransferValidation.Validation memory stored = boundCompliance.validationOf(crossChain);
        vm.warp(stored.releaseAt + (stored.releaseAt - stored.expiry) + 1);
        vm.prank(keeper);
        boundCompliance.resolveStuckValidation(crossChain);
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotResendable.selector,
                crossChain,
                uint8(ITransferValidation.ValidationStatus.Resolved)
            )
        );
        boundCompliance.resendValidation(crossChain, optimism, bobOptimism, "");
        assertEq(optimismGateway.queueLength(), 1);
    }

    function test_resendValidation_RevertWhen_PastTheSatelliteDeadline() public {
        uint64 expiry = boundCompliance.validationOf(id).expiry;
        vm.warp(expiry);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationExpired.selector, id, expiry));
        boundCompliance.resendValidation(id, polygon, bobSat, "");
    }

    function test_resendValidation_RevertWhen_AlreadySettled() public {
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 50));
        polygonGateway.relay(index);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotResendable.selector, id, uint8(ITransferValidation.ValidationStatus.Settled)
            )
        );
        boundCompliance.resendValidation(id, polygon, bobSat, "");
    }

    /// @notice The sender's leg was consumed by the burn: sending it again could only make the Lite execute twice.
    function test_resendValidation_RevertWhen_TheSendersLegIsResentAfterTheBurnLanded() public {
        bytes32 crossChain = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(crossChain, token, aliceSat, 10)));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotResendable.selector,
                crossChain,
                uint8(ITransferValidation.ValidationStatus.AwaitingMint)
            )
        );
        boundCompliance.resendValidation(crossChain, polygon, aliceSat, "");
    }

    /// @notice A chain whose inbound is paused holds its reports at the gateway; a leg sent now could only add to
    ///         what cannot land.
    function test_resendValidation_RevertWhen_TheChainsInboundIsPaused() public {
        vm.prank(agent);
        token.setInboundPaused(polygon, true);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, polygon));
        boundCompliance.resendValidation(id, polygon, bobSat, "");
        assertEq(polygonGateway.queueLength(), 1);
    }

    /// @notice The issuance pause means nothing more goes toward that chain; a resend is no exception.
    function test_resendValidation_RevertWhen_IssuanceTowardTheChainIsPaused() public {
        vm.prank(deployer);
        boundCompliance.setIssuancePaused(polygon, true);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, polygon));
        boundCompliance.resendValidation(id, polygon, bobSat, "");
        assertEq(polygonGateway.queueLength(), 1);
    }

    /// @notice Only the current peer's settlement is accepted, so the leg goes where an issuance would go now.
    function test_resendValidation_Success_WhenThePeerChangedTheLegGoesToTheCurrentPeer() public {
        bytes memory newPeer = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("newPolygonLite"));
        vm.prank(deployer);
        token.setPeer(polygon, newPeer);

        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(id, polygon, bobSat, "");

        assertEq(polygonGateway.queuedMessage(1).recipient, newPeer);
        assertEq(polygonGateway.queuedMessage(1).payload, polygonGateway.queuedMessage(0).payload);
    }

    /// @notice The pause stops movements; a settlement is one, an issuance and a resend are not.
    function test_resendValidation_Success_WhenTheTokenIsPaused() public {
        vm.prank(agent);
        token.pause();

        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(id, polygon, bobSat, "");

        assertEq(polygonGateway.queueLength(), 2);
    }

    /// @notice The leg's settlement is matched against the pinned gateway, so it is never resent through another.
    function test_resendValidation_RevertWhen_TheRouteWasSwitched() public {
        ERC7786GatewayMock replacement = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(replacement));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationAlreadyRouted.selector, id, polygon, address(polygonGateway))
        );
        boundCompliance.resendValidation(id, polygon, bobSat, "");

        assertEq(replacement.queueLength(), 0);
    }

    function _assertNotPinnedAgain() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EventsLib.ValidationRoutePinned.selector, "the route was pinned again");
        }
    }

}
