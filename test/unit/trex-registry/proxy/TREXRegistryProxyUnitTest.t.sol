// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test, Vm } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { TREXRegistryProxy } from "contracts/proxy/TREXRegistryProxy.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";

/// @notice Unit tests for `TREXRegistryProxy`.
/// @dev    Exercises constructor input validation (zero authority, zero IRS, zero AccessManager,
///         unset implementation) and successful initialization (`init` events emitted, post-deploy
///         ABI reachable through the fallback delegatecall).
contract TREXRegistryProxyUnitTest is Test {

    address public deployer = makeAddr("deployer");

    AccessManager public accessManager;
    TREXImplementationAuthority public ia;
    TREXRegistry public registryImpl;
    IdentityRegistryStorage public identityRegistryStorage;

    function setUp() public {
        accessManager = new AccessManager(address(this));

        accessManager.grantRole(RolesLib.OWNER, deployer, 0);

        // Deploy a reference IA owned/managed by `accessManager`.
        ia = new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(accessManager, address(ia));

        // Deploy a registry implementation that the IA will surface.
        registryImpl = new TREXRegistry();

        // Deploy a real IRS so that `TREXRegistry.init` checks succeed.
        IdentityRegistryStorage irsImpl = new IdentityRegistryStorage();
        identityRegistryStorage = IdentityRegistryStorage(
            address(
                new ERC1967Proxy(
                    address(irsImpl), abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0)))
                )
            )
        );

        // Register a TREX version that includes the registry implementation.
        vm.prank(deployer);
        ia.addAndUseTREXVersion(
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 }),
            ITREXImplementationAuthority.TREXContracts({
                tokenImplementation: makeAddr("tokenImpl"),
                irsImplementation: address(irsImpl),
                mcImplementation: makeAddr("mcImpl"),
                trexRegistryImplementation: address(registryImpl)
            })
        );
    }

    // ============ Constructor input validation ============

    /// @notice Should revert when the implementation authority is the zero address.
    function test_constructor_RevertWhen_ImplementationAuthorityZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXRegistryProxy(
            address(0),
            address(identityRegistryStorage),
            address(accessManager),
            new uint256[](0),
            new address[](0),
            new uint256[][](0)
        );
    }

    /// @notice Should revert when the IRS address is the zero address.
    function test_constructor_RevertWhen_IdentityStorageZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXRegistryProxy(
            address(ia), address(0), address(accessManager), new uint256[](0), new address[](0), new uint256[][](0)
        );
    }

    /// @notice Should revert when the AccessManager is the zero address.
    function test_constructor_RevertWhen_AccessManagerZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXRegistryProxy(
            address(ia),
            address(identityRegistryStorage),
            address(0),
            new uint256[](0),
            new address[](0),
            new uint256[][](0)
        );
    }

    /// @notice Should revert when the authority has no TREXRegistry implementation set.
    function test_constructor_RevertWhen_AuthorityHasNoImplementation() public {
        // A reference authority with no registered version: getTREXRegistryImplementation() == 0.
        // (A non-reference authority cannot be used here — it pins the reference contract's version
        // at construction, which reverts when no TREXFactory is wired.)
        TREXImplementationAuthority emptyAuthority =
            new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXRegistryProxy(
            address(emptyAuthority),
            address(identityRegistryStorage),
            address(accessManager),
            new uint256[](0),
            new address[](0),
            new uint256[][](0)
        );
    }

    // ============ Successful initialization ============

    /// @notice Should successfully deploy and emit the four init events at the proxy address.
    function test_constructor_Success_EmitsExpectedInitEvents() public {
        vm.recordLogs();
        TREXRegistryProxy proxy = new TREXRegistryProxy(
            address(ia),
            address(identityRegistryStorage),
            address(accessManager),
            new uint256[](0),
            new address[](0),
            new uint256[][](0)
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sigClaimTopicsRegistrySet = keccak256("ClaimTopicsRegistrySet(address)");
        bytes32 sigTrustedIssuersRegistrySet = keccak256("TrustedIssuersRegistrySet(address)");
        bytes32 sigIdentityStorageSet = keccak256("IdentityStorageSet(address)");
        bytes32 sigEligibilityChecksEnabled = keccak256("EligibilityChecksEnabled()");

        bool sawCTR;
        bool sawTIR;
        bool sawIRS;
        bool sawEligibility;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(proxy)) continue;
            bytes32 topic0 = entries[i].topics[0];
            if (topic0 == sigClaimTopicsRegistrySet) {
                sawCTR = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(proxy));
            } else if (topic0 == sigTrustedIssuersRegistrySet) {
                sawTIR = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(proxy));
            } else if (topic0 == sigIdentityStorageSet) {
                sawIRS = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(identityRegistryStorage));
            } else if (topic0 == sigEligibilityChecksEnabled) {
                sawEligibility = true;
            }
        }
        assertTrue(sawCTR, "ClaimTopicsRegistrySet missing");
        assertTrue(sawTIR, "TrustedIssuersRegistrySet missing");
        assertTrue(sawIRS, "IdentityStorageSet missing");
        assertTrue(sawEligibility, "EligibilityChecksEnabled missing");
    }

    /// @notice Should expose the registry ABI through the proxy fallback delegatecall.
    function test_proxyExposes_TREXRegistry_ABI() public {
        TREXRegistryProxy proxy = new TREXRegistryProxy(
            address(ia),
            address(identityRegistryStorage),
            address(accessManager),
            new uint256[](0),
            new address[](0),
            new uint256[][](0)
        );
        TREXRegistry registryAtProxy = TREXRegistry(address(proxy));

        // `topicsRegistry()` and `issuersRegistry()` resolve to `address(this)` — i.e., the proxy itself.
        assertEq(address(registryAtProxy.topicsRegistry()), address(proxy), "topicsRegistry must be self");
        assertEq(address(registryAtProxy.issuersRegistry()), address(proxy), "issuersRegistry must be self");

        // `identityStorage()` returns the externally configured IRS.
        assertEq(
            address(registryAtProxy.identityStorage()),
            address(identityRegistryStorage),
            "identityStorage must be the configured IRS"
        );

        // No claim topics, no trusted issuers, eligibility checks enabled by default.
        assertEq(registryAtProxy.getClaimTopics().length, 0, "claim topics must start empty");
        assertEq(registryAtProxy.getTrustedIssuers().length, 0, "trusted issuers must start empty");
    }

    /// @notice Should revert if the configured authority returns a non-contract implementation.
    /// @dev    `init` is called via `delegatecall` against the resolved logic — if logic has no code,
    ///         the call succeeds silently and only the zero-address guard above can catch it. Here we
    ///         pick an EOA-like address to ensure the implementation-authority-zero guard still fires
    ///         because that EOA's `getTREXRegistryImplementation()` will revert (no code → empty
    ///         returndata, decoded as garbage).
    function test_constructor_RevertWhen_AuthorityIsEOA() public {
        address fakeAuthority = makeAddr("fakeAuthority");
        vm.expectRevert();
        new TREXRegistryProxy(
            fakeAuthority,
            address(identityRegistryStorage),
            address(accessManager),
            new uint256[](0),
            new address[](0),
            new uint256[][](0)
        );
    }

    /// @notice Helper kept to ensure the imported `IAccessManager` symbol is referenced.
    function test_ConstructorSetup_HasOwnerRole() public view {
        (bool isOwner,) = IAccessManager(accessManager).hasRole(RolesLib.OWNER, deployer);
        assertTrue(isOwner, "deployer should have OWNER role");
    }

}
