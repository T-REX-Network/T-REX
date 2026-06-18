// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { TREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IAFactory, IIAFactory } from "contracts/proxy/authority/IAFactory.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { IProxy } from "contracts/proxy/interface/IProxy.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract TREXImplementationAuthorityTest is TREXSuiteTest {

    // ============ constructor() Tests ============

    /// @notice Should revert when the AccessManager (authority) is the zero address
    /// @dev OZ's AccessManaged constructor does not validate a zero authority, so the in-body
    ///      ZeroAddress guard is what rejects it.
    function test_constructor_RevertWhen_AccessManagerIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXImplementationAuthority(
            true, // is reference
            address(0), // trex factory
            address(0), // ia factory
            address(0) // access manager (zero -> revert)
        );
    }

    // ============ setTREXFactory() Tests ============

    /// @notice Should revert when called by not owner
    function test_setTREXFactory_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trexImplementationAuthority.setTREXFactory(address(0));
    }

    /// @notice Should revert when trex factory to add is not using this authority contract
    function test_setTREXFactory_RevertWhen_FactoryNotUsingThisAuthority() public {
        // Deploy another IA and factory using it
        TREXImplementationAuthority otherIA = _deployTREXImplementationAuthority(true);
        TREXFactory otherFactory = new TREXFactory(address(otherIA), address(idFactory), address(accessManager));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyReferenceContractCanCall.selector);
        trexImplementationAuthority.setTREXFactory(address(otherFactory));
    }

    /// @notice Should set the trex factory address
    function test_setTREXFactory_Success() public {
        // Deploy a new factory using this IA
        TREXFactory newFactory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(accessManager));

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit EventsLib.TREXFactorySet(address(newFactory));
        trexImplementationAuthority.setTREXFactory(address(newFactory));

        assertEq(trexImplementationAuthority.getTREXFactory(), address(newFactory));
    }

    // ============ setIAFactory() Tests ============

    /// @notice Should revert when called by not owner
    function test_setIAFactory_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trexImplementationAuthority.setIAFactory(address(0));
    }

    /// @notice Should set the IA factory address
    function test_setIAFactory_Success() public {
        // First set TREXFactory (required for setIAFactory)
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        // Deploy IAFactory
        IAFactory iaFactory = new IAFactory(address(trexFactory));

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit EventsLib.IAFactorySet(address(iaFactory));
        trexImplementationAuthority.setIAFactory(address(iaFactory));
    }

    /// @notice Should revert when setIAFactory is called on reference contract but factory references different IA
    /// @dev isReferenceContract() is true but getImplementationAuthority() != address(this)
    function test_setIAFactory_RevertWhen_FactoryReferencesDifferentIA() public {
        // Deploy another reference IA and factory using it
        TREXImplementationAuthority otherIA = _deployTREXImplementationAuthority(true);
        TREXFactory otherFactory = new TREXFactory(address(otherIA), address(idFactory), address(accessManager));

        // Create a new reference IA with the other factory in constructor
        // This factory references otherIASetup, not this IA
        vm.prank(deployer);
        TREXImplementationAuthority newIA = new TREXImplementationAuthority(
            true, // is reference
            address(otherFactory), // factory that references a different IA
            address(0), // no IAFactory
            address(accessManager)
        );
        _authorizeIAGovernance(address(newIA));

        // Now try to set IAFactory - should revert because otherFactory.getImplementationAuthority() != address(newIA)
        IAFactory iaFactory = new IAFactory(address(otherFactory));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyReferenceContractCanCall.selector);
        newIA.setIAFactory(address(iaFactory));
    }

    // ============ fetchVersion() Tests ============

    /// @notice Should revert when called on the reference contract
    function test_fetchVersion_RevertWhen_OnReferenceContract() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.CannotCallOnReferenceContract.selector);
        trexImplementationAuthority.fetchVersion(version);
    }

    /// @notice Should revert when version was already fetched
    /// @dev The auxiliary IA already pins the reference's current version (5.0.0) at construction,
    ///      so fetching that same version again reverts.
    function test_fetchVersion_RevertWhen_AlreadyFetched() public {
        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(accessManager));

        // Deploy non-reference IA (auto-fetches and uses version 5.0.0 at construction)
        TREXImplementationAuthority otherIA = new TREXImplementationAuthority(
            false, address(factory), address(trexImplementationAuthority), address(accessManager)
        );

        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        vm.expectRevert(ErrorsLib.VersionAlreadyFetched.selector);
        otherIA.fetchVersion(version);
    }

    /// @notice Should fetch a non-current version from the reference contract
    function test_fetchVersion_Success() public {
        // Add a second, non-current version on the reference contract
        ITREXImplementationAuthority.Version memory extraVersion =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 1 });
        vm.prank(deployer);
        trexImplementationAuthority.addTREXVersion(extraVersion, getTREXContracts());

        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(accessManager));

        // Deploy non-reference IA (auto-fetches current 5.0.0 at construction)
        TREXImplementationAuthority otherIA = new TREXImplementationAuthority(
            false, address(factory), address(trexImplementationAuthority), address(accessManager)
        );

        // Explicitly fetch the extra version (fetchVersion has no access control)
        otherIA.fetchVersion(extraVersion);

        // Verify version was fetched by checking it exists
        ITREXImplementationAuthority.TREXContracts memory fetchedContracts = otherIA.getContracts(extraVersion);
        assertNotEq(fetchedContracts.tokenImplementation, address(0), "Version should be fetched");
    }

    // ============ addTREXVersion() Tests ============

    /// @notice Should revert when called not as owner
    function test_addTREXVersion_RevertWhen_NotOwner() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 1 });
        ITREXImplementationAuthority.TREXContracts memory contracts = getTREXContracts();

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trexImplementationAuthority.addTREXVersion(version, contracts);
    }

    /// @notice Should revert when called on a non-reference contract
    function test_addTREXVersion_RevertWhen_NonReferenceContract() public {
        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(accessManager));

        // Deploy non-reference IA and wire its governance so the restricted check passes
        TREXImplementationAuthority otherIA = new TREXImplementationAuthority(
            false, address(factory), address(trexImplementationAuthority), address(accessManager)
        );
        _authorizeIAGovernance(address(otherIA));

        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 0 });
        ITREXImplementationAuthority.TREXContracts memory contracts = getTREXContracts();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyReferenceContractCanCall.selector);
        otherIA.addTREXVersion(version, contracts);
    }

    /// @notice Should revert when version was already added
    function test_addTREXVersion_RevertWhen_AlreadyExists() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });
        ITREXImplementationAuthority.TREXContracts memory contracts = getTREXContracts();

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.VersionAlreadyExists.selector);
        trexImplementationAuthority.addTREXVersion(version, contracts);
    }

    /// @notice Should revert when a contract implementation address is zero address
    function test_addTREXVersion_RevertWhen_ZeroAddress() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 1 });
        ITREXImplementationAuthority.TREXContracts memory contracts = getTREXContracts();
        contracts.irsImplementation = address(0); // Set one to zero

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trexImplementationAuthority.addTREXVersion(version, contracts);
    }

    // ============ useTREXVersion() Tests ============

    /// @notice Should revert when called not as owner
    function test_useTREXVersion_RevertWhen_NotOwner() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 0 });

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trexImplementationAuthority.useTREXVersion(version);
    }

    /// @notice Should revert when version is already in use
    function test_useTREXVersion_RevertWhen_AlreadyInUse() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.VersionAlreadyInUse.selector);
        trexImplementationAuthority.useTREXVersion(version);
    }

    /// @notice Should revert when version does not exist
    function test_useTREXVersion_RevertWhen_NonExistingVersion() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 1 });

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.NonExistingVersion.selector);
        trexImplementationAuthority.useTREXVersion(version);
    }

    // ============ changeImplementationAuthority() Tests ============

    /// @notice Should revert when token to update is zero address
    function test_changeImplementationAuthority_RevertWhen_TokenZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trexImplementationAuthority.changeImplementationAuthority(address(0), address(0));
    }

    /// @notice Should revert when new authority is zero address on non-reference contract
    function test_changeImplementationAuthority_RevertWhen_ZeroAddressOnNonReference() public {
        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(accessManager));

        // Deploy non-reference IA and wire its changeImplementationAuthority to the OWNER role
        TREXImplementationAuthority otherIA = new TREXImplementationAuthority(
            false, address(factory), address(trexImplementationAuthority), address(accessManager)
        );
        _authorizeIAGovernance(address(otherIA));

        // deployer holds OWNER; the call must reach and fail at OnlyReferenceContractCanCall
        // (non-reference IAs may not deploy a new auxiliary IA via the zero-address path)
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyReferenceContractCanCall.selector);
        otherIA.changeImplementationAuthority(address(token), address(0));
    }

    /// @notice Should revert when caller does not hold the required AccessManager role
    function test_changeImplementationAuthority_RevertWhen_Unauthorized() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trexImplementationAuthority.changeImplementationAuthority(address(token), address(0));
    }

    /// @notice Should deploy a new authority contract when caller is owner
    function test_changeImplementationAuthority_Success_DeployNewIA() public {
        IAFactory iaFactory = new IAFactory(address(trexFactory));
        vm.prank(deployer);
        trexImplementationAuthority.setIAFactory(address(iaFactory));

        ModularCompliance newCompliance = _newUnboundComplianceProxy(address(trexImplementationAuthority));
        vm.prank(deployer);
        token.setCompliance(address(newCompliance));

        vm.expectEmit(true, false, false, false);
        emit EventsLib.ImplementationAuthorityChanged(address(token), address(0));
        vm.prank(deployer);
        trexImplementationAuthority.changeImplementationAuthority(address(token), address(0));
    }

    /// @notice Should revert when version of new IA is not the same as current
    function test_changeImplementationAuthority_RevertWhen_VersionMismatch() public {
        // Setup TREXFactory and IAFactory
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        vm.prank(deployer);
        trexImplementationAuthority.setIAFactory(address(iaFactory));

        // Replace compliance with a new one
        ModularCompliance compliance = _newUnboundComplianceProxy(address(trexImplementationAuthority));
        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Deploy another reference IA with different version
        TREXImplementationAuthority otherIA =
            new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));
        _authorizeIAGovernance(address(otherIA));

        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 1 });
        ITREXImplementationAuthority.TREXContracts memory contracts = ITREXImplementationAuthority.TREXContracts({
            tokenImplementation: address(tokenImplementation),
            ctrImplementation: address(claimTopicsRegistryImplementation),
            irImplementation: address(identityRegistryImplementation),
            irsImplementation: address(identityRegistryStorageImplementation),
            tirImplementation: address(trustedIssuersRegistryImplementation),
            mcImplementation: address(modularComplianceImplementation)
        });
        vm.prank(deployer);
        otherIA.addAndUseTREXVersion(version, contracts);

        vm.expectRevert(ErrorsLib.VersionOfNewIAMustBeTheSameAsCurrentIA.selector);
        vm.prank(deployer);
        trexImplementationAuthority.changeImplementationAuthority(address(token), address(otherIA));
    }

    /// @notice Should revert when new IA is a reference contract but not current one
    function test_changeImplementationAuthority_RevertWhen_NewIAIsReferenceButNotCurrent() public {
        // Setup TREXFactory and IAFactory
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        vm.prank(deployer);
        trexImplementationAuthority.setIAFactory(address(iaFactory));

        // Replace compliance with a new one
        ModularCompliance compliance = _newUnboundComplianceProxy(address(trexImplementationAuthority));
        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Deploy another reference IA - it already has version 4.0.0 set up from deploy()
        TREXImplementationAuthority otherIA = _deployTREXImplementationAuthority(true);

        // Note: otherIASetup already has version 4.0.0 added and in use from deploy(),
        // so we don't need to call addAndUseTREXVersion again

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.NewIAIsNotAReferenceContract.selector);
        trexImplementationAuthority.changeImplementationAuthority(address(token), address(otherIA));
    }

    /// @notice Should revert when new IA is not valid
    function test_changeImplementationAuthority_RevertWhen_InvalidIA() public {
        // Setup TREXFactory and IAFactory
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        vm.prank(deployer);
        trexImplementationAuthority.setIAFactory(address(iaFactory));

        // Replace compliance with a new one
        ModularCompliance compliance = _newUnboundComplianceProxy(address(trexImplementationAuthority));
        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Deploy non-reference IA that fetched version but not deployed by factory
        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(accessManager));

        // Auxiliary IA pins version 5.0.0 at construction but is not deployed by the IAFactory
        TREXImplementationAuthority otherIA = new TREXImplementationAuthority(
            false, address(factory), address(trexImplementationAuthority), address(accessManager)
        );

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidImplementationAuthority.selector);
        trexImplementationAuthority.changeImplementationAuthority(address(token), address(otherIA));
    }

    /// @notice Should succeed when changing to the reference contract itself
    /// @dev  _newImplementationAuthority == getReferenceContract()
    function test_changeImplementationAuthority_Success_WithReferenceContract() public {
        // Setup TREXFactory and IAFactory
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        vm.prank(deployer);
        trexImplementationAuthority.setIAFactory(address(iaFactory));

        // Replace compliance with a new one
        ModularCompliance compliance = _newUnboundComplianceProxy(address(trexImplementationAuthority));
        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Change to the reference contract itself (getReferenceContract() returns this IA)
        address referenceContract = trexImplementationAuthority.getReferenceContract();
        assertEq(referenceContract, address(trexImplementationAuthority), "Should be the reference contract");

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit EventsLib.ImplementationAuthorityChanged(address(token), referenceContract);
        trexImplementationAuthority.changeImplementationAuthority(address(token), referenceContract);
    }

    // ============ supportsInterface() Tests ============

    /// @notice Should return false for unsupported interfaces
    function test_supportsInterface_ReturnsFalse_ForUnsupported() public view {
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(trexImplementationAuthority.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the ITREXImplementationAuthority interface ID
    function test_supportsInterface_ReturnsTrue_ForITREXImplementationAuthority() public view {
        assertTrue(trexImplementationAuthority.supportsInterface(type(ITREXImplementationAuthority).interfaceId));
    }

    /// @notice IERC173 is part of the public interface via the AccessManagerOwnable ERC-173 ownership shim
    function test_supportsInterface_ReturnsTrue_ForIERC173() public view {
        assertTrue(trexImplementationAuthority.supportsInterface(type(IERC173).interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public view {
        assertTrue(trexImplementationAuthority.supportsInterface(type(IERC165).interfaceId));
    }

    // ============ IAFactory supportsInterface() Tests ============

    /// @notice Should return false for unsupported interfaces (IAFactory)
    function test_IAFactory_supportsInterface_ReturnsFalse_ForUnsupported() public {
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(iaFactory.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the IIAFactory interface ID
    function test_IAFactory_supportsInterface_ReturnsTrue_ForIIAFactory() public {
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        assertTrue(iaFactory.supportsInterface(type(IIAFactory).interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID (IAFactory)
    function test_IAFactory_supportsInterface_ReturnsTrue_ForIERC165() public {
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        assertTrue(iaFactory.supportsInterface(type(IERC165).interfaceId));
    }

    // ============ IAFactory deployIA() Tests ============

    /// @notice Should revert when deployIA is called from non-reference IA
    /// @dev just the reference implementation authority can call the iaFactory to deploy new implementation authority for a specific token
    function test_deployIA_RevertWhen_NotFromReferenceIA() public {
        // Setup TREXFactory and IAFactory
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));

        // Use a simple address that is not the reference IA
        // The check at line 90 should fail: trexFactory.getImplementationAuthority() != msg.sender
        address nonReferenceIA = makeAddr("nonReferenceIA");

        // Try to call deployIA from a non-reference address
        // This should revert at line 90 because msg.sender != trexFactory.getImplementationAuthority()
        vm.prank(nonReferenceIA);
        vm.expectRevert(IAFactory.OnlyReferenceIACanDeploy.selector);
        iaFactory.deployIA(address(token));
    }

    // ============ Cross-AccessManager isolation Tests ============

    /// @notice A reference IA governed by a second, independent AccessManager is isolated: an OWNER
    ///         holder of the suite's manager cannot drive it; only an OWNER holder of that second
    ///         manager can.
    function test_governance_IsolatedAcrossAccessManagers() public {
        address otherAdmin = makeAddr("otherAdmin");
        address otherOwner = makeAddr("otherOwner");
        AccessManager otherAccessManager = new AccessManager(otherAdmin);

        // Reference IA governed by the second, independent AccessManager
        TREXImplementationAuthority otherIA =
            new TREXImplementationAuthority(true, address(0), address(0), address(otherAccessManager));

        assertEq(IAccessManaged(address(otherIA)).authority(), address(otherAccessManager));
        assertTrue(
            IAccessManaged(address(otherIA)).authority() != address(accessManager),
            "IA must not be governed by the suite manager"
        );

        // Wire the IA governance selectors to OWNER on the second manager and grant OWNER to otherOwner
        vm.startPrank(otherAdmin);
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(otherAccessManager, address(otherIA));
        otherAccessManager.grantRole(RolesLib.OWNER, otherOwner, NO_DELAY);
        vm.stopPrank();

        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });
        ITREXImplementationAuthority.TREXContracts memory contracts = getTREXContracts();

        // The suite OWNER (deployer holds OWNER on `accessManager`) cannot govern an IA under another manager
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, deployer));
        otherIA.addAndUseTREXVersion(version, contracts);

        // The second manager's OWNER can
        vm.prank(otherOwner);
        otherIA.addAndUseTREXVersion(version, contracts);

        assertEq(otherIA.getTokenImplementation(), address(tokenImplementation), "Version should be set");
    }

    /// @notice An auxiliary IA deployed through the IAFactory inherits the token's AccessManager,
    ///         not necessarily the reference IA's manager.
    function test_changeImplementationAuthority_AuxiliaryIAInheritsTokenAccessManager() public {
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        vm.prank(deployer);
        trexImplementationAuthority.setIAFactory(address(iaFactory));

        ModularCompliance compliance = _newUnboundComplianceProxy(address(trexImplementationAuthority));
        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Deploy a fresh auxiliary IA for the token (newImplementationAuthority == address(0))
        vm.prank(deployer);
        trexImplementationAuthority.changeImplementationAuthority(address(token), address(0));

        address auxIA = IProxy(address(token)).getImplementationAuthority();
        assertTrue(auxIA != address(trexImplementationAuthority), "Token should use a new auxiliary IA");
        assertEq(
            IAccessManaged(auxIA).authority(),
            IAccessManaged(address(token)).authority(),
            "Auxiliary IA must inherit the token's AccessManager"
        );
        assertEq(IAccessManaged(auxIA).authority(), address(accessManager), "Token is governed by the suite manager");
    }

}
