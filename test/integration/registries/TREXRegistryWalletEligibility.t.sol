// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

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

}
