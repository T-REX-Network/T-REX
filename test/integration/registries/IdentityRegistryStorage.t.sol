// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import {
    IERC3643IdentityRegistryStorage,
    IdentityRegistryStorage
} from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { MockContract } from "../mocks/MockContract.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { Countries } from "test/integration/helpers/Countries.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract IdentityRegistryStorageTest is TREXSuiteTest {

    // Contracts
    IdentityRegistryStorage public identityRegistryStorage;

    /// @notice Sets up IdentityRegistryStorage via proxy
    function setUp() public override {
        super.setUp();

        identityRegistryStorage = IdentityRegistryStorage(address(token.identityRegistry().identityStorage()));

        // bindIdentityRegistry is now gated by the transient IRS_BINDER role (not OWNER). deployer
        // already holds OWNER for the suite; grant it IRS_BINDER too so the bind-path tests can run.
        _grantIRSBinderRole(deployer);
        _grantStorageWriterRole(agent);

        // Note: In Hardhat fixture, identityRegistry.target is bound to storage in setUp
        // For Foundry, we start with 0 bound registries (tests will bind as needed)
    }

    // ============ init() Tests ============

    /// @notice Should revert when contract was already initialized
    function test_init_RevertWhen_AlreadyInitialized() public {
        vm.prank(deployer);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        identityRegistryStorage.init(deployer, address(0));
    }

    // ============ addIdentityToStorage() Tests ============

    /// @notice Should revert when sender is not agent
    function test_addIdentityToStorage_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.addIdentityToStorage(charlie, charlieIdentity, Countries.UNITED_STATES);
    }

    /// @notice Should revert when identity is zero address
    function test_addIdentityToStorage_RevertWhen_IdentityZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.addIdentityToStorage(charlie, IIdentity(address(0)), Countries.UNITED_STATES);
    }

    /// @notice Should revert when wallet is zero address
    function test_addIdentityToStorage_RevertWhen_WalletZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.addIdentityToStorage(address(0), charlieIdentity, Countries.UNITED_STATES);
    }

    /// @notice Should revert when wallet is already registered
    function test_addIdentityToStorage_RevertWhen_AlreadyStored() public {
        // Try to add bob again
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.AddressAlreadyStored.selector);
        identityRegistryStorage.addIdentityToStorage(bob, charlieIdentity, Countries.FRANCE);
    }

    /// @notice The country argument is ignored: only `IdentityStored` is emitted and no country is recorded.
    function test_addIdentityToStorage_IgnoresCountry() public {
        vm.recordLogs();
        vm.prank(agent);
        identityRegistryStorage.addIdentityToStorage(another, charlieIdentity, Countries.FRANCE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC3643IdentityRegistryStorage.IdentityStored.selector);
        assertEq(identityRegistryStorage.storedInvestorCountry(another), 0);
    }

    // ============ modifyStoredIdentity() Tests ============

    /// @notice `InvestorIdentityChanged` names the wallet the standard `IdentityModified` omits.
    function test_modifyStoredIdentity_EmitsInvestorIdentityChanged() public {
        vm.expectEmit(address(identityRegistryStorage));
        emit IERC3643IdentityRegistryStorage.IdentityModified(bobIdentity, charlieIdentity);
        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.InvestorIdentityChanged(bob);
        vm.prank(agent);
        identityRegistryStorage.modifyStoredIdentity(bob, charlieIdentity);

        assertEq(address(identityRegistryStorage.storedIdentity(bob)), address(charlieIdentity));
    }

    /// @notice Should revert when sender is not agent
    function test_modifyStoredIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.modifyStoredIdentity(charlie, charlieIdentity);
    }

    /// @notice Should revert when identity is zero address
    function test_modifyStoredIdentity_RevertWhen_IdentityZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.modifyStoredIdentity(charlie, IIdentity(address(0)));
    }

    /// @notice Should revert when wallet is zero address
    function test_modifyStoredIdentity_RevertWhen_WalletZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.modifyStoredIdentity(address(0), charlieIdentity);
    }

    /// @notice Should revert when wallet is not registered
    function test_modifyStoredIdentity_RevertWhen_NotStored() public {
        vm.prank(agent);
        identityRegistryStorage.removeIdentityFromStorage(charlie);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.AddressNotYetStored.selector);
        identityRegistryStorage.modifyStoredIdentity(charlie, charlieIdentity);
    }

    // ============ modifyStoredInvestorCountry() — deprecated ============

    /// @notice Deprecated: the storage keeps no country, so even an agent hits `Deprecated()`.
    function test_modifyStoredInvestorCountry_RevertWhen_Deprecated_AsAgent() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        identityRegistryStorage.modifyStoredInvestorCountry(charlie, Countries.UNITED_STATES);
    }

    /// @notice Deprecation takes precedence — non-agents get `Deprecated()`, never the access-managed error.
    function test_modifyStoredInvestorCountry_RevertWhen_Deprecated_AsOther() public {
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        identityRegistryStorage.modifyStoredInvestorCountry(charlie, Countries.UNITED_STATES);
    }

    // ============ removeIdentityFromStorage() Tests ============

    /// @notice Should revert when sender is not agent
    function test_removeIdentityFromStorage_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.removeIdentityFromStorage(charlie);
    }

    /// @notice Should revert when wallet is zero address
    function test_removeIdentityFromStorage_RevertWhen_WalletZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.removeIdentityFromStorage(address(0));
    }

    /// @notice Should revert when wallet is not registered
    function test_removeIdentityFromStorage_RevertWhen_NotStored() public {
        vm.prank(agent);
        identityRegistryStorage.removeIdentityFromStorage(charlie);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.AddressNotYetStored.selector);
        identityRegistryStorage.removeIdentityFromStorage(charlie);
    }

    // ============ bindIdentityRegistry() Tests ============

    /// @notice Should revert when sender lacks the IRS_BINDER role
    function test_bindIdentityRegistry_RevertWhen_NotBinder() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.bindIdentityRegistry(address(charlieIdentity));
    }

    /// @notice bind is gated by IRS_BINDER, not OWNER: holding OWNER alone must not authorize a bind.
    function test_bindIdentityRegistry_RevertWhen_OwnerWithoutBinderRole() public {
        address ownerOnly = makeAddr("ownerOnly");
        _grantOwnerRole(ownerOnly);

        vm.prank(ownerOnly);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ownerOnly));
        identityRegistryStorage.bindIdentityRegistry(address(charlieIdentity));
    }

    /// @notice Should revert when identity registry is zero address. The onlySharedAuthority guard rejects
    ///         address(0) (it cannot share the storage's authority), so the bind never proceeds.
    function test_bindIdentityRegistry_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.AuthorityMismatch.selector);
        identityRegistryStorage.bindIdentityRegistry(address(0));
    }

    /// @notice Should revert when there are already 299 identity registries bound
    function test_bindIdentityRegistry_RevertWhen_MoreThan299Registries() public {
        // Add 300 registries (max is 300, so length 300 means we have 300 registries)
        // Check is length < 300, so when length is 299, we can add one more (300th)
        // When length is 300, we cannot add more (301st should fail)
        for (uint256 i = 1; i < 300; i++) {
            address registryAddress = vm.addr(i + 1000);
            // bindIdentityRegistry is gated by onlySharedAuthority: each registry must report the storage's
            // AccessManager as its authority.
            vm.mockCall(
                registryAddress,
                abi.encodeWithSelector(IAccessManaged.authority.selector),
                abi.encode(address(accessManager))
            );
            vm.prank(deployer);
            identityRegistryStorage.bindIdentityRegistry(registryAddress);
        }

        // Try to add 301st registry (should fail, length is now 300, not < 300). It must also share the
        // authority so it reaches the count check rather than reverting on onlySharedAuthority first.
        address extraRegistry = vm.addr(2000);
        vm.mockCall(
            extraRegistry, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        uint256 maxBound = identityRegistryStorage.MAX_BOUND_REGISTRIES();
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxIRByIRSReached.selector, maxBound));
        identityRegistryStorage.bindIdentityRegistry(extraRegistry);
    }

    /// @notice Binding an already bound registry is a no-op: the set is unchanged and no event is emitted.
    function test_bindIdentityRegistry_NoOp_WhenAlreadyBound() public {
        address identityRegistry = address(token.identityRegistry());
        uint256 boundBefore = identityRegistryStorage.linkedIdentityRegistries().length;

        vm.recordLogs();
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(identityRegistry);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(identityRegistryStorage.linkedIdentityRegistries().length, boundBefore);
    }

    // ============ unbindIdentityRegistry() Tests ============

    /// @notice Should revert when sender is not owner
    function test_unbindIdentityRegistry_RevertWhen_NotOwner() public {
        // Bind first. bindIdentityRegistry is gated by onlySharedAuthority, so the bound address must report
        // the storage's AccessManager as its authority.
        vm.mockCall(
            address(charlieIdentity),
            abi.encodeWithSelector(IAccessManaged.authority.selector),
            abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(address(charlieIdentity));

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.unbindIdentityRegistry(address(charlieIdentity));
    }

    /// @notice Should revert when identity registry is zero address
    function test_unbindIdentityRegistry_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.unbindIdentityRegistry(address(0));
    }

    /// @notice Should revert when identity registry is not bound
    function test_unbindIdentityRegistry_RevertWhen_NotBound() public {
        address identityRegistry = address(token.identityRegistry());

        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(identityRegistry);

        vm.expectRevert(ErrorsLib.IdentityRegistryNotStored.selector);
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(identityRegistry);
    }

    /// @notice Should unbind the identity registry
    function test_unbindIdentityRegistry_Success() public {
        address identityRegistry = address(token.identityRegistry());

        vm.expectEmit(true, false, false, false);
        emit IERC3643IdentityRegistryStorage.IdentityRegistryUnbound(identityRegistry);
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(identityRegistry);
    }

    /// @notice Should unbind a registry located past index 0 (exercises the loop increment)
    function test_unbindIdentityRegistry_Success_WhenNotFirst() public {
        address firstIR = address(token.identityRegistry());
        address secondIR = makeAddr("secondIR");

        // bindIdentityRegistry is gated by onlySharedAuthority: the bound address must report the
        // storage's AccessManager as its authority.
        vm.mockCall(
            secondIR, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(secondIR);

        // Unbind the second one — match is at index 1, so the loop increments past index 0
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(secondIR);

        address[] memory linked = identityRegistryStorage.linkedIdentityRegistries();
        assertEq(linked.length, 1);
        assertEq(linked[0], firstIR);
    }

    // ============ linkedIdentityRegistries() Tests ============

    /// @notice Should return the list of bound identity registries
    function test_linkedIdentityRegistries_ReturnsBoundRegistries() public {
        address existingIR = address(token.identityRegistry());

        // Initially only the suite's IR is bound
        address[] memory initial = identityRegistryStorage.linkedIdentityRegistries();
        assertEq(initial.length, 1);
        assertEq(initial[0], existingIR);

        // Bind another registry and verify it appears. It must share the storage's authority to pass
        // the onlySharedAuthority guard.
        address extraIR = makeAddr("extraIR");
        vm.mockCall(
            extraIR, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(extraIR);

        address[] memory updated = identityRegistryStorage.linkedIdentityRegistries();
        assertEq(updated.length, 2);
        assertEq(updated[0], existingIR);
        assertEq(updated[1], extraIR);
    }

    // ============ isIdentityRegistryBound() / linkedIdentityRegistryCount() Tests ============

    /// @notice Should track membership as registries are bound and unbound
    function test_isIdentityRegistryBound_TracksBindAndUnbind() public {
        address existingIR = address(token.identityRegistry());
        address extraIR = makeAddr("extraIR");

        assertTrue(identityRegistryStorage.isIdentityRegistryBound(existingIR));
        assertFalse(identityRegistryStorage.isIdentityRegistryBound(extraIR));

        vm.mockCall(
            extraIR, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(extraIR);
        assertTrue(identityRegistryStorage.isIdentityRegistryBound(extraIR));

        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(extraIR);
        assertFalse(identityRegistryStorage.isIdentityRegistryBound(extraIR));
        assertTrue(identityRegistryStorage.isIdentityRegistryBound(existingIR));
    }

    /// @notice Should return false for the zero address, which is never bindable
    function test_isIdentityRegistryBound_ReturnsFalse_ForZeroAddress() public view {
        assertFalse(identityRegistryStorage.isIdentityRegistryBound(address(0)));
    }

    /// @notice Should agree with the length of the enumerated set at every step
    function test_linkedIdentityRegistryCount_MatchesEnumeratedLength() public {
        assertEq(
            identityRegistryStorage.linkedIdentityRegistryCount(),
            identityRegistryStorage.linkedIdentityRegistries().length
        );
        assertEq(identityRegistryStorage.linkedIdentityRegistryCount(), 1);

        address extraIR = makeAddr("extraIR");
        vm.mockCall(
            extraIR, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(extraIR);

        assertEq(identityRegistryStorage.linkedIdentityRegistryCount(), 2);
        assertEq(
            identityRegistryStorage.linkedIdentityRegistryCount(),
            identityRegistryStorage.linkedIdentityRegistries().length
        );

        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(extraIR);
        assertEq(identityRegistryStorage.linkedIdentityRegistryCount(), 1);
    }

    /// @notice A silent rebind must not double-count
    function test_linkedIdentityRegistryCount_Unchanged_OnRebind() public {
        address existingIR = address(token.identityRegistry());
        uint256 countBefore = identityRegistryStorage.linkedIdentityRegistryCount();

        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(existingIR);

        assertEq(identityRegistryStorage.linkedIdentityRegistryCount(), countBefore);
        assertTrue(identityRegistryStorage.isIdentityRegistryBound(existingIR));
    }

    // ============ linkedIdentityRegistries(start, end) pagination Tests ============

    /// @dev Binds `count` extra registries and returns them, sharing the storage authority so each
    ///  passes the onlySharedAuthority guard.
    function _bindExtraRegistries(uint256 count) internal returns (address[] memory extras) {
        extras = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            address extra = makeAddr(string.concat("pagedIR", vm.toString(i)));
            vm.mockCall(
                extra, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
            );
            vm.prank(deployer);
            identityRegistryStorage.bindIdentityRegistry(extra);
            extras[i] = extra;
        }
    }

    /// @notice Paging through the set in slices must reconstruct the full enumeration
    function test_linkedIdentityRegistriesPaged_ReassemblesFullSet() public {
        _bindExtraRegistries(4);

        address[] memory all = identityRegistryStorage.linkedIdentityRegistries();
        assertEq(all.length, 5);

        address[] memory assembled = new address[](all.length);
        uint256 filled = 0;
        for (uint256 start = 0; start < all.length; start += 2) {
            address[] memory page = identityRegistryStorage.linkedIdentityRegistries(start, start + 2);
            for (uint256 i = 0; i < page.length; i++) {
                assembled[filled++] = page[i];
            }
        }

        assertEq(filled, all.length);
        for (uint256 i = 0; i < all.length; i++) {
            assertEq(assembled[i], all[i]);
        }
    }

    /// @notice A page must match the same window of the full enumeration
    function test_linkedIdentityRegistriesPaged_MatchesFullEnumerationWindow() public {
        _bindExtraRegistries(3);

        address[] memory all = identityRegistryStorage.linkedIdentityRegistries();
        address[] memory page = identityRegistryStorage.linkedIdentityRegistries(1, 3);

        assertEq(page.length, 2);
        assertEq(page[0], all[1]);
        assertEq(page[1], all[2]);
    }

    /// @notice An end past the set size clamps instead of reverting
    function test_linkedIdentityRegistriesPaged_ClampsEndBeyondLength() public {
        _bindExtraRegistries(2);

        address[] memory page = identityRegistryStorage.linkedIdentityRegistries(0, 999);
        assertEq(page.length, identityRegistryStorage.linkedIdentityRegistryCount());
        assertEq(page.length, 3);
    }

    /// @notice A start past the set size yields an empty page, not a revert
    function test_linkedIdentityRegistriesPaged_ReturnsEmpty_WhenStartBeyondLength() public view {
        address[] memory page = identityRegistryStorage.linkedIdentityRegistries(50, 60);
        assertEq(page.length, 0);
    }

    /// @notice An inverted range yields an empty page, not a revert
    function test_linkedIdentityRegistriesPaged_ReturnsEmpty_WhenStartExceedsEnd() public {
        _bindExtraRegistries(2);

        address[] memory page = identityRegistryStorage.linkedIdentityRegistries(2, 1);
        assertEq(page.length, 0);
    }

    /// @notice An empty window inside the set yields an empty page
    function test_linkedIdentityRegistriesPaged_ReturnsEmpty_WhenStartEqualsEnd() public {
        _bindExtraRegistries(2);

        address[] memory page = identityRegistryStorage.linkedIdentityRegistries(1, 1);
        assertEq(page.length, 0);
    }

    /// @notice Documents the swap-and-pop reorder: an unbind moves the last entry into the freed slot,
    ///  so a page read across a mutation is not a consistent snapshot.
    function test_linkedIdentityRegistriesPaged_OrderShifts_WhenEarlierEntryUnbound() public {
        address[] memory extras = _bindExtraRegistries(3);
        address last = identityRegistryStorage.linkedIdentityRegistries(3, 4)[0];
        assertEq(last, extras[2]);

        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(extras[0]);

        // extras[0] sat at index 1; the tail entry took its place rather than the set shifting down.
        assertEq(identityRegistryStorage.linkedIdentityRegistries(1, 2)[0], last);
        assertEq(identityRegistryStorage.linkedIdentityRegistryCount(), 3);
    }

    // ============ storedIdentity() fallback / storedInvestorCountry() deprecated ============

    /// @notice storedIdentity returns the local identity when present (no fallback to global)
    function test_storedIdentity_UsesLocal_WhenPresent() public view {
        assertEq(address(identityRegistryStorage.storedIdentity(bob)), address(bobIdentity));
    }

    /// @notice storedIdentity falls back to the global identity registry when no local identity is stored
    function test_storedIdentity_FallsBackToGlobal_WhenLocalMissing() public {
        // `another` is a fresh wallet that has never been added to the local IRS.
        // Create its identity directly in the global IdentityFactory and check the fallback.
        address globalIdentity = address(_deployIdentity(another, "another"));

        assertEq(address(identityRegistryStorage.storedIdentity(another)), globalIdentity);
    }

    /// @notice storedIdentity returns address(0) when the wallet is unknown to both local and global
    function test_storedIdentity_ReturnsZero_WhenUnknownEverywhere() public view {
        assertEq(address(identityRegistryStorage.storedIdentity(another)), address(0));
    }

    /// @notice storedInvestorCountry returns 0 for every wallet, local or global-only
    function test_storedInvestorCountry_ReturnsZero_ForAnyWallet() public {
        _deployIdentity(another, "another");
        assertEq(identityRegistryStorage.storedInvestorCountry(bob), 0);
        assertEq(identityRegistryStorage.storedInvestorCountry(another), 0);
    }

    /// @notice With no registry bound there is no factory to fall back to: a global-only wallet
    ///         resolves to the zero identity
    function test_storedIdentity_ReturnsZero_WhenNoRegistryBound() public {
        address globalIdentity = address(_deployIdentity(another, "another"));
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(address(token.identityRegistry()));

        assertEq(address(identityRegistryStorage.storedIdentity(another)), address(0));
        assertNotEq(globalIdentity, address(0));
    }

    // ============ addIdentityToStorage() override signal ============

    /// @notice A local binding that shadows a different global identity is signalled by `IdentityOverridden`
    ///         right after the standard `IdentityStored`, and the local binding wins.
    function test_addIdentityToStorage_EmitsIdentityOverridden_WhenGlobalIdentityDiffers() public {
        IIdentity globalIdentity = _deployIdentity(another, "another");

        vm.expectEmit(address(identityRegistryStorage));
        emit IERC3643IdentityRegistryStorage.IdentityStored(another, charlieIdentity);
        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.IdentityOverridden(another, globalIdentity, charlieIdentity);
        vm.prank(agent);
        identityRegistryStorage.addIdentityToStorage(another, charlieIdentity, 0);

        assertEq(address(identityRegistryStorage.storedIdentity(another)), address(charlieIdentity));
    }

    /// @notice The signal reaches the agent path an issuer actually uses: registering through the registry.
    function test_registerIdentity_EmitsIdentityOverridden_ThroughRegistry() public {
        address globalOnly = makeAddr("globalOnly");
        IIdentity globalIdentity = _deployIdentity(globalOnly, "globalOnly");
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));

        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.IdentityOverridden(globalOnly, globalIdentity, charlieIdentity);
        vm.expectEmit(address(registry));
        emit IERC3643IdentityRegistry.IdentityRegistered(globalOnly, charlieIdentity);
        vm.prank(agent);
        registry.registerIdentity(globalOnly, charlieIdentity, 0);
    }

    /// @notice With no registry bound there is no global registry to compare against: only `IdentityStored`.
    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenNoRegistryBound() public {
        _deployIdentity(another, "another");
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(address(token.identityRegistry()));

        vm.recordLogs();
        vm.prank(agent);
        identityRegistryStorage.addIdentityToStorage(another, charlieIdentity, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC3643IdentityRegistryStorage.IdentityStored.selector);
    }

    // ============ modifyStoredIdentity() / removeIdentityFromStorage() override signal ============

    /// @notice Rewriting a local binding that still differs from the global identity keeps signalling the
    ///         divergence, after the two standard modification logs.
    function test_modifyStoredIdentity_EmitsIdentityOverridden_WhenGlobalIdentityDiffers() public {
        IIdentity globalIdentity = _deployIdentity(another, "another");
        vm.prank(agent);
        identityRegistryStorage.addIdentityToStorage(another, charlieIdentity, 0);

        vm.expectEmit(address(identityRegistryStorage));
        emit IERC3643IdentityRegistryStorage.IdentityModified(charlieIdentity, bobIdentity);
        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.InvestorIdentityChanged(another);
        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.IdentityOverridden(another, globalIdentity, bobIdentity);
        vm.prank(agent);
        identityRegistryStorage.modifyStoredIdentity(another, bobIdentity);

        assertEq(address(identityRegistryStorage.storedIdentity(another)), address(bobIdentity));
    }

    /// @notice Rewriting the local binding to exactly the global identity ends the override.
    function test_modifyStoredIdentity_EmitsIdentityOverrideReleased_WhenNewIdentityMatchesGlobal() public {
        IIdentity globalIdentity = _deployIdentity(another, "another");
        vm.prank(agent);
        identityRegistryStorage.addIdentityToStorage(another, charlieIdentity, 0);

        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.IdentityOverrideReleased(another, charlieIdentity, globalIdentity);
        vm.prank(agent);
        identityRegistryStorage.modifyStoredIdentity(another, globalIdentity);
    }

    /// @notice The signal reaches the agent path an issuer actually uses: updating through the registry.
    function test_updateIdentity_EmitsIdentityOverridden_ThroughRegistry() public {
        IIdentity globalIdentity = _deployIdentity(another, "another");
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        vm.prank(agent);
        registry.registerIdentity(another, charlieIdentity, 0);

        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.IdentityOverridden(another, globalIdentity, bobIdentity);
        vm.expectEmit(address(registry));
        emit IERC3643IdentityRegistry.IdentityUpdated(charlieIdentity, bobIdentity);
        vm.prank(agent);
        registry.updateIdentity(another, bobIdentity);
    }

    /// @notice Removing the local binding hands the wallet to a different global identity: never silent.
    function test_removeIdentityFromStorage_EmitsIdentityOverrideReleased_WhenGlobalIdentityDiffers() public {
        IIdentity globalIdentity = _deployIdentity(another, "another");
        vm.prank(agent);
        identityRegistryStorage.addIdentityToStorage(another, charlieIdentity, 0);

        vm.expectEmit(address(identityRegistryStorage));
        emit IERC3643IdentityRegistryStorage.IdentityUnstored(another, charlieIdentity);
        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.IdentityOverrideReleased(another, charlieIdentity, globalIdentity);
        vm.prank(agent);
        identityRegistryStorage.removeIdentityFromStorage(another);

        assertEq(address(identityRegistryStorage.storedIdentity(another)), address(globalIdentity));
        assertFalse(identityRegistryStorage.isLocallyRegistered(another));
    }

    /// @notice The release signal reaches the registry path too.
    function test_deleteIdentity_EmitsIdentityOverrideReleased_ThroughRegistry() public {
        IIdentity globalIdentity = _deployIdentity(another, "another");
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        vm.prank(agent);
        registry.registerIdentity(another, charlieIdentity, 0);

        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.IdentityOverrideReleased(another, charlieIdentity, globalIdentity);
        vm.expectEmit(address(registry));
        emit IERC3643IdentityRegistry.IdentityRemoved(another, charlieIdentity);
        vm.prank(agent);
        registry.deleteIdentity(another);
    }

    /// @notice A wallet the factory never minted has no global identity to fall back to: only `IdentityUnstored`.
    function test_removeIdentityFromStorage_EmitsOnlyIdentityUnstored_WhenWalletIsUnknownGlobally() public {
        vm.prank(agent);
        identityRegistryStorage.addIdentityToStorage(another, charlieIdentity, 0);

        vm.recordLogs();
        vm.prank(agent);
        identityRegistryStorage.removeIdentityFromStorage(another);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC3643IdentityRegistryStorage.IdentityUnstored.selector);
    }

    // ============ supportsInterface() Tests ============

    /// @notice Should return false for unsupported interfaces
    function test_supportsInterface_ReturnsFalse_ForUnsupported() public view {
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(identityRegistryStorage.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the IERC3643IdentityRegistryStorage interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC3643IdentityRegistryStorage() public view {
        assertTrue(identityRegistryStorage.supportsInterface(type(IERC3643IdentityRegistryStorage).interfaceId));
    }

    /// @notice IERC173 is part of the public interface via the AccessManagerOwnable ERC-173 ownership shim
    function test_supportsInterface_ReturnsTrue_ForIERC173() public view {
        assertTrue(identityRegistryStorage.supportsInterface(type(IERC173).interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public view {
        assertTrue(identityRegistryStorage.supportsInterface(type(IERC165).interfaceId));
    }

    // ============ Constructor Tests ============

    /// @notice Should revert when the beacon is the zero address
    function test_constructor_RevertWhen_BeaconIsZeroAddress() public {
        vm.expectRevert();
        new BeaconProxy(address(0), abi.encodeCall(IdentityRegistryStorage.init, (deployer, address(0))));
    }

    /// @notice Should revert when initialization fails (implementation without init())
    function test_constructor_RevertWhen_InitializationFails() public {
        MockContract mockImpl = new MockContract();
        address beacon = address(new UpgradeableBeacon(address(mockImpl), address(this)));

        // the delegatecall to mockImpl.init() finds no such function, so the proxy constructor reverts
        vm.expectRevert();
        new BeaconProxy(beacon, abi.encodeCall(IdentityRegistryStorage.init, (deployer, address(0))));
    }

}
