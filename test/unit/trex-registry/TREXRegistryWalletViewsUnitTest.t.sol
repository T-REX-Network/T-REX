// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

/// @dev The two ERC-7930 wallet views: `resolveIdentity` attributes (revoked included), `isWalletVerified`
///      admits (active binding, then the claim check). The satellite branch is proved against a mocked
///      IdentityFactory answer; the native branch against the registry's own storage.
contract TREXRegistryWalletViewsUnitTest is TREXRegistryBaseUnitTest {

    uint256 internal constant POLYGON = 137;

    address internal satelliteSigner = makeAddr("satelliteSigner");
    bytes internal satelliteWallet;
    bytes internal nativeAlice;

    function setUp() public override {
        super.setUp();
        _registerBaseIdentities();

        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.startPrank(deployer);
        registry.addClaimTopic(CLAIM_TOPIC_1);
        registry.addTrustedIssuer(address(claimIssuer), topics);
        vm.stopPrank();

        _addClaim(
            aliceIdentity, CLAIM_TOPIC_1, "Some claim public data.", claimIssuerSigner.key, address(claimIssuer), alice
        );

        satelliteWallet = InteroperableAddress.formatEvmV1(POLYGON, satelliteSigner);
        nativeAlice = InteroperableAddress.formatEvmV1(block.chainid, alice);
    }

    // ==== .resolveIdentity Tests ====

    /// @notice A native envelope resolves to the registry entry of its address.
    function test_resolveIdentity_Success_WhenWalletIsNative() public view {
        assertEq(address(registry.resolveIdentity(nativeAlice)), address(aliceIdentity));
        assertEq(address(registry.resolveIdentity(nativeAlice)), address(registry.identity(alice)));
    }

    /// @notice A native envelope the storage does not hold resolves to zero.
    function test_resolveIdentity_Success_WhenNativeWalletIsUnregistered() public view {
        assertEq(
            address(registry.resolveIdentity(InteroperableAddress.formatEvmV1(block.chainid, another))), address(0)
        );
    }

    /// @notice A satellite envelope resolves through the factory, revoked bindings included.
    function test_resolveIdentity_Success_WhenWalletIsASatelliteOne() public {
        _mockResolved(address(aliceIdentity), IIdentityFactory.AccountStatus.Revoked);
        assertEq(address(registry.resolveIdentity(satelliteWallet)), address(aliceIdentity));
    }

    /// @notice A satellite envelope nobody linked resolves to zero.
    function test_resolveIdentity_Success_WhenSatelliteWalletIsUnbound() public view {
        assertEq(address(registry.resolveIdentity(satelliteWallet)), address(0));
    }

    /// @notice A padded envelope is refused before any lookup.
    function test_resolveIdentity_RevertWhen_EnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satelliteWallet, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        registry.resolveIdentity(padded);
    }

    // ==== .isWalletVerified Tests ====

    /// @notice A native envelope answers exactly what `isVerified` answers for the address.
    function test_isWalletVerified_Success_WhenWalletIsNative() public view {
        assertTrue(registry.isWalletVerified(nativeAlice));
        assertEq(registry.isWalletVerified(nativeAlice), registry.isVerified(alice));

        bytes memory nativeCharlie = InteroperableAddress.formatEvmV1(block.chainid, charlie);
        assertFalse(registry.isWalletVerified(nativeCharlie));
        assertEq(registry.isWalletVerified(nativeCharlie), registry.isVerified(charlie));
    }

    /// @notice A native envelope the storage does not hold is not verified.
    function test_isWalletVerified_Success_WhenNativeWalletIsUnregistered() public view {
        assertFalse(registry.isWalletVerified(InteroperableAddress.formatEvmV1(block.chainid, another)));
    }

    /// @notice A satellite wallet actively bound to a claimed identity is verified.
    function test_isWalletVerified_Success_WhenSatelliteWalletIsActiveAndClaimed() public {
        _mockActive(address(aliceIdentity));
        assertTrue(registry.isWalletVerified(satelliteWallet));
    }

    /// @notice A satellite wallet bound to an identity without the claim is not verified.
    function test_isWalletVerified_Success_WhenSatelliteWalletIsActiveButUnclaimed() public {
        _mockActive(address(charlieIdentity));
        assertFalse(registry.isWalletVerified(satelliteWallet));
    }

    /// @notice A revoked satellite wallet is attributed but not admitted.
    function test_isWalletVerified_Success_WhenSatelliteWalletIsRevoked() public {
        _mockResolved(address(aliceIdentity), IIdentityFactory.AccountStatus.Revoked);
        _mockActive(address(0));

        assertFalse(registry.isWalletVerified(satelliteWallet));
        assertEq(address(registry.resolveIdentity(satelliteWallet)), address(aliceIdentity));
    }

    /// @notice A satellite wallet nobody linked is not verified.
    function test_isWalletVerified_Success_WhenSatelliteWalletIsUnbound() public view {
        assertFalse(registry.isWalletVerified(satelliteWallet));
    }

    /// @notice Disabled checks admit any wallet, bound or not, before any lookup.
    function test_isWalletVerified_Success_WhenChecksAreDisabled() public {
        vm.prank(deployer);
        registry.disableEligibilityChecks();

        assertTrue(registry.isWalletVerified(satelliteWallet));
        assertTrue(registry.isWalletVerified(InteroperableAddress.formatEvmV1(block.chainid, charlie)));
    }

    /// @notice A padded envelope is refused before any lookup.
    function test_isWalletVerified_RevertWhen_EnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(nativeAlice, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        registry.isWalletVerified(padded);
    }

    function _mockActive(address identityAddress) private {
        vm.mockCall(
            address(idFactory),
            abi.encodeCall(IIdentityFactory.getIdentity, (satelliteWallet)),
            abi.encode(identityAddress)
        );
    }

    function _mockResolved(address identityAddress, IIdentityFactory.AccountStatus status) private {
        vm.mockCall(
            address(idFactory),
            abi.encodeCall(IIdentityFactory.getIdentityIncludingRevoked, (satelliteWallet)),
            abi.encode(identityAddress, status)
        );
    }

}
