// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//
/**
 *     NOTICE
 *
 *     The T-REX software is licensed under a proprietary license or the GPL v.3.
 *     If you choose to receive it under the GPL v.3 license, the following applies:
 *     T-REX is a suite of smart contracts implementing the ERC-3643 standard and
 *     developed by Tokeny to manage and transfer financial assets on EVM blockchains
 *
 *     Copyright (C) 2025, Tokeny sàrl.
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
pragma solidity ^0.8.30;

import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { IERC3643ClaimTopicsRegistry } from "contracts/ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643TrustedIssuersRegistry } from "contracts/ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";
import { ClaimIssuerTrick } from "../mocks/ClaimIssuerTrick.sol";

/// @title TREXRegistryTest
/// @notice Integration coverage for `TREXRegistry`: identity registration, trusted issuers, claim
///         topics and eligibility. Cross-registry address swaps (`setClaimTopicsRegistry` /
///         `setTrustedIssuersRegistry`) are covered by the deprecation assertions, and proxy/init
///         zero-address paths are owned by the unit suites under `test/unit/trex-registry/**`.
contract TREXRegistryTest is TREXSuiteTest {

    TREXRegistry public registry;

    // Extra claim topics reused across trusted-issuer scenarios.
    uint256 public constant CLAIM_TOPIC_2 = 42;
    uint256 public constant CLAIM_TOPIC_3 = 66;
    uint256 public constant CLAIM_TOPIC_4 = 100;

    /// @notice Deploys a token that seeds the registry with `CLAIM_TOPIC_1` and the suite's
    ///         trusted issuer, registers the three identities, and issues alice + bob the matching
    ///         claim so the eligibility scenarios have a verified baseline to mutate from.
    function setUp() public override {
        super.setUp();

        token = _deployTokenWithClaimTopic("trex-registry", "TREX Token", "TRX");
        registry = TREXRegistry(address(token.identityRegistry()));

        _registerIdentities(token);

        bytes memory claimData = "Some claim public data.";
        _addClaim(aliceIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), alice);
        _addClaim(bobIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), bob);
    }

    // =============================================================================================
    // init() — re-init guard at integration level (zero-address branches live in
    // TREXRegistryInitUnitTest).
    // =============================================================================================

    /// @notice Re-initializing a registry already produced by the factory must revert.
    function test_init_RevertWhen_AlreadyInitialized() public {
        address irs = address(registry.identityStorage());
        vm.prank(deployer);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.init(irs, address(accessManager), new uint256[](0), new address[](0), new uint256[][](0));
    }

    // =============================================================================================
    // Identity sub-surface
    // =============================================================================================

    /// @notice Updating an identity emits `IdentityUpdated` and persists the new identity.
    function test_identity_updateIdentity_Success() public {
        IIdentity oldIdentity = registry.identity(bob);
        assertEq(address(oldIdentity), address(bobIdentity));

        vm.expectEmit(true, true, false, false, address(registry));
        emit ERC3643EventsLib.IdentityUpdated(oldIdentity, charlieIdentity);
        vm.prank(agent);
        registry.updateIdentity(bob, charlieIdentity);

        assertEq(address(registry.identity(bob)), address(charlieIdentity));
    }

    /// @notice `setIdentityRegistryStorage` is OWNER-only — non-owner callers are rejected by the
    ///         AccessManager.
    function test_identity_setIdentityRegistryStorage_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.setIdentityRegistryStorage(address(0));
    }

    /// @notice The owner can swap the identity storage and `IdentityStorageSet` is emitted.
    function test_identity_setIdentityRegistryStorage_Success() public {
        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.IdentityStorageSet(address(0));
        registry.setIdentityRegistryStorage(address(0));

        assertEq(address(registry.identityStorage()), address(0));
    }

    // =============================================================================================
    // Deprecated cross-registry setters
    // =============================================================================================

    /// @notice `setClaimTopicsRegistry` is deprecated. The deprecation revert beats the
    ///         AccessManager check, so any caller hits `Deprecated()`.
    function test_deprecation_setClaimTopicsRegistry_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setClaimTopicsRegistry(address(0));
    }

    /// @notice `setClaimTopicsRegistry` reverts even for the owner — this registry is its own
    ///         claim-topics registry.
    function test_deprecation_setClaimTopicsRegistry_RevertWhen_Owner() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setClaimTopicsRegistry(address(0));
    }

    /// @notice `setTrustedIssuersRegistry` is deprecated — non-owner callers hit `Deprecated()`.
    function test_deprecation_setTrustedIssuersRegistry_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setTrustedIssuersRegistry(address(0));
    }

    /// @notice `setTrustedIssuersRegistry` reverts even for the owner.
    function test_deprecation_setTrustedIssuersRegistry_RevertWhen_Owner() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setTrustedIssuersRegistry(address(0));
    }

    /// @notice The registry reports itself for both sibling registries.
    function test_identity_topicsAndIssuersReturnSelf() public view {
        assertEq(address(registry.topicsRegistry()), address(registry));
        assertEq(address(registry.issuersRegistry()), address(registry));
    }

    // =============================================================================================
    // Eligibility checks
    // =============================================================================================

    /// @notice With no required claim topics, any registered identity is verified.
    function test_eligibility_isVerified_ReturnsTrue_WhenNoClaimTopics() public {
        // charlie has an identity registered but no claim → not yet verified for CLAIM_TOPIC_1.
        assertFalse(registry.isVerified(charlie));

        // Drop every required claim topic.
        uint256[] memory topics = registry.getClaimTopics();
        for (uint256 i = 0; i < topics.length; i++) {
            vm.prank(deployer);
            registry.removeClaimTopic(topics[i]);
        }

        assertTrue(registry.isVerified(charlie));
    }

    /// @notice When a required claim topic has no trusted issuers, verification fails.
    function test_eligibility_isVerified_ReturnsFalse_WhenNoTrustedIssuersForClaimTopic() public {
        assertTrue(registry.isVerified(alice));

        uint256[] memory topics = registry.getClaimTopics();
        address[] memory trustedIssuers = registry.getTrustedIssuersForClaimTopic(topics[0]);
        for (uint256 i = 0; i < trustedIssuers.length; i++) {
            vm.prank(deployer);
            registry.removeTrustedIssuer(trustedIssuers[i]);
        }

        assertFalse(registry.isVerified(alice));
    }

    /// @notice Revoking the only claim flips verification to false.
    function test_eligibility_isVerified_ReturnsFalse_WhenClaimRevoked() public {
        assertTrue(registry.isVerified(alice));

        uint256[] memory topics = registry.getClaimTopics();
        bytes32[] memory claimIds = aliceIdentity.getClaimIdsByTopic(topics[0]);
        // Revocation is now keyed by the EIP-712 claim digest rather than the raw signature.
        (,,,, Structs.ClaimData memory data,) = aliceIdentity.getClaim(claimIds[0]);
        bytes32 digest = IIdentity(address(claimIssuer)).getClaimHash(address(aliceIdentity), topics[0], data);

        vm.prank(claimIssuerSigner.addr);
        IClaimIssuer(address(claimIssuer)).revokeClaimByDigest(digest);

        assertFalse(registry.isVerified(alice));
    }

    /// @notice A claim issuer that throws does not poison verification when another valid claim
    ///         exists for the same topic.
    function test_eligibility_isVerified_ReturnsTrue_WhenClaimIssuerThrowsButOtherValidClaimExists() public {
        ClaimIssuerTrick trickyClaimIssuer = new ClaimIssuerTrick(address(validatorModule));

        uint256[] memory topics = registry.getClaimTopics();
        uint256 topic = topics[0];

        vm.startPrank(deployer);
        registry.removeTrustedIssuer(address(claimIssuer));
        registry.addTrustedIssuer(address(trickyClaimIssuer), topics);
        registry.addTrustedIssuer(address(claimIssuer), topics);
        vm.stopPrank();

        // Alice keeps her valid claim from setUp and gains a second one from the tricky issuer. Claim
        // ids are keyed by (issuer, topic), so the two coexist rather than overwrite. The valid claim
        // is deliberately left untouched: removing a claim revokes its digest for good, so it could
        // not be added back.
        // Built before the prank: constructing the claim data calls the validator, which would
        // otherwise consume the prank meant for addClaim.
        Structs.ClaimData memory trickyData = _trickyClaimData();
        vm.prank(alice);
        aliceIdentity.addClaim(topic, 1, address(trickyClaimIssuer), "0x00", trickyData, "");

        assertTrue(registry.isVerified(alice));
    }

    /// @notice A throwing claim issuer with no other valid claim leads to a verification failure.
    function test_eligibility_isVerified_ReturnsFalse_WhenClaimIssuerThrowsAndNoOtherValidClaim() public {
        ClaimIssuerTrick trickyClaimIssuer = new ClaimIssuerTrick(address(validatorModule));

        uint256[] memory topics = registry.getClaimTopics();
        uint256 topic = topics[0];

        vm.prank(deployer);
        registry.addTrustedIssuer(address(trickyClaimIssuer), topics);

        bytes32[] memory claimIds = aliceIdentity.getClaimIdsByTopic(topic);
        vm.prank(alice);
        aliceIdentity.removeClaim(claimIds[0]);

        // Built before the prank: constructing the claim data calls the validator, which would
        // otherwise consume the prank meant for addClaim.
        Structs.ClaimData memory trickyData = _trickyClaimData();
        vm.prank(alice);
        aliceIdentity.addClaim(topic, 1, address(trickyClaimIssuer), "0x00", trickyData, "");

        assertFalse(registry.isVerified(alice));
    }

    /// @notice `disableEligibilityChecks` is OWNER-only.
    function test_eligibility_disableEligibilityChecks_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.disableEligibilityChecks();
    }

    /// @notice Disabling eligibility checks short-circuits `isVerified` to true for every address.
    function test_eligibility_disableEligibilityChecks_Success() public {
        vm.prank(deployer);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.EligibilityChecksDisabled();
        registry.disableEligibilityChecks();

        assertTrue(registry.isVerified(charlie));
    }

    /// @notice Disabling twice in a row reverts with `EligibilityChecksDisabledAlready`.
    function test_eligibility_disableEligibilityChecks_RevertWhen_AlreadyDisabled() public {
        vm.prank(deployer);
        registry.disableEligibilityChecks();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EligibilityChecksDisabledAlready.selector);
        registry.disableEligibilityChecks();
    }

    /// @notice `enableEligibilityChecks` is OWNER-only.
    function test_eligibility_enableEligibilityChecks_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.enableEligibilityChecks();
    }

    /// @notice Re-enabling after a disable restores eligibility enforcement.
    function test_eligibility_enableEligibilityChecks_Success() public {
        vm.prank(deployer);
        registry.disableEligibilityChecks();
        assertTrue(registry.isVerified(another));

        vm.prank(deployer);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.EligibilityChecksEnabled();
        registry.enableEligibilityChecks();

        assertFalse(registry.isVerified(another));
    }

    /// @notice Enabling when already enabled reverts with `EligibilityChecksEnabledAlready`.
    function test_eligibility_enableEligibilityChecks_RevertWhen_AlreadyEnabled() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EligibilityChecksEnabledAlready.selector);
        registry.enableEligibilityChecks();
    }

    /// @notice After re-enabling, registered-but-unclaimed addresses fall back to false.
    function test_eligibility_isVerified_ResumesNormalChecks_WhenReEnabled() public {
        vm.prank(deployer);
        registry.disableEligibilityChecks();
        assertTrue(registry.isVerified(charlie));

        vm.prank(deployer);
        registry.enableEligibilityChecks();

        uint256[] memory topics = registry.getClaimTopics();
        if (topics.length > 0) {
            assertFalse(registry.isVerified(charlie));
        } else {
            assertTrue(registry.isVerified(charlie));
        }
    }

    // =============================================================================================
    // Trusted issuers sub-surface
    // =============================================================================================

    /// @notice `addTrustedIssuer` is OWNER-only.
    function test_trustedIssuer_addTrustedIssuer_RevertWhen_NotOwner() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        address anotherClaimIssuer = makeAddr("anotherClaimIssuer");
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.addTrustedIssuer(address(anotherClaimIssuer), claimTopics);
    }

    /// @notice `addTrustedIssuer` rejects the zero issuer address.
    function test_trustedIssuer_addTrustedIssuer_RevertWhen_ZeroAddress() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        registry.addTrustedIssuer(address(0), claimTopics);
    }

    /// @notice `addTrustedIssuer` refuses to register the same issuer twice.
    function test_trustedIssuer_addTrustedIssuer_RevertWhen_AlreadyRegistered() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TrustedIssuerAlreadyExists.selector);
        registry.addTrustedIssuer(address(claimIssuer), claimTopics);
    }

    /// @notice `addTrustedIssuer` rejects an empty topics array.
    function test_trustedIssuer_addTrustedIssuer_RevertWhen_ClaimTopicsEmpty() public {
        address newClaimIssuer = makeAddr("newClaimIssuer");
        uint256[] memory emptyClaimTopics = new uint256[](0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TrustedClaimTopicsCannotBeEmpty.selector);
        registry.addTrustedIssuer(address(newClaimIssuer), emptyClaimTopics);
    }

    /// @notice `addTrustedIssuer` enforces the 15-topic cap per issuer.
    function test_trustedIssuer_addTrustedIssuer_RevertWhen_MoreThan15ClaimTopics() public {
        address newClaimIssuer = makeAddr("newClaimIssuer");
        uint256[] memory claimTopics = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            claimTopics[i] = i;
        }

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        registry.addTrustedIssuer(address(newClaimIssuer), claimTopics);
    }

    /// @notice `addTrustedIssuer` enforces the 50-issuer cap (setup contributes one, so we top up
    ///         to 50 and the 51st must fail).
    function test_trustedIssuer_addTrustedIssuer_RevertWhen_MoreThan49Issuers() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        for (uint256 i = 0; i < 49; i++) {
            address issuerAddress = address(uint160(uint256(keccak256(abi.encodePacked("issuer", i)))));
            vm.prank(deployer);
            registry.addTrustedIssuer(issuerAddress, claimTopics);
        }

        address fiftyFirstClaimIssuer = makeAddr("fiftyFirstClaimIssuer");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxTrustedIssuersReached.selector, 50));
        registry.addTrustedIssuer(address(fiftyFirstClaimIssuer), claimTopics);
    }

    /// @notice `removeTrustedIssuer` is OWNER-only.
    function test_trustedIssuer_removeTrustedIssuer_RevertWhen_NotOwner() public {
        address anotherClaimIssuerForRemove = makeAddr("anotherClaimIssuerForRemove");

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.removeTrustedIssuer(address(anotherClaimIssuerForRemove));
    }

    /// @notice `removeTrustedIssuer` rejects the zero issuer address.
    function test_trustedIssuer_removeTrustedIssuer_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        registry.removeTrustedIssuer(address(0));
    }

    /// @notice `removeTrustedIssuer` reverts when the issuer is unknown.
    function test_trustedIssuer_removeTrustedIssuer_RevertWhen_NotRegistered() public {
        address newClaimIssuer = makeAddr("newClaimIssuer");

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.NotATrustedIssuer.selector);
        registry.removeTrustedIssuer(address(newClaimIssuer));
    }

    /// @notice Removing a middle issuer drops it from the list and `TrustedIssuerRemoved` is emitted.
    function test_trustedIssuer_removeTrustedIssuer_Success() public {
        address bobClaimIssuer = makeAddr("bobClaimIssuer");
        address anotherClaimIssuer = makeAddr("anotherClaimIssuer");
        address charlieClaimIssuer = makeAddr("charlieClaimIssuer");

        uint256[] memory topicsBob = new uint256[](3);
        topicsBob[0] = CLAIM_TOPIC_3;
        topicsBob[1] = CLAIM_TOPIC_4;
        topicsBob[2] = CLAIM_TOPIC_1;

        uint256[] memory topicsAnother = new uint256[](2);
        topicsAnother[0] = CLAIM_TOPIC_1;
        topicsAnother[1] = CLAIM_TOPIC_2;

        uint256[] memory topicsCharlie = new uint256[](3);
        topicsCharlie[0] = CLAIM_TOPIC_2;
        topicsCharlie[1] = CLAIM_TOPIC_3;
        topicsCharlie[2] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        registry.addTrustedIssuer(address(bobClaimIssuer), topicsBob);
        vm.prank(deployer);
        registry.addTrustedIssuer(address(anotherClaimIssuer), topicsAnother);
        vm.prank(deployer);
        registry.addTrustedIssuer(address(charlieClaimIssuer), topicsCharlie);

        assertTrue(registry.isTrustedIssuer(address(anotherClaimIssuer)));

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.TrustedIssuerRemoved(address(anotherClaimIssuer));
        registry.removeTrustedIssuer(address(anotherClaimIssuer));

        assertFalse(registry.isTrustedIssuer(address(anotherClaimIssuer)));

        address[] memory trustedIssuers = registry.getTrustedIssuers();
        assertEq(trustedIssuers.length, 3);
        assertEq(address(trustedIssuers[0]), address(claimIssuer));
        assertEq(address(trustedIssuers[1]), address(bobClaimIssuer));
        assertEq(address(trustedIssuers[2]), address(charlieClaimIssuer));
    }

    /// @notice `updateIssuerClaimTopics` is OWNER-only.
    function test_trustedIssuer_updateIssuerClaimTopics_RevertWhen_NotOwner() public {
        address anotherClaimIssuerForUpdate = makeAddr("anotherClaimIssuerForUpdate");
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.updateIssuerClaimTopics(address(anotherClaimIssuerForUpdate), claimTopics);
    }

    /// @notice `updateIssuerClaimTopics` rejects the zero issuer address.
    function test_trustedIssuer_updateIssuerClaimTopics_RevertWhen_ZeroAddress() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        registry.updateIssuerClaimTopics(address(0), claimTopics);
    }

    /// @notice `updateIssuerClaimTopics` reverts when the issuer is unknown.
    function test_trustedIssuer_updateIssuerClaimTopics_RevertWhen_NotRegistered() public {
        address newClaimIssuer = makeAddr("newClaimIssuer");
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.NotATrustedIssuer.selector);
        registry.updateIssuerClaimTopics(address(newClaimIssuer), claimTopics);
    }

    /// @notice `updateIssuerClaimTopics` enforces the 15-topic cap.
    function test_trustedIssuer_updateIssuerClaimTopics_RevertWhen_MoreThan15ClaimTopics() public {
        uint256[] memory claimTopics = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            claimTopics[i] = i;
        }

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        registry.updateIssuerClaimTopics(address(claimIssuer), claimTopics);
    }

    /// @notice `updateIssuerClaimTopics` rejects an empty topics array.
    function test_trustedIssuer_updateIssuerClaimTopics_RevertWhen_ClaimTopicsEmpty() public {
        uint256[] memory emptyClaimTopics = new uint256[](0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ClaimTopicsCannotBeEmpty.selector);
        registry.updateIssuerClaimTopics(address(claimIssuer), emptyClaimTopics);
    }

    /// @notice `updateIssuerClaimTopics` rewrites the issuer's topic set and emits
    ///         `ClaimTopicsUpdated`.
    function test_trustedIssuer_updateIssuerClaimTopics_Success() public {
        uint256[] memory initialTopics = registry.getTrustedIssuerClaimTopics(address(claimIssuer));
        assertGt(initialTopics.length, 0);

        uint256[] memory newTopics = new uint256[](2);
        newTopics[0] = CLAIM_TOPIC_3;
        newTopics[1] = CLAIM_TOPIC_4;

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.ClaimTopicsUpdated(address(claimIssuer), newTopics);
        registry.updateIssuerClaimTopics(address(claimIssuer), newTopics);

        assertTrue(registry.hasClaimTopic(address(claimIssuer), CLAIM_TOPIC_3));
        assertTrue(registry.hasClaimTopic(address(claimIssuer), CLAIM_TOPIC_4));
        assertFalse(registry.hasClaimTopic(address(claimIssuer), initialTopics[0]));

        uint256[] memory retrievedTopics = registry.getTrustedIssuerClaimTopics(address(claimIssuer));
        assertEq(retrievedTopics.length, 2);
        assertEq(retrievedTopics[0], CLAIM_TOPIC_3);
        assertEq(retrievedTopics[1], CLAIM_TOPIC_4);
    }

    /// @notice Covers the inner-loop increment in `updateIssuerClaimTopics`: the updated issuer
    ///         must not be the first entry in the per-topic array.
    function test_trustedIssuer_updateIssuerClaimTopics_CoversInnerLoopIncrement() public {
        address firstIssuer = makeAddr("firstIssuer");
        address secondIssuer = makeAddr("secondIssuer");

        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        registry.addTrustedIssuer(address(firstIssuer), topics);
        vm.prank(deployer);
        registry.addTrustedIssuer(address(secondIssuer), topics);

        uint256[] memory newTopics = new uint256[](1);
        newTopics[0] = CLAIM_TOPIC_2;

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.ClaimTopicsUpdated(address(secondIssuer), newTopics);
        registry.updateIssuerClaimTopics(address(secondIssuer), newTopics);

        assertFalse(registry.hasClaimTopic(address(secondIssuer), CLAIM_TOPIC_1));
        assertTrue(registry.hasClaimTopic(address(secondIssuer), CLAIM_TOPIC_2));
    }

    /// @notice `getTrustedIssuerClaimTopics` returns an empty set when the issuer is unknown.
    function test_trustedIssuer_getTrustedIssuerClaimTopics_ReturnsEmptyWhen_NotRegistered() public {
        address newClaimIssuer = makeAddr("newClaimIssuer");
        assertEq(registry.getTrustedIssuerClaimTopics(address(newClaimIssuer)).length, 0);
    }

    // =============================================================================================
    // Claim topics sub-surface
    // =============================================================================================

    /// @notice `addClaimTopic` is OWNER-only.
    function test_claimTopic_addClaimTopic_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.addClaimTopic(1);
    }

    /// @notice `addClaimTopic` enforces the 15-topic cap. `CLAIM_TOPIC_1` is already seeded by
    ///         the factory, so we add 14 more to reach the cap and the 15th post-seed addition
    ///         must revert.
    function test_claimTopic_addClaimTopic_RevertWhen_MoreThan14Topics() public {
        // Setup deploys with CLAIM_TOPIC_1 already added (length == 1). Fill up to 15 topics, then
        // try one more.
        for (uint256 i = 0; i < 14; i++) {
            vm.prank(deployer);
            registry.addClaimTopic(i);
        }

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        registry.addClaimTopic(15);
    }

    /// @notice `addClaimTopic` refuses to add the same topic twice.
    function test_claimTopic_addClaimTopic_RevertWhen_TopicAlreadyExists() public {
        vm.prank(deployer);
        registry.addClaimTopic(1);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ClaimTopicAlreadyExists.selector);
        registry.addClaimTopic(1);
    }

    /// @notice `removeClaimTopic` is OWNER-only.
    function test_claimTopic_removeClaimTopic_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.removeClaimTopic(1);
    }

    /// @notice Removing a middle topic emits `ClaimTopicRemoved`.
    function test_claimTopic_removeClaimTopic_Success() public {
        vm.prank(deployer);
        registry.addClaimTopic(1);
        vm.prank(deployer);
        registry.addClaimTopic(2);
        vm.prank(deployer);
        registry.addClaimTopic(3);

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.ClaimTopicRemoved(2);
        registry.removeClaimTopic(2);
    }

    // =============================================================================================
    // supportsInterface — integration smoke for the registry behind its proxy
    // =============================================================================================

    /// @notice Unknown interface ids return false through the proxy.
    function test_supportsInterface_ReturnsFalse_ForUnsupported() public view {
        assertFalse(registry.supportsInterface(0x12345678));
    }

    /// @notice IERC3643IdentityRegistry is supported.
    function test_supportsInterface_ReturnsTrue_ForIERC3643IdentityRegistry() public view {
        assertTrue(registry.supportsInterface(type(IERC3643IdentityRegistry).interfaceId));
    }

    /// @notice IERC3643TrustedIssuersRegistry is supported.
    function test_supportsInterface_ReturnsTrue_ForIERC3643TrustedIssuersRegistry() public view {
        assertTrue(registry.supportsInterface(type(IERC3643TrustedIssuersRegistry).interfaceId));
    }

    /// @notice IERC3643ClaimTopicsRegistry is supported.
    function test_supportsInterface_ReturnsTrue_ForIERC3643ClaimTopicsRegistry() public view {
        assertTrue(registry.supportsInterface(type(IERC3643ClaimTopicsRegistry).interfaceId));
    }

    /// @notice IERC173 (ownable) is supported.
    function test_supportsInterface_ReturnsTrue_ForIERC173() public view {
        assertTrue(registry.supportsInterface(type(IERC173).interfaceId));
    }

    /// @notice IERC165 is supported.
    function test_supportsInterface_ReturnsTrue_ForIERC165() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
    }

    /// @dev Claim envelope for the tricky issuer: the payload is never read because the issuer
    ///      reverts before inspecting it, but `issuedAt` must be set for the claim to be stored.
    function _trickyClaimData() private view returns (Structs.ClaimData memory) {
        return Structs.ClaimData({
            issuedAt: block.timestamp,
            validUntil: 0,
            metadataHash: validatorModule.getMetadataHash(1, ""),
            payload: "0x00"
        });
    }

}
