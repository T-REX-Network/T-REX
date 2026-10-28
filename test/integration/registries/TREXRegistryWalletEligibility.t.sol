// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Errors } from "@onchain-id/solidity/contracts/libraries/Errors.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @dev The wallet views against the real ONCHAINID stack: a satellite wallet linked through the factory's
///      cross-chain path, revoked by its identity, and never linked at all.
contract TREXRegistryWalletEligibilityTest is TREXSuiteTest {

    uint256 internal constant POLYGON = 137;

    Token internal claimed;
    ITREXRegistry internal registry;
    Account internal satellite = makeAccount("aliceOnPolygon");

    function setUp() public override {
        super.setUp();
        claimed = _deployTokenWithClaimedHolders("claimed", "Claimed", "CLM");
        registry = ITREXRegistry(address(claimed.identityRegistry()));
    }

    /// @notice A claimed identity's linked satellite wallet is attributed and admitted.
    function test_isWalletVerified_Success_WhenSatelliteWalletIsLinkedToAClaimedIdentity() public {
        bytes memory envelope = _linkSatelliteWallet(aliceIdentity, POLYGON, satellite);

        assertEq(address(registry.resolveIdentity(envelope)), address(aliceIdentity));
        assertTrue(registry.isWalletVerified(envelope));
    }

    /// @notice After revocation the wallet keeps its owner but loses its eligibility.
    function test_isWalletVerified_Success_WhenSatelliteWalletWasRevoked() public {
        bytes memory envelope = _linkSatelliteWallet(aliceIdentity, POLYGON, satellite);
        _revokeWallet(aliceIdentity, envelope);

        assertEq(address(registry.resolveIdentity(envelope)), address(aliceIdentity));
        assertFalse(registry.isWalletVerified(envelope));
    }

    /// @notice A wallet nobody linked has no owner and no eligibility.
    function test_isWalletVerified_Success_WhenSatelliteWalletIsUnbound() public view {
        bytes memory envelope = _satelliteEnvelope(POLYGON, satellite.addr);

        assertEq(address(registry.resolveIdentity(envelope)), address(0));
        assertFalse(registry.isWalletVerified(envelope));
    }

    /// @notice The native envelope of a registered wallet answers what the address forms answer.
    function test_isWalletVerified_Success_WhenWalletIsNative() public {
        bytes memory envelope = InteroperableAddress.formatEvmV1(block.chainid, alice);

        assertEq(address(registry.resolveIdentity(envelope)), address(registry.identity(alice)));
        assertEq(registry.isWalletVerified(envelope), registry.isVerified(alice));
        assertTrue(registry.isWalletVerified(envelope));

        _removeClaim(aliceIdentity, CLAIM_TOPIC_1, alice);
        assertFalse(registry.isWalletVerified(envelope));
        assertEq(registry.isWalletVerified(envelope), registry.isVerified(alice));
    }

    /* ----- An identity resolves to itself ----- */

    /// @notice An identity's own address is attributed and admitted without any local registration: the
    ///         factory self-resolves it on the including-revoked view the registry's global fallback uses.
    function test_identity_Success_WhenAddressIsTheIdentityItself() public view {
        address self = address(aliceIdentity);
        bytes memory envelope = InteroperableAddress.formatEvmV1(block.chainid, self);

        assertFalse(registry.isLocallyRegistered(self));
        assertEq(address(registry.identity(self)), self);
        assertTrue(registry.contains(self));
        assertTrue(registry.isVerified(self));
        assertEq(address(registry.resolveIdentity(envelope)), self);
        assertTrue(registry.isWalletVerified(envelope));
    }

    /// @notice An identity can hold the token on its own address: it is minted to, receives from one of its
    ///         wallets, and sends out again, with the position attributed to the identity throughout.
    function test_transfer_Success_WhenHolderIsTheIdentityItself() public {
        address self = address(aliceIdentity);
        IComplianceLedger ledger = IComplianceLedger(address(claimed.compliance()));

        vm.startPrank(agent);
        claimed.mint(self, 300);
        claimed.unpause();
        vm.stopPrank();
        assertEq(claimed.balanceOf(self), 300);
        // The ledger credits the identity, not the address it happens to be held on, and `ownerOf` names the
        // identity for its own address: that attribution is what this repin enables.
        assertEq(ledger.positionOf(address(aliceIdentity)), 300, "mint not attributed to the identity");
        assertEq(ledger.ownerOf(self), address(aliceIdentity), "the identity's own address has no owner");

        vm.prank(self);
        claimed.transfer(bob, 100);
        assertEq(claimed.balanceOf(bob), 100);
        assertEq(ledger.positionOf(address(aliceIdentity)), 200, "outbound transfer not debited");
        assertEq(ledger.positionOf(address(bobIdentity)), 100, "bob not credited");

        vm.prank(bob);
        claimed.transfer(self, 50);
        assertEq(claimed.balanceOf(self), 250);
        assertEq(ledger.positionOf(address(aliceIdentity)), 250, "inbound transfer not credited");
        assertEq(ledger.positionOf(address(bobIdentity)), 50, "bob not debited");
        assertEq(ledger.positionGap(), 0, "positions drifted from the supply");
    }

    /// @notice An identity can never revoke its own address, so it cannot break the attribution the two tests
    ///         above rely on. The self-resolution entry is seeded outside the identity's account set, which is
    ///         what makes the revocation fail. Pinned here, not only upstream, because T-REX now depends on it:
    ///         a future ONCHAINID bump that let this through would silently un-attribute the position.
    function test_revokeAccount_RevertWhen_WalletIsTheIdentityItself() public {
        bytes memory envelope = InteroperableAddress.formatEvmV1(block.chainid, address(aliceIdentity));

        vm.expectRevert(abi.encodeWithSelector(Errors.WalletNotLinkedToIdentity.selector, envelope));
        vm.prank(address(aliceIdentity));
        idFactory.revokeAccount(envelope);

        assertEq(address(registry.resolveIdentity(envelope)), address(aliceIdentity), "attribution lost");
        assertTrue(registry.isWalletVerified(envelope), "eligibility lost");
    }

}
