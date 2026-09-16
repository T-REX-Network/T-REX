// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";

import {
    ClaimTopicsRegistryHarness,
    IdentityRegistryHarness,
    IdentityRegistryStorageHarness,
    TrustedIssuersRegistryHarness
} from "./harnesses/StandardHarnesses.sol";

/// @dev ERC-3643 standard: Identity Registry.
///
///  Runs against the standard bases alone (issue #65), wired the way the specification describes them:
///  four separate contracts, the registry pointing at the other three. T-REX consolidates them into one
///  address, which is an extension-layer choice; this file deliberately exercises the un-consolidated
///  shape, so it must pass unchanged when OpenZeppelin's bases replace ours.
contract IdentityRegistryStandardTest is Test {

    IdentityRegistryHarness internal registry;
    IdentityRegistryStorageHarness internal identityStorage;
    TrustedIssuersRegistryHarness internal issuersRegistry;
    ClaimTopicsRegistryHarness internal topicsRegistry;

    address internal investor = makeAddr("investor");
    IIdentity internal identity = IIdentity(makeAddr("identity"));
    IIdentity internal newIdentity = IIdentity(makeAddr("newIdentity"));

    uint16 internal constant COUNTRY = 42;

    function setUp() public {
        identityStorage = new IdentityRegistryStorageHarness();
        issuersRegistry = new TrustedIssuersRegistryHarness();
        topicsRegistry = new ClaimTopicsRegistryHarness();

        registry = new IdentityRegistryHarness();
        registry.init(address(identityStorage), address(issuersRegistry), address(topicsRegistry));

        identityStorage.bindIdentityRegistry(address(registry));
    }

    function test_collaborators_AreReadBack() public view {
        assertEq(address(registry.identityStorage()), address(identityStorage));
        assertEq(address(registry.issuersRegistry()), address(issuersRegistry));
        assertEq(address(registry.topicsRegistry()), address(topicsRegistry));
    }

    function test_registerIdentity_StoresThroughTheIdentityStorage() public {
        registry.registerIdentity(investor, identity, COUNTRY);

        assertTrue(registry.contains(investor));
        assertEq(address(registry.identity(investor)), address(identity));
        assertEq(registry.investorCountry(investor), COUNTRY);
        assertEq(address(identityStorage.storedIdentity(investor)), address(identity));
    }

    function test_registerIdentity_EmitsIdentityRegistered() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit IERC3643IdentityRegistry.IdentityRegistered(investor, identity);

        registry.registerIdentity(investor, identity, COUNTRY);
    }

    function test_contains_IsFalseForUnknownInvestor() public view {
        assertFalse(registry.contains(investor));
    }

    function test_batchRegisterIdentity_RegistersEveryEntry() public {
        address[] memory investors = new address[](2);
        investors[0] = investor;
        investors[1] = makeAddr("investor2");

        IIdentity[] memory identities = new IIdentity[](2);
        identities[0] = identity;
        identities[1] = newIdentity;

        uint16[] memory countries = new uint16[](2);
        countries[0] = COUNTRY;
        countries[1] = 7;

        registry.batchRegisterIdentity(investors, identities, countries);

        assertTrue(registry.contains(investors[0]));
        assertTrue(registry.contains(investors[1]));
        assertEq(registry.investorCountry(investors[1]), 7);
    }

    function test_batchRegisterIdentity_RevertWhen_ArrayLengthsDiffer() public {
        address[] memory investors = new address[](2);
        IIdentity[] memory identities = new IIdentity[](1);
        uint16[] memory countries = new uint16[](2);

        vm.expectRevert(ERC3643ErrorsLib.ArrayLengthMismatch.selector);
        registry.batchRegisterIdentity(investors, identities, countries);
    }

    function test_updateIdentity_ReplacesTheIdentity() public {
        registry.registerIdentity(investor, identity, COUNTRY);

        registry.updateIdentity(investor, newIdentity);

        assertEq(address(registry.identity(investor)), address(newIdentity));
    }

    function test_updateIdentity_EmitsIdentityUpdated() public {
        registry.registerIdentity(investor, identity, COUNTRY);

        vm.expectEmit(true, true, false, true, address(registry));
        emit IERC3643IdentityRegistry.IdentityUpdated(identity, newIdentity);

        registry.updateIdentity(investor, newIdentity);
    }

    function test_updateCountry_ReplacesTheCountry() public {
        registry.registerIdentity(investor, identity, COUNTRY);

        registry.updateCountry(investor, 99);

        assertEq(registry.investorCountry(investor), 99);
    }

    function test_updateCountry_EmitsCountryUpdated() public {
        registry.registerIdentity(investor, identity, COUNTRY);

        vm.expectEmit(true, true, false, true, address(registry));
        emit IERC3643IdentityRegistry.CountryUpdated(investor, 99);

        registry.updateCountry(investor, 99);
    }

    function test_deleteIdentity_RemovesTheInvestor() public {
        registry.registerIdentity(investor, identity, COUNTRY);

        registry.deleteIdentity(investor);

        assertFalse(registry.contains(investor));
    }

    function test_deleteIdentity_EmitsIdentityRemoved() public {
        registry.registerIdentity(investor, identity, COUNTRY);

        vm.expectEmit(true, true, false, true, address(registry));
        emit IERC3643IdentityRegistry.IdentityRemoved(investor, identity);

        registry.deleteIdentity(investor);
    }

    function test_setIdentityRegistryStorage_RepointsAndEmits() public {
        IdentityRegistryStorageHarness replacement = new IdentityRegistryStorageHarness();

        vm.expectEmit(true, false, false, true, address(registry));
        emit IERC3643IdentityRegistry.IdentityStorageSet(address(replacement));

        registry.setIdentityRegistryStorage(address(replacement));

        assertEq(address(registry.identityStorage()), address(replacement));
    }

    function test_setClaimTopicsRegistry_RepointsAndEmits() public {
        ClaimTopicsRegistryHarness replacement = new ClaimTopicsRegistryHarness();

        vm.expectEmit(true, false, false, true, address(registry));
        emit IERC3643IdentityRegistry.ClaimTopicsRegistrySet(address(replacement));

        registry.setClaimTopicsRegistry(address(replacement));

        assertEq(address(registry.topicsRegistry()), address(replacement));
    }

    function test_setTrustedIssuersRegistry_RepointsAndEmits() public {
        TrustedIssuersRegistryHarness replacement = new TrustedIssuersRegistryHarness();

        vm.expectEmit(true, false, false, true, address(registry));
        emit IERC3643IdentityRegistry.TrustedIssuersRegistrySet(address(replacement));

        registry.setTrustedIssuersRegistry(address(replacement));

        assertEq(address(registry.issuersRegistry()), address(replacement));
    }

    function test_setIdentityRegistryStorage_RevertWhen_ZeroAddress() public {
        vm.expectRevert(ERC3643ErrorsLib.ZeroAddress.selector);
        registry.setIdentityRegistryStorage(address(0));
    }

    /// @dev An unregistered address is never verified.
    function test_isVerified_IsFalseForUnknownInvestor() public view {
        assertFalse(registry.isVerified(investor));
    }

    /// @dev With no required topics, a registered identity is verified without any claim being read.
    function test_isVerified_IsTrueWhenNoTopicsAreRequired() public {
        registry.registerIdentity(investor, identity, COUNTRY);

        assertTrue(registry.isVerified(investor));
    }

    /// @dev A required topic with no trusted issuer can never be satisfied.
    function test_isVerified_IsFalseWhenTopicHasNoTrustedIssuer() public {
        registry.registerIdentity(investor, identity, COUNTRY);
        topicsRegistry.addClaimTopic(1);

        assertFalse(registry.isVerified(investor));
    }

}
