// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { IdentityRegistryStorageProxy } from "contracts/proxy/IdentityRegistryStorageProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { TREXImplementationAuthority } from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import {
    IERC3643IdentityRegistryStorage,
    IdentityRegistryStorage
} from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { MockContract } from "../mocks/MockContract.sol";
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

    // ============ modifyStoredIdentity() Tests ============

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

    // ============ modifyStoredInvestorCountry() Tests ============

    /// @notice Should revert when sender is not agent
    function test_modifyStoredInvestorCountry_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.modifyStoredInvestorCountry(charlie, Countries.UNITED_STATES);
    }

    /// @notice Should revert when wallet is zero address
    function test_modifyStoredInvestorCountry_RevertWhen_WalletZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.modifyStoredInvestorCountry(address(0), Countries.UNITED_STATES);
    }

    /// @notice Should revert when wallet is not registered
    function test_modifyStoredInvestorCountry_RevertWhen_NotStored() public {
        vm.prank(agent);
        identityRegistryStorage.removeIdentityFromStorage(charlie);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.AddressNotYetStored.selector);
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
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxIRByIRSReached.selector, 300));
        identityRegistryStorage.bindIdentityRegistry(extraRegistry);
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
        emit ERC3643EventsLib.IdentityRegistryUnbound(identityRegistry);
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(identityRegistry);
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

    /// @notice Should revert when implementation authority is zero address
    function test_constructor_RevertWhen_ImplementationAuthorityZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new IdentityRegistryStorageProxy(address(0), deployer, address(0));
    }

    /// @notice Should revert when initialization fails (invalid implementation)
    function test_constructor_RevertWhen_InitializationFails() public {
        // Deploy a mock contract that doesn't have init() function
        MockContract mockImpl = new MockContract();

        // Deploy an IA and manually set an invalid IRS implementation
        TREXImplementationAuthority incompleteIA =
            new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));

        // Create a version with invalid IRS implementation (mock contract without init())
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 0 });

        ITREXImplementationAuthority.TREXContracts memory contracts = ITREXImplementationAuthority.TREXContracts({
            tokenImplementation: address(mockImpl), // Invalid - doesn't have proper init
            irsImplementation: address(mockImpl), // Invalid - doesn't have init() function
            mcImplementation: address(mockImpl), // Invalid
            trexRegistryImplementation: address(mockImpl) // Invalid
        });

        // Add version to IA (need to be owner)
        _authorizeIAGovernance(address(incompleteIA));
        vm.prank(deployer);
        incompleteIA.addAndUseTREXVersion(version, contracts);

        // Now try to deploy proxy - delegatecall to mockImpl.init() will fail
        // because MockContract doesn't have init() function, so the proxy constructor bubbles the empty revert
        vm.expectRevert();
        new IdentityRegistryStorageProxy(address(incompleteIA), deployer, address(0));
    }

}
