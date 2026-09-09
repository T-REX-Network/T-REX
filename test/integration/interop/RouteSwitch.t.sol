// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ERC7786Recipient } from "@openzeppelin/contracts/crosschain/ERC7786Recipient.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ISettlementHandler } from "contracts/interop/ISettlementHandler.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Routes are snapshot at dispatch. An issuer switching a chain's gateway affects new validations
///      only; the legs of one already in flight are matched against the gateway that carried it out.
contract RouteSwitchTest is InteropSuiteTest {

    ERC7786GatewayMock oldGateway;
    ERC7786GatewayMock newGateway;

    address compliance;

    bytes32 satellite = polygon;

    uint256 inFlight = 1;
    uint256 issuedAfterSwitch = 2;
    uint256 neverDispatched = 99;
    uint256 amount = 100;

    bytes validationBody = abi.encode("validation");

    function setUp() public override {
        super.setUp();

        oldGateway = _newTrustedGateway(POLYGON);
        newGateway = _newTrustedGateway(POLYGON);
        compliance = address(token.compliance());

        _openEvmChain(token, POLYGON, address(oldGateway));
        _dispatch(inFlight);

        // The switch: from here on the issuer's traffic goes through the new gateway.
        _openEvmChain(token, POLYGON, address(newGateway));
    }

    function _dispatch(uint256 validationId) private {
        vm.prank(compliance);
        token.dispatchComplianceValidation(satellite, validationId, validationBody);
    }

    function _settlementFrom(ERC7786GatewayMock gateway, uint256 validationId) private returns (uint256) {
        return _liteSends(
            gateway, token, MessageTypesLib.encodeSettlement(_sameChainSettlement(validationId, token, POLYGON, amount))
        );
    }

    function _expectHandled(uint256 validationId) private {
        vm.expectCall(
            compliance,
            abi.encodeCall(
                ISettlementHandler.handleSettlement,
                (satellite, _sameChainSettlement(validationId, token, POLYGON, amount))
            )
        );
    }

    function _expectNotPinned(ERC7786GatewayMock gateway, uint256 validationId) private {
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.GatewayNotPinned.selector, address(gateway), validationId, satellite)
        );
    }

    /* ----- The old leg ----- */

    function testTheSwitchIsInPlace() public view {
        assertEq(token.routeFor(satellite), address(newGateway));
        assertEq(token.pinnedRouteFor(inFlight, satellite), address(oldGateway));
    }

    function testOldLegIsAcceptedFromThePinnedGatewayAfterTheSwitch() public {
        uint256 index = _settlementFrom(oldGateway, inFlight);

        _expectHandled(inFlight);
        oldGateway.relay(index);
    }

    function testOldLegIsRefusedFromTheNewRoute() public {
        uint256 index = _settlementFrom(newGateway, inFlight);

        _expectNotPinned(newGateway, inFlight);
        newGateway.relay(index);

        assertFalse(token.messageReceived(address(newGateway), newGateway.receiveIdFor(index)));
    }

    /// @dev Cross-chain: the second leg of the same validation, from the same chain, keeps the same pin.
    function testEveryLegOfTheOldValidationHonoursThePin() public {
        uint256 burnLeg = _liteSends(
            oldGateway,
            token,
            MessageTypesLib.encodeSettlement(
                _settlement(inFlight, token, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("From")), "", amount)
            )
        );
        uint256 replayOnNewRoute = _settlementFrom(newGateway, inFlight);

        vm.expectCall(compliance, abi.encodeWithSelector(ISettlementHandler.handleSettlement.selector), 1);
        oldGateway.relay(burnLeg);

        _expectNotPinned(newGateway, inFlight);
        newGateway.relay(replayOnNewRoute);
    }

    /* ----- The new validation ----- */

    function testNewValidationGoesOutThroughTheNewRouteAndPinsIt() public {
        _dispatch(issuedAfterSwitch);

        assertEq(oldGateway.queueLength(), 1, "only the in-flight one went through the old gateway");
        assertEq(newGateway.queueLength(), 1);
        assertEq(token.pinnedRouteFor(issuedAfterSwitch, satellite), address(newGateway));
    }

    function testNewValidationSettlesThroughTheNewRouteOnly() public {
        _dispatch(issuedAfterSwitch);

        uint256 viaOld = _settlementFrom(oldGateway, issuedAfterSwitch);
        uint256 viaNew = _settlementFrom(newGateway, issuedAfterSwitch);

        _expectNotPinned(oldGateway, issuedAfterSwitch);
        oldGateway.relay(viaOld);

        _expectHandled(issuedAfterSwitch);
        newGateway.relay(viaNew);
    }

    /* ----- What was never pinned follows the current route ----- */

    /// @dev An id this token never dispatched is not refused by transport: the compliance must see it to
    ///      raise its never-issued emergency. It follows the current route, like any unpinned message.
    function testUnpinnedSettlementFollowsTheCurrentRoute() public {
        uint256 viaOld = _settlementFrom(oldGateway, neverDispatched);
        uint256 viaNew = _settlementFrom(newGateway, neverDispatched);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GatewayNotRouted.selector, address(oldGateway), satellite));
        oldGateway.relay(viaOld);

        _expectHandled(neverDispatched);
        newGateway.relay(viaNew);
    }

    /// @dev A recall carries no validation, so it checks against the current route: old gateway refused.
    function testBurnProofFollowsTheCurrentRoute() public {
        bytes memory payload =
            MessageTypesLib.encodeBurnProof(_burnProof(POLYGON, makeAddr("Burned"), amount, makeAddr("Holder")));

        uint256 viaOld = _liteSends(oldGateway, token, payload);
        uint256 viaNew = _liteSends(newGateway, token, payload);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GatewayNotRouted.selector, address(oldGateway), satellite));
        oldGateway.relay(viaOld);

        newGateway.relay(viaNew);
        assertTrue(token.messageReceived(address(newGateway), newGateway.receiveIdFor(viaNew)));
    }

    /* ----- Emergency removal of the pinned gateway ----- */

    /// @dev Removal invalidates pinned routes too: the old leg can arrive through nothing, and the
    ///      validation will expire and be discarded by the slot lifecycle. Safe, and loud.
    function testRemovingThePinnedGatewayOrphansTheOldLeg() public {
        uint256 viaOld = _settlementFrom(oldGateway, inFlight);
        uint256 viaNew = _settlementFrom(newGateway, inFlight);

        trustedGatewayRegistry.setTrustedGateway(address(oldGateway), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7786Recipient.ERC7786RecipientUnauthorizedGateway.selector,
                address(oldGateway),
                InteroperableAddress.formatEvmV1(POLYGON, address(token))
            )
        );
        oldGateway.relay(viaOld);

        _expectNotPinned(newGateway, inFlight);
        newGateway.relay(viaNew);

        assertEq(token.pinnedRouteFor(inFlight, satellite), address(oldGateway), "the pin is a record, not a lever");
    }

}
