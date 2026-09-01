// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { MockTokenV2 } from "test/integration/mocks/MockTokenV2.sol";

/// @notice Behavior-driven tests for the deploy-time issuer opt-out path (`deployTREXSuiteIsolated`).
///         Each test boots through the existing `TREXSuiteTest` fixture (which already deploys one
///         shared-mode suite under `deployer`) and then deploys an additional isolated suite under a
///         separate issuer to prove the two modes do not bleed into one another.
contract TREXFactoryIsolatedSuiteTest is TREXSuiteTest {

    /// @dev Topic-0 of `IsolatedSuiteDeployed(address indexed token, SuiteBeacons beacons)`,
    ///      used to locate the event inside `vm.getRecordedLogs()`.
    bytes32 internal constant ISOLATED_SUITE_DEPLOYED_TOPIC =
        keccak256("IsolatedSuiteDeployed(address,(address,address,address,address))");

    address public issuer = makeAddr("isolatedIssuer");

    function _isolatedTokenDetails(string memory name, string memory symbol)
        internal
        view
        returns (ITREXFactory.TokenDetails memory)
    {
        address[] memory agents = new address[](1);
        agents[0] = agent;

        return ITREXFactory.TokenDetails({
            name: name,
            symbol: symbol,
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: agents,
            tokenAgents: agents,
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager)
        });
    }

    function _emptyClaims() internal pure returns (ITREXFactory.ClaimDetails memory) {
        return ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
    }

    /// @dev Deploys an isolated suite via the factory's owner (the existing `deployer`) and pulls the
    ///      cloned beacons out of the `IsolatedSuiteDeployed` event payload.
    function _deployIsolatedSuiteAndReadBeacons(string memory salt, string memory name, string memory symbol)
        internal
        returns (address tokenAddress, ITREXImplementationAuthority.SuiteBeacons memory beacons)
    {
        ITREXFactory.TokenDetails memory tokenDetails = _isolatedTokenDetails(name, symbol);
        ITREXFactory.ClaimDetails memory claimDetails = _emptyClaims();

        vm.recordLogs();
        vm.prank(deployer);
        trexFactory.deployTREXSuiteIsolated(salt, tokenDetails, claimDetails);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        tokenAddress = trexFactory.getToken(salt);

        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length >= 2 && logs[i].topics[0] == ISOLATED_SUITE_DEPLOYED_TOPIC
                    && logs[i].emitter == address(trexFactory)
            ) {
                assertEq(
                    address(uint160(uint256(logs[i].topics[1]))),
                    tokenAddress,
                    "IsolatedSuiteDeployed token topic must equal the deployed token address"
                );
                beacons = abi.decode(logs[i].data, (ITREXImplementationAuthority.SuiteBeacons));
                return (tokenAddress, beacons);
            }
        }
        revert("IsolatedSuiteDeployed event not emitted");
    }

    /// @notice Behavior: deploying an isolated suite mints 4 fresh beacons owned by the suite's own
    ///         AccessManager, pointing at the registry's current implementations, and leaves the shared
    ///         registry's beacons + their ownership untouched.
    function test_deployIsolatedSuite_OwnsClonedBeacons() public {
        ITREXImplementationAuthority.SuiteBeacons memory sharedBefore = trexImplementationAuthority.beacons();

        (, ITREXImplementationAuthority.SuiteBeacons memory beacons) =
            _deployIsolatedSuiteAndReadBeacons("isolated-salt", "Iso", "ISO");

        // each cloned beacon must be distinct from its shared counterpart
        assertNotEq(beacons.tokenBeacon, sharedBefore.tokenBeacon, "token beacon must be cloned");
        assertNotEq(beacons.trexRegistryBeacon, sharedBefore.trexRegistryBeacon, "registry beacon must be cloned");
        assertNotEq(beacons.irsBeacon, sharedBefore.irsBeacon, "irs beacon must be cloned");
        assertNotEq(beacons.mcBeacon, sharedBefore.mcBeacon, "mc beacon must be cloned");

        // each cloned beacon must be owned by the suite AccessManager
        assertEq(
            UpgradeableBeacon(beacons.tokenBeacon).owner(),
            address(accessManager),
            "token beacon owner must be the suite AccessManager"
        );
        assertEq(
            UpgradeableBeacon(beacons.trexRegistryBeacon).owner(),
            address(accessManager),
            "registry beacon owner must be the suite AccessManager"
        );
        assertEq(
            UpgradeableBeacon(beacons.irsBeacon).owner(),
            address(accessManager),
            "irs beacon owner must be the suite AccessManager"
        );
        assertEq(
            UpgradeableBeacon(beacons.mcBeacon).owner(),
            address(accessManager),
            "mc beacon owner must be the suite AccessManager"
        );

        // each cloned beacon's implementation must equal the authority's active implementations
        ITREXImplementationAuthority.SuiteImplementations memory expected =
            trexImplementationAuthority.implementationsFor(trexImplementationAuthority.currentVersion());
        assertEq(
            UpgradeableBeacon(beacons.tokenBeacon).implementation(),
            expected.tokenImplementation,
            "token beacon must point at the registry's current token implementation"
        );
        assertEq(
            UpgradeableBeacon(beacons.trexRegistryBeacon).implementation(),
            expected.trexRegistryImplementation,
            "registry beacon must point at the authority's current registry implementation"
        );
        assertEq(
            UpgradeableBeacon(beacons.irsBeacon).implementation(),
            expected.irsImplementation,
            "irs beacon must point at the registry's current irs implementation"
        );
        assertEq(
            UpgradeableBeacon(beacons.mcBeacon).implementation(),
            expected.mcImplementation,
            "mc beacon must point at the registry's current mc implementation"
        );

        // the shared registry's beacons must be untouched and still owned by the registry
        ITREXImplementationAuthority.SuiteBeacons memory sharedAfter = trexImplementationAuthority.beacons();
        assertEq(sharedAfter.tokenBeacon, sharedBefore.tokenBeacon, "shared token beacon must be stable");
        assertEq(
            sharedAfter.trexRegistryBeacon, sharedBefore.trexRegistryBeacon, "shared registry beacon must be stable"
        );
        assertEq(sharedAfter.irsBeacon, sharedBefore.irsBeacon, "shared irs beacon must be stable");
        assertEq(sharedAfter.mcBeacon, sharedBefore.mcBeacon, "shared mc beacon must be stable");
        assertEq(
            UpgradeableBeacon(sharedAfter.tokenBeacon).owner(),
            address(trexImplementationAuthority),
            "shared token beacon must stay registry-owned"
        );
        assertEq(
            UpgradeableBeacon(sharedAfter.mcBeacon).owner(),
            address(trexImplementationAuthority),
            "shared mc beacon must stay registry-owned"
        );
    }

    /// @notice Behavior: a registry-wide `publishAndUpgrade` swaps the shared-mode token's implementation
    ///         (sentinel function appears) without touching the isolated suite (sentinel still reverts).
    function test_publishAndUpgrade_DoesNotAffectIsolatedSuite() public {
        (address isolatedToken,) = _deployIsolatedSuiteAndReadBeacons("isolated-salt", "Iso", "ISO");

        // pre-upgrade: neither suite exposes the v2 sentinel
        vm.expectRevert();
        MockTokenV2(address(token)).mockTokenV2Version();
        vm.expectRevert();
        MockTokenV2(isolatedToken).mockTokenV2Version();

        // registry owner publishes v5.0.1 with a MockTokenV2 token implementation
        MockTokenV2 v2Implementation = new MockTokenV2();
        ITREXImplementationAuthority.Version memory v1 =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 1 });
        ITREXImplementationAuthority.SuiteImplementations memory impls =
            ITREXImplementationAuthority.SuiteImplementations({
                tokenImplementation: address(v2Implementation),
                trexRegistryImplementation: address(trexRegistryImplementation),
                irsImplementation: address(identityRegistryStorageImplementation),
                mcImplementation: address(modularComplianceImplementation)
            });
        vm.prank(deployer);
        trexImplementationAuthority.publishAndUpgrade(v1, impls);

        // post-upgrade: shared-mode token picks up the new impl; isolated token still on v0
        assertEq(
            MockTokenV2(address(token)).mockTokenV2Version(),
            2,
            "shared-mode token must follow the registry's published upgrade"
        );
        vm.expectRevert();
        MockTokenV2(isolatedToken).mockTokenV2Version();
    }

    /// @notice Behavior: the isolated suite's AccessManager can rotate its token beacon through
    ///         `execute`. The isolated token picks up the new code, and the shared-mode token (which has
    ///         its own registry-owned beacon) is unaffected. `upgradeTo` is unmapped on the beacon target,
    ///         so it resolves to ADMIN_ROLE, held here by the test contract.
    function test_isolatedBeaconUpgrade_AffectsOnlyIsolatedSuite() public {
        (address isolatedToken, ITREXImplementationAuthority.SuiteBeacons memory beacons) =
            _deployIsolatedSuiteAndReadBeacons("isolated-salt", "Iso", "ISO");

        // pre-upgrade: neither suite exposes the v2 sentinel
        vm.expectRevert();
        MockTokenV2(isolatedToken).mockTokenV2Version();
        vm.expectRevert();
        MockTokenV2(address(token)).mockTokenV2Version();

        // the suite's AccessManager upgrades only the isolated token beacon
        MockTokenV2 v2Implementation = new MockTokenV2();
        accessManager.execute(
            beacons.tokenBeacon, abi.encodeCall(UpgradeableBeacon.upgradeTo, (address(v2Implementation)))
        );

        // post-upgrade: isolated token resolves to v2; shared-mode token stays on v0
        assertEq(
            MockTokenV2(isolatedToken).mockTokenV2Version(), 2, "isolated token must follow its own beacon upgrade"
        );
        vm.expectRevert();
        MockTokenV2(address(token)).mockTokenV2Version();
    }

    /// @notice Behavior: calling `upgradeTo` directly never works, whoever the caller is: the beacon is
    ///         owned by the AccessManager, so OZ Ownable rejects every external account.
    function test_directCallerCannotUpgradeIsolatedBeacons() public {
        (, ITREXImplementationAuthority.SuiteBeacons memory beacons) =
            _deployIsolatedSuiteAndReadBeacons("isolated-salt", "Iso", "ISO");

        MockTokenV2 v2Implementation = new MockTokenV2();

        address randomAccount = makeAddr("randomAccount");
        vm.prank(randomAccount);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomAccount));
        UpgradeableBeacon(beacons.tokenBeacon).upgradeTo(address(v2Implementation));
    }

}
