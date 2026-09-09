// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

contract OutboundMessagingTest is InteropSuiteTest {

    ERC7786GatewayMock gateway;

    address compliance;

    bytes32 satellite = polygon;
    bytes32 closedChain = optimism;

    /// @dev A non-EVM chain: CREATE3 gives no address there, so a peer must be registered explicitly.
    bytes32 solana = MessageTypesLib.chainKey(bytes2(0x0002), hex"01");

    uint256 validationId = 1;
    bytes validationBody = abi.encode(uint256(1), "validation");
    bytes mintBody = abi.encode(uint256(2), "mint");

    /// @dev Mirrors TREXMessaging's ERC-7201 namespace, so a test can strip the registry back off.
    bytes32 internal constant MESSAGING_STORAGE_LOCATION =
        0x6781593751868cc4363b89c5315b7498ab1a563f1f060d4f48327b74abb92100;

    function setUp() public override {
        super.setUp();

        gateway = _newTrustedGateway(POLYGON);
        compliance = address(token.compliance());

        _openEvmChain(token, POLYGON, address(gateway));
    }

    function _dispatch(uint256 id, bytes32 chainKey) private returns (bytes32) {
        vm.prank(compliance);
        return token.dispatchComplianceValidation(chainKey, id, validationBody);
    }

    /* ----- Happy path ----- */

    /// @dev The peer is the token's own address on the satellite, not on the reference chain.
    function testComplianceDispatchesAValidationToItsLiteOnTheSatellite() public {
        _dispatch(validationId, satellite);

        assertEq(gateway.queueLength(), 1);
        assertEq(gateway.queuedMessage(0).recipient, token.peerFor(satellite));
        assertEq(gateway.queuedMessage(0).recipient, InteroperableAddress.formatEvmV1(POLYGON, address(token)));
    }

    function testDispatchedPayloadDecodesBackToWhatWasSent() public {
        _dispatch(validationId, satellite);

        (uint8 messageType, uint8 version, bytes memory body) =
            abi.decode(gateway.queuedMessage(0).payload, (uint8, uint8, bytes));

        assertEq(messageType, MessageTypesLib.COMPLIANCE_VALIDATION);
        assertEq(version, MessageTypesLib.VERSION);
        assertEq(body, validationBody);
    }

    function testEverySendAnnouncesItsTypeChainAndSendId() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(MessageTypesLib.COMPLIANCE_VALIDATION, satellite, gateway.receiveIdFor(0));

        _dispatch(validationId, satellite);
    }

    function testBothTypesQueueSeparately() public {
        _dispatch(validationId, satellite);

        vm.prank(agent);
        token.dispatchMintInstruction(satellite, mintBody);

        assertEq(gateway.queueLength(), 2);
    }

    /* ----- Route snapshot ----- */

    function testDispatchPinsTheRouteForTheValidation() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ValidationRoutePinned(validationId, satellite, address(gateway));

        _dispatch(validationId, satellite);

        assertEq(token.pinnedRouteFor(validationId, satellite), address(gateway));
    }

    /// @dev A lost message may be re-sent: same validation, same chain, same gateway.
    function testRedispatchThroughThePinnedGatewayIsAllowed() public {
        _dispatch(validationId, satellite);
        _dispatch(validationId, satellite);

        assertEq(gateway.queueLength(), 2);
        assertEq(token.pinnedRouteFor(validationId, satellite), address(gateway));
    }

    /// @dev Its legs could never be accepted through the new gateway, so the re-dispatch says so now.
    function testRedispatchThroughAnotherGatewayIsRefused() public {
        _dispatch(validationId, satellite);

        ERC7786GatewayMock other = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(other));

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationAlreadyRouted.selector, validationId, satellite, address(gateway)
            )
        );
        _dispatch(validationId, satellite);

        assertEq(other.queueLength(), 0);
    }

    /// @dev One validation, two chains: each leg pins the route it took, independently.
    function testACrossChainValidationPinsOneRoutePerChain() public {
        ERC7786GatewayMock optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        _dispatch(validationId, satellite);
        _dispatch(validationId, optimism);

        assertEq(token.pinnedRouteFor(validationId, satellite), address(gateway));
        assertEq(token.pinnedRouteFor(validationId, optimism), address(optimismGateway));
        assertEq(gateway.queueLength(), 1);
        assertEq(optimismGateway.queueLength(), 1);
    }

    /* ----- Mint instruction: fire and forget ----- */

    function testAgentDispatchesAMintInstructionAndItIsAnnounced() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageSent(MessageTypesLib.MINT_INSTRUCTION, satellite, gateway.receiveIdFor(0));

        vm.prank(agent);
        bytes32 sendId = token.dispatchMintInstruction(satellite, mintBody);

        assertEq(gateway.queueLength(), 1);
        assertEq(sendId, gateway.receiveIdFor(0));

        (uint8 messageType,, bytes memory body) = abi.decode(gateway.queuedMessage(0).payload, (uint8, uint8, bytes));
        assertEq(messageType, MessageTypesLib.MINT_INSTRUCTION);
        assertEq(body, mintBody);
    }

    /// @dev Nothing is reconciled, so nothing is pinned: the token keeps no record of a mint instruction.
    function testAMintInstructionLeavesNoRecordBehind() public {
        vm.prank(agent);
        token.dispatchMintInstruction(satellite, mintBody);

        // Neither dropping nor never relaying the message changes anything on the token's side.
        gateway.drop(0);

        vm.prank(agent);
        token.dispatchMintInstruction(satellite, mintBody);

        assertEq(gateway.queueLength(), 2);
        assertEq(token.pinnedRouteFor(0, satellite), address(0));
    }

    /* ----- Fail closed ----- */

    function testDispatchRevertsOnAChainThatWasNeverOpened() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, closedChain));
        _dispatch(validationId, closedChain);

        assertEq(gateway.queueLength(), 0);
    }

    /// @dev Routed, but with no address to send to: a non-EVM chain has no CREATE3 default.
    function testDispatchRevertsOnARoutedChainWithNoPeer() public {
        vm.prank(deployer);
        token.setRoute(bytes2(0x0002), hex"01", address(gateway));

        assertEq(token.peerFor(solana), "");
        assertFalse(token.isChainOpen(solana));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, solana));
        _dispatch(validationId, solana);

        vm.prank(deployer);
        token.setPeer(solana, hex"0001000201010401020304");

        _dispatch(validationId, solana);
        assertEq(gateway.queuedMessage(0).recipient, hex"0001000201010401020304");
    }

    function testDispatchRevertsWhenTheTokenHasNoRegistry() public {
        Token fresh = _deployToken("fresh", "Fresh", "FRS");
        address freshCompliance = address(fresh.compliance());

        // Undo the helper's wiring: a token that was never pointed at a registry sends nothing.
        // `registry` is the first field of the messaging namespace, so it sits on the location itself.
        vm.store(address(fresh), MESSAGING_STORAGE_LOCATION, 0);
        assertEq(fresh.trustedGatewayRegistry(), address(0));

        vm.expectRevert(ErrorsLib.RegistryNotSet.selector);
        vm.prank(freshCompliance);
        fresh.dispatchComplianceValidation(satellite, validationId, validationBody);

        assertEq(gateway.queueLength(), 0);
    }

    function testDispatchRevertsForAnUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        token.dispatchComplianceValidation(satellite, validationId, validationBody);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        token.dispatchMintInstruction(satellite, mintBody);

        assertEq(gateway.queueLength(), 0);
    }

    /// @dev The emergency lever, proven end to end: removal stops traffic with no call on the token.
    function testRemovingTheGatewayStopsTrafficWithNoConfigChange() public {
        _dispatch(validationId, satellite);
        assertEq(gateway.queueLength(), 1);

        trustedGatewayRegistry.setTrustedGateway(address(gateway), false);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, satellite));
        _dispatch(2, satellite);

        assertEq(gateway.queueLength(), 1, "nothing new was queued");
        assertEq(token.routeFor(satellite), address(gateway), "the route is untouched, trust is what moved");
    }

}
