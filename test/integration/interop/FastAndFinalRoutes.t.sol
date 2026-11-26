// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Each chain has two routes. The fast one carries validations out and nothing else; the final one carries
///      instructions out and is the only one settlements and burn proofs are taken from. Every message type is
///      tried on each route.
contract FastAndFinalRoutesTest is InteropSuiteTest {

    ERC7786GatewayMock finalGateway;
    ERC7786GatewayMock fastGateway;
    ERC7786GatewayMock optimismGateway;

    bytes aliceSat;
    bytes bobSat;

    function setUp() public override {
        super.setUp();
        finalGateway = _newTrustedGateway(POLYGON);
        fastGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(finalGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        _setFastRoute(POLYGON, address(fastGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), 1000);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();
    }

    function _setFastRoute(uint256 chainId, address gateway) private {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(chainId);
        vm.prank(deployer);
        token.setFastRoute(chainType, chainReference, gateway);
    }

    function _issue() private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 100);
    }

    function _proof(ERC7786GatewayMock gateway, uint256 recallId, uint256 amount) private returns (uint256) {
        return _liteSends(gateway, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, aliceSat, amount)));
    }

    /* ----- Configuration ----- */

    function test_setFastRoute_Success_WhenSetIndependentlyPerChain() public {
        ERC7786GatewayMock other = _newTrustedGateway(POLYGON);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.FastRouteSet(polygon, address(other));
        _setFastRoute(POLYGON, address(other));

        assertEq(token.fastRouteFor(polygon), address(other));
        assertEq(token.routeFor(polygon), address(finalGateway), "the final route is untouched");
        assertEq(token.fastRouteFor(optimism), address(0), "another chain is untouched");
        assertEq(token.routeFor(optimism), address(optimismGateway));
    }

    function test_setFastRoute_Success_WhenZeroUnsetsIt() public {
        _setFastRoute(POLYGON, address(0));

        assertEq(token.fastRouteFor(polygon), address(0));
        assertTrue(token.isChainOpen(polygon), "the chain stays open on its final route");
    }

    function test_setFastRoute_RevertWhen_TheGatewayIsNotTrusted() public {
        address untrusted = address(new ERC7786GatewayMock(POLYGON));
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GatewayNotTrusted.selector, untrusted));
        vm.prank(deployer);
        token.setFastRoute(chainType, chainReference, untrusted);
    }

    function test_setFastRoute_RevertWhen_TheGatewayIsTheFinalRoute() public {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.FastRouteIsFinalRoute.selector, polygon, address(finalGateway))
        );
        vm.prank(deployer);
        token.setFastRoute(chainType, chainReference, address(finalGateway));
    }

    function test_setRoute_RevertWhen_TheGatewayIsTheFastRoute() public {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FastRouteIsFinalRoute.selector, polygon, address(fastGateway)));
        vm.prank(deployer);
        token.setRoute(chainType, chainReference, address(fastGateway));
    }

    function test_setFastRoute_RevertWhen_TheCallerHasNoRole() public {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(POLYGON);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        token.setFastRoute(chainType, chainReference, address(0));
    }

    /* ----- Validation ----- */

    function test_validation_GoesOutOnTheFastRouteAndPinsTheFinalRoute() public {
        bytes32 id = _issue();

        assertEq(fastGateway.queueLength(), 1, "the validation took the fast route");
        assertEq(finalGateway.queueLength(), 0);
        assertEq(_decodeQueuedValidation(fastGateway, 0).validationId, id);
        assertEq(token.pinnedRouteFor(id, polygon), address(finalGateway), "its settlement comes back on final");
    }

    function test_validation_GoesOutOnTheFinalRouteWhenTheFastRouteIsUnset() public {
        _setFastRoute(POLYGON, address(0));

        bytes32 id = _issue();

        assertEq(finalGateway.queueLength(), 1);
        assertEq(fastGateway.queueLength(), 0);
        assertEq(token.pinnedRouteFor(id, polygon), address(finalGateway));
    }

    /// @dev The registry dropped the fast gateway: issuance falls back to the final route rather than stopping.
    function test_validation_GoesOutOnTheFinalRouteWhenTheFastGatewayIsNoLongerTrusted() public {
        trustedGatewayRegistry.setTrustedGateway(address(fastGateway), false);

        _issue();

        assertEq(finalGateway.queueLength(), 1);
        assertEq(fastGateway.queueLength(), 0);
    }

    /// @dev Without a final route nothing could settle the validation, so the fast route alone opens nothing.
    function test_validation_RevertWhen_OnlyTheFastRouteIsSet() public {
        _openEvmChain(token, POLYGON, address(0));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        _issue();

        assertEq(fastGateway.queueLength(), 0);
    }

    function test_resendValidation_GoesOutOnTheFastRouteAgain() public {
        bytes32 id = _issue();

        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(id, polygon, bobSat, "");

        assertEq(fastGateway.queueLength(), 2);
        assertEq(fastGateway.queuedMessage(1).payload, fastGateway.queuedMessage(0).payload);
        assertEq(finalGateway.queueLength(), 0);
    }

    /* ----- Instructions ----- */

    function test_mintInstruction_GoesOutOnTheFinalRouteOnly() public {
        vm.prank(alice);
        token.delegateOut(alice, aliceSat, 100);

        assertEq(finalGateway.queueLength(), 1);
        assertEq(fastGateway.queueLength(), 0, "never on the fast route");
        (MessageTypesLib.Message messageType,) = MessageTypesLib.decode(finalGateway.queuedMessage(0).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.MINT_INSTRUCTION));
    }

    function test_mintInstruction_RevertWhen_OnlyTheFastRouteIsSet() public {
        _openEvmChain(token, POLYGON, address(0));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        vm.prank(alice);
        token.delegateOut(alice, aliceSat, 100);
    }

    function test_recallInstruction_GoesOutOnTheFinalRouteOnly() public {
        vm.prank(agent);
        token.instructRecall(aliceSat, 100, alice);

        assertEq(finalGateway.queueLength(), 1);
        assertEq(fastGateway.queueLength(), 0, "never on the fast route");
        (MessageTypesLib.Message messageType,) = MessageTypesLib.decode(finalGateway.queuedMessage(0).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.RECALL_INSTRUCTION));
    }

    function test_recallInstruction_RevertWhen_OnlyTheFastRouteIsSet() public {
        _openEvmChain(token, POLYGON, address(0));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        vm.prank(agent);
        token.instructRecall(aliceSat, 100, alice);
    }

    /* ----- Settlement ----- */

    function test_settlement_Success_FromTheFinalRoute() public {
        bytes32 id = _issue();

        finalGateway.relay(_liteSettles(finalGateway, token, _settlement(id, aliceSat, bobSat, 60)));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 60);
    }

    function test_settlement_RevertWhen_FromTheFastRoute() public {
        bytes32 id = _issue();
        uint256 index = _liteSettles(fastGateway, token, _settlement(id, aliceSat, bobSat, 60));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GatewayIsFastRoute.selector, address(fastGateway), polygon));
        fastGateway.relay(index);

        assertFalse(token.messageReceived(address(fastGateway), fastGateway.receiveIdFor(index)));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    /* ----- Burn proof ----- */

    function test_burnProof_Success_FromTheFinalRoute() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(aliceSat, 100, alice);

        finalGateway.relay(_proof(finalGateway, recallId, 100));

        assertEq(token.bridgedBalanceOf(aliceSat), 900);
        assertEq(token.pendingRecall(recallId).amount, 0, "settled");
    }

    function test_burnProof_RevertWhen_FromTheFastRoute() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(aliceSat, 100, alice);
        uint256 index = _proof(fastGateway, recallId, 100);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GatewayIsFastRoute.selector, address(fastGateway), polygon));
        fastGateway.relay(index);

        assertEq(token.bridgedBalanceOf(aliceSat), 1000);
    }

    /// @dev The fast route is judged at delivery: a final gateway that later became the fast route delivers
    ///  nothing more while it is one, even for a validation pinned to it, since what it relays no longer waits for
    ///  finality. The refusal reverts, so the leg is not lost: it lands once the gateway is no longer the fast route.
    function test_settlement_RevertWhen_ThePinnedGatewayBecameTheFastRoute() public {
        bytes32 id = _issue();
        _makeTheFinalGatewayTheFastRoute();
        uint256 index = _liteSettles(finalGateway, token, _settlement(id, aliceSat, bobSat, 60));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GatewayIsFastRoute.selector, address(finalGateway), polygon));
        finalGateway.relay(index);
        assertFalse(token.messageReceived(address(finalGateway), finalGateway.receiveIdFor(index)), "deliverable");

        _setFastRoute(POLYGON, address(0));
        finalGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 60);
    }

    /// @dev The same for an open recall: its proof is refused while the gateway it was dispatched through is the
    ///  fast route, stays deliverable, and settles once that gateway is no longer the fast route.
    function test_burnProof_RevertWhen_TheRecallsGatewayBecameTheFastRoute() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(aliceSat, 100, alice);
        _makeTheFinalGatewayTheFastRoute();
        uint256 index = _proof(finalGateway, recallId, 100);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GatewayIsFastRoute.selector, address(finalGateway), polygon));
        finalGateway.relay(index);
        assertEq(token.pendingRecall(recallId).amount, 100, "still open");

        _setFastRoute(POLYGON, address(0));
        finalGateway.relay(index);

        assertEq(token.bridgedBalanceOf(aliceSat), 900);
        assertEq(token.pendingRecall(recallId).amount, 0, "settled");
    }

    /// @dev Polygon gets a new final route and its former one becomes the fast route.
    function _makeTheFinalGatewayTheFastRoute() private {
        ERC7786GatewayMock newFinal = _newTrustedGateway(POLYGON);
        _setFastRoute(POLYGON, address(0));
        _openEvmChain(token, POLYGON, address(newFinal));
        _setFastRoute(POLYGON, address(finalGateway));
    }

}
