// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ITREXMessaging } from "contracts/interop/ITREXMessaging.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

/// @dev The messaging layer runs in `TREXMessagingLib`, so the events and errors it raises are
///  redeclared on `ITREXMessaging` to stay in the token's ABI. A redeclaration that drifts from the
///  library definition would put a signature in the ABI that the token never produces; this pins
///  every one of them to the definition the library actually uses.
contract TREXMessagingAbiUnitTest is Test {

    function test_events_MatchTheLibraryDefinitions() public pure {
        assertEq(ITREXMessaging.TrustedGatewayRegistrySet.selector, EventsLib.TrustedGatewayRegistrySet.selector);
        assertEq(ITREXMessaging.ChainRegistered.selector, EventsLib.ChainRegistered.selector);
        assertEq(ITREXMessaging.RouteSet.selector, EventsLib.RouteSet.selector);
        assertEq(ITREXMessaging.PeerSet.selector, EventsLib.PeerSet.selector);
        assertEq(ITREXMessaging.ValidationRoutePinned.selector, EventsLib.ValidationRoutePinned.selector);
        assertEq(ITREXMessaging.ProtocolMessageSent.selector, EventsLib.ProtocolMessageSent.selector);
        assertEq(ITREXMessaging.BurnProofReceived.selector, EventsLib.BurnProofReceived.selector);
    }

    function test_errors_MatchTheLibraryDefinitions() public pure {
        assertEq(ITREXMessaging.ChainNotOpen.selector, ErrorsLib.ChainNotOpen.selector);
        assertEq(ITREXMessaging.ChainNotRegistered.selector, ErrorsLib.ChainNotRegistered.selector);
        assertEq(ITREXMessaging.GatewayNotRouted.selector, ErrorsLib.GatewayNotRouted.selector);
        assertEq(ITREXMessaging.GatewayNotPinned.selector, ErrorsLib.GatewayNotPinned.selector);
        assertEq(ITREXMessaging.GatewayNotTrusted.selector, ErrorsLib.GatewayNotTrusted.selector);
        assertEq(ITREXMessaging.InvalidChainReference.selector, ErrorsLib.InvalidChainReference.selector);
        assertEq(ITREXMessaging.InvalidPeer.selector, ErrorsLib.InvalidPeer.selector);
        assertEq(ITREXMessaging.MessageAlreadyReceived.selector, ErrorsLib.MessageAlreadyReceived.selector);
        assertEq(ITREXMessaging.MessageTypeNotInbound.selector, ErrorsLib.MessageTypeNotInbound.selector);
        assertEq(ITREXMessaging.PeerChainMismatch.selector, ErrorsLib.PeerChainMismatch.selector);
        assertEq(ITREXMessaging.SenderNotPeer.selector, ErrorsLib.SenderNotPeer.selector);
        assertEq(ITREXMessaging.ValidationAlreadyRouted.selector, ErrorsLib.ValidationAlreadyRouted.selector);
        assertEq(ITREXMessaging.UnsupportedMessageVersion.selector, ErrorsLib.UnsupportedMessageVersion.selector);
    }

    function test_errors_MatchTheOpenZeppelinDefinitions() public pure {
        assertEq(
            ITREXMessaging.InteroperableAddressParsingError.selector,
            InteroperableAddress.InteroperableAddressParsingError.selector
        );
        assertEq(
            ITREXMessaging.InteroperableAddressEmptyReferenceAndAddress.selector,
            InteroperableAddress.InteroperableAddressEmptyReferenceAndAddress.selector
        );
        assertEq(
            ITREXMessaging.SafeCastOverflowedUintDowncast.selector, SafeCast.SafeCastOverflowedUintDowncast.selector
        );
    }

}
