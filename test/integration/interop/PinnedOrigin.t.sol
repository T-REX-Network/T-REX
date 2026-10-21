// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ISettlementHandler } from "contracts/interop/ISettlementHandler.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A validation leg is pinned to the gateway and the peer it was sent to. A peer change does not strand
///      it.
///      The validations are dispatched by the token alone, never issued by the compliance, so a leg that
///      passes the transport reaches `handleSettlement`, which is what these tests read.
contract PinnedOriginTest is InteropSuiteTest {

    ERC7786GatewayMock gateway;
    address compliance;
    address newLite = makeAddr("newLite");

    bytes32 satellite = polygon;
    uint256 inFlight = 1;
    uint256 neverDispatched = 99;
    uint256 amount = 100;

    function setUp() public override {
        super.setUp();

        gateway = _newTrustedGateway(POLYGON);
        compliance = address(token.compliance());
        _openEvmChain(token, POLYGON, address(gateway));

        vm.prank(compliance);
        token.dispatchComplianceValidation(satellite, inFlight, abi.encode("validation"));

        vm.prank(agent);
        token.unpause();
    }

    function _settlementFrom(address author, uint256 validationId) private returns (uint256) {
        return _queue(
            gateway,
            author,
            token,
            MessageTypesLib.encodeSettlement(_sameChainSettlement(validationId, POLYGON, amount))
        );
    }

    function _changePeer() private {
        vm.prank(deployer);
        token.setPeer(satellite, InteroperableAddress.formatEvmV1(POLYGON, newLite));
    }

    function _expectHandled() private {
        vm.expectCall(compliance, abi.encodeWithSelector(ISettlementHandler.handleSettlement.selector), 1);
    }

    function _expectNotPeer(address author) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SenderNotPeer.selector, satellite, InteroperableAddress.formatEvmV1(POLYGON, author)
            )
        );
    }

    /* ----- A peer change ----- */

    function testThePreviousPeerStillSettlesWhatItWasSent() public {
        uint256 index = _settlementFrom(address(token), inFlight);
        _changePeer();

        _expectHandled();
        gateway.relay(index);
    }

    function testTheNewPeerCannotSettleWhatThePreviousOneWasSent() public {
        _changePeer();
        uint256 index = _settlementFrom(newLite, inFlight);

        _expectNotPeer(newLite);
        gateway.relay(index);
    }

    function testRedispatchAfterAPeerChangeIsRefused() public {
        _changePeer();

        vm.prank(compliance);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ValidationAlreadyRouted.selector, inFlight, satellite, address(gateway))
        );
        token.dispatchComplianceValidation(satellite, inFlight, abi.encode("validation"));
    }

    function testAnUnpinnedSettlementFollowsTheCurrentPeer() public {
        _changePeer();
        uint256 fromPrevious = _settlementFrom(address(token), neverDispatched);
        uint256 fromCurrent = _settlementFrom(newLite, neverDispatched);

        _expectNotPeer(address(token));
        gateway.relay(fromPrevious);

        _expectHandled();
        gateway.relay(fromCurrent);
    }

}
