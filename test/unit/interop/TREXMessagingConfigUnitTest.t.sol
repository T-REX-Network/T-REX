// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { TokenBaseUnitTest } from "test/unit/token/TokenBaseUnitTest.t.sol";

contract TREXMessagingConfigUnitTest is TokenBaseUnitTest {

    TrustedGatewayRegistry registry;

    address identityManager = makeAddr("IdentityManager");
    address interopManager = makeAddr("InteropManager");

    address trustedGateway = makeAddr("TrustedGateway");
    address untrustedGateway = makeAddr("UntrustedGateway");

    /// @dev An EVM chain that is not this one, so the peer default is exercised away from home.
    bytes2 evmType = MessageTypesLib.EVM_CHAIN_TYPE;
    bytes evmRef = hex"89";
    bytes32 evmChain = MessageTypesLib.chainKey(bytes2(0x0000), hex"89");

    /// @dev A non-EVM chain, where CREATE3 gives no address and a peer must be registered.
    bytes2 nonEvmType = 0x0002;
    bytes nonEvmRef = hex"01";
    bytes32 nonEvmChain = MessageTypesLib.chainKey(bytes2(0x0002), hex"01");

    /// @dev ERC-7930 v1: version, chain type 0x0002, reference length 1, reference 0x01, account length 4, account.
    bytes nonEvmPeer = hex"0001000201010401020304";

    function setUp() public override {
        super.setUp();

        registry = new TrustedGatewayRegistry(address(accessManager));
        AccessManagerSetupLib.setupTrustedGatewayRegistryRoles(accessManager, address(registry));

        _grantManagerRoles(identityManager);
        _grantInteropManagerRole(interopManager);

        vm.prank(interopManager);
        registry.setTrustedGateway(trustedGateway, true);
    }

    function _pointAtRegistry() private {
        vm.prank(identityManager);
        token.setTrustedGatewayRegistry(address(registry));
    }

    /* ----- Registry ----- */

    function testTokenStartsWithNoRegistry() public view {
        assertEq(token.trustedGatewayRegistry(), address(0));
    }

    function testIdentityManagerSetsTheRegistry() public {
        vm.expectEmit(false, false, false, true, address(token));
        emit EventsLib.TrustedGatewayRegistrySet(address(registry));

        _pointAtRegistry();

        assertEq(token.trustedGatewayRegistry(), address(registry));
    }

    function testSetTrustedGatewayRegistryRevertsOnZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(identityManager);
        token.setTrustedGatewayRegistry(address(0));
    }

    function testSetTrustedGatewayRegistryRevertsWhenNotIdentityManager() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        vm.prank(agent);
        token.setTrustedGatewayRegistry(address(registry));
    }

    /* ----- Routes ----- */

    function testSetRouteRevertsWhenRegistryNotSet() public {
        vm.expectRevert(ErrorsLib.RegistryNotSet.selector);
        vm.prank(identityManager);
        token.setRoute(evmType, evmRef, trustedGateway);
    }

    function testIdentityManagerOpensAChain() public {
        _pointAtRegistry();

        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.ChainRegistered(evmChain, evmType, evmRef);
        vm.expectEmit(true, true, false, false, address(token));
        emit EventsLib.RouteSet(evmChain, trustedGateway);

        vm.prank(identityManager);
        token.setRoute(evmType, evmRef, trustedGateway);

        assertEq(token.routeFor(evmChain), trustedGateway);
        assertTrue(token.isChainOpen(evmChain));

        (bytes2 chainType, bytes memory chainReference) = token.chainOf(evmChain);
        assertEq(chainType, evmType);
        assertEq(chainReference, evmRef);
    }

    function testChainIsRegisteredOnce() public {
        _pointAtRegistry();

        vm.startPrank(identityManager);
        token.setRoute(evmType, evmRef, trustedGateway);

        vm.recordLogs();
        token.setRoute(evmType, evmRef, address(0));
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EventsLib.ChainRegistered.selector, "registered again");
        }
    }

    function testSetRouteRevertsOnAnEmptyChainReference() public {
        _pointAtRegistry();

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidChainReference.selector, evmType, bytes("")));
        vm.prank(identityManager);
        token.setRoute(evmType, "", trustedGateway);
    }

    /// @dev A gateway derives the chain from a minimal big-endian id; a padded one would never match it.
    function testSetRouteRevertsOnAPaddedEvmChainReference() public {
        _pointAtRegistry();

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidChainReference.selector, evmType, hex"0089"));
        vm.prank(identityManager);
        token.setRoute(evmType, hex"0089", trustedGateway);
    }

    /// @dev Only EVM references are minimal by construction; another chain type may start with a zero.
    function testNonEvmChainReferenceMayStartWithZero() public {
        _pointAtRegistry();

        vm.prank(identityManager);
        token.setRoute(nonEvmType, hex"0001", trustedGateway);

        assertEq(token.routeFor(MessageTypesLib.chainKey(nonEvmType, hex"0001")), trustedGateway);
    }

    function testSetRouteRevertsOnUntrustedGateway() public {
        _pointAtRegistry();

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.GatewayNotTrusted.selector, untrustedGateway));
        vm.prank(identityManager);
        token.setRoute(evmType, evmRef, untrustedGateway);
    }

    function testZeroGatewayClosesTheChain() public {
        _pointAtRegistry();

        vm.startPrank(identityManager);
        token.setRoute(evmType, evmRef, trustedGateway);
        token.setRoute(evmType, evmRef, address(0));
        vm.stopPrank();

        assertEq(token.routeFor(evmChain), address(0));
        assertFalse(token.isChainOpen(evmChain));
    }

    function testSetRouteRevertsWhenNotIdentityManager() public {
        _pointAtRegistry();

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        vm.prank(agent);
        token.setRoute(evmType, evmRef, trustedGateway);
    }

    /// @dev The emergency lever: removal severs the route with no call on the token.
    function testRemovingTheGatewayClosesEveryRouteThroughIt() public {
        _pointAtRegistry();

        vm.prank(identityManager);
        token.setRoute(evmType, evmRef, trustedGateway);
        assertTrue(token.isChainOpen(evmChain));

        vm.prank(interopManager);
        registry.setTrustedGateway(trustedGateway, false);

        assertFalse(token.isChainOpen(evmChain));
        assertEq(token.routeFor(evmChain), trustedGateway, "the route is stored, it is trust that went away");
    }

    /* ----- Peers ----- */

    /// @dev On the satellite, not on the reference chain: the Lite lives at the token's address over there.
    function testPeerDefaultsToTheTokensOwnAddressOnThatChain() public {
        _pointAtRegistry();
        vm.prank(identityManager);
        token.setRoute(evmType, evmRef, trustedGateway);

        assertEq(token.peerFor(evmChain), InteroperableAddress.formatEvmV1(0x89, address(token)));
        assertEq(
            token.peerFor(evmChain), InteroperableAddress.formatV1(evmType, evmRef, abi.encodePacked(address(token)))
        );
    }

    /// @dev Before the prefix is known there is no address to spell, and the chain is not open.
    function testPeerIsEmptyForAChainNeverSeen() public view {
        assertEq(token.peerFor(evmChain), "");
        assertFalse(token.isChainOpen(evmChain));
    }

    function testNonEvmChainHasNoDefaultPeer() public {
        _pointAtRegistry();
        vm.prank(identityManager);
        token.setRoute(nonEvmType, nonEvmRef, trustedGateway);

        assertEq(token.peerFor(nonEvmChain), "");
        assertFalse(token.isChainOpen(nonEvmChain), "routed, but nowhere to send to");

        vm.prank(identityManager);
        token.setPeer(nonEvmChain, nonEvmPeer);

        assertTrue(token.isChainOpen(nonEvmChain));
    }

    function testSetPeerRegistersTheChainToo() public {
        vm.prank(identityManager);
        token.setPeer(nonEvmChain, nonEvmPeer);

        (bytes2 chainType, bytes memory chainReference) = token.chainOf(nonEvmChain);
        assertEq(chainType, nonEvmType);
        assertEq(chainReference, nonEvmRef);
    }

    function testSetPeerRevertsWhenThePeerIsOnAnotherChain() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.PeerChainMismatch.selector, evmChain, nonEvmChain));
        vm.prank(identityManager);
        token.setPeer(evmChain, nonEvmPeer);
    }

    /// @dev Trailing bytes decode to the same peer but never equal a gateway's canonical sender.
    function testSetPeerRevertsOnTrailingBytes() public {
        bytes memory padded = bytes.concat(nonEvmPeer, hex"00");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidPeer.selector, padded));
        vm.prank(identityManager);
        token.setPeer(nonEvmChain, padded);
    }

    function testSetPeerRevertsOnAnEmptyAccount() public {
        bytes memory chainOnly = hex"00010002010100";

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidPeer.selector, chainOnly));
        vm.prank(identityManager);
        token.setPeer(nonEvmChain, chainOnly);
    }

    function testEmptyPeerRestoresTheDefault() public {
        _pointAtRegistry();
        vm.startPrank(identityManager);
        token.setRoute(evmType, evmRef, trustedGateway);

        bytes memory explicitPeer = InteroperableAddress.formatEvmV1(0x89, makeAddr("OtherLite"));
        token.setPeer(evmChain, explicitPeer);
        assertEq(token.peerFor(evmChain), explicitPeer);

        token.setPeer(evmChain, "");
        vm.stopPrank();

        assertEq(token.peerFor(evmChain), InteroperableAddress.formatEvmV1(0x89, address(token)));
    }

    function testIdentityManagerRegistersANonEvmPeer() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.PeerSet(nonEvmChain, nonEvmPeer);

        vm.prank(identityManager);
        token.setPeer(nonEvmChain, nonEvmPeer);

        assertEq(token.peerFor(nonEvmChain), nonEvmPeer);
    }

    function testSetPeerRevertsWhenNotIdentityManager() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        vm.prank(agent);
        token.setPeer(nonEvmChain, nonEvmPeer);
    }

    /* ----- Storage isolation ----- */

    function testRoutingDoesNotDisturbTheTokenLedger() public {
        vm.prank(agent);
        token.unpause();
        vm.prank(agent);
        token.mint(user1, 1000);

        uint256 balanceBefore = token.balanceOf(user1);
        uint256 supplyBefore = token.totalSupply();

        _pointAtRegistry();
        vm.startPrank(identityManager);
        token.setRoute(evmType, evmRef, trustedGateway);
        token.setPeer(nonEvmChain, nonEvmPeer);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), balanceBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.name(), "Token");
        assertEq(token.decimals(), 18);
    }

}
