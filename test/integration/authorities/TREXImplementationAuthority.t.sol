// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { TREXFactory } from "contracts/factory/TREXFactory.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { ModularCompliance, ModularComplianceProxy } from "contracts/proxy/ModularComplianceProxy.sol";
import { IAFactory } from "contracts/proxy/authority/IAFactory.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { InterfaceIdCalculator } from "contracts/utils/InterfaceIdCalculator.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract TREXImplementationAuthorityTest is TREXSuiteTest {

    // ============ setTREXFactory() Tests ============

    /// @notice Should revert when called by not owner
    function test_setTREXFactory_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        trexImplementationAuthority.setTREXFactory(address(0));
    }

    /// @notice Should revert when trex factory to add is not using this authority contract
    function test_setTREXFactory_RevertWhen_FactoryNotUsingThisAuthority() public {
        // Deploy another IA and factory using it
        TREXImplementationAuthority otherIA = _deployTREXImplementationAuthority(true);
        TREXFactory otherFactory = new TREXFactory(address(otherIA), address(idFactory), address(createX));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyReferenceContractCanCall.selector);
        trexImplementationAuthority.setTREXFactory(address(otherFactory));
    }

    /// @notice Should set the trex factory address
    function test_setTREXFactory_Success() public {
        // Deploy a new factory using this IA
        TREXFactory newFactory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(createX));
        Ownable(address(newFactory)).transferOwnership(deployer);

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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
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
        TREXFactory otherFactory = new TREXFactory(address(otherIA), address(idFactory), address(createX));

        // Create a new reference IA with the other factory in constructor
        // This factory references otherIASetup, not this IA
        vm.prank(deployer);
        TREXImplementationAuthority newIA = new TREXImplementationAuthority(
            true, // is reference
            address(otherFactory), // factory that references a different IA
            address(0) // no IAFactory
        );

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
    function test_fetchVersion_RevertWhen_AlreadyFetched() public {
        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(createX));
        Ownable(address(factory)).transferOwnership(deployer);

        // Deploy non-reference IA
        TREXImplementationAuthority otherIA =
            new TREXImplementationAuthority(false, address(factory), address(trexImplementationAuthority));
        Ownable(address(otherIA)).transferOwnership(deployer);

        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        // Fetch version first time
        vm.prank(deployer);
        otherIA.fetchVersion(version);

        // Try to fetch again
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.VersionAlreadyFetched.selector);
        otherIA.fetchVersion(version);
    }

    /// @notice Should fetch and set the versions from the reference contract
    function test_fetchVersion_Success() public {
        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(createX));
        Ownable(address(factory)).transferOwnership(deployer);

        // Deploy non-reference IA
        TREXImplementationAuthority otherIA =
            new TREXImplementationAuthority(false, address(factory), address(trexImplementationAuthority));

        Ownable(address(otherIA)).transferOwnership(deployer);

        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        vm.prank(deployer);
        otherIA.fetchVersion(version);

        // Verify version was fetched by checking it exists
        ITREXImplementationAuthority.TREXContracts memory fetchedContracts = otherIA.getContracts(version);
        assertNotEq(fetchedContracts.tokenImplementation, address(0), "Version should be fetched");
    }

    // ============ addTREXVersion() Tests ============

    /// @notice Should revert when called not as owner
    function test_addTREXVersion_RevertWhen_NotOwner() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 1 });
        ITREXImplementationAuthority.TREXContracts memory contracts = getTREXContracts();

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
        trexImplementationAuthority.addTREXVersion(version, contracts);
    }

    /// @notice Should revert when called on a non-reference contract
    function test_addTREXVersion_RevertWhen_NonReferenceContract() public {
        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(createX));
        Ownable(address(factory)).transferOwnership(deployer);

        // Deploy non-reference IA
        TREXImplementationAuthority otherIA =
            new TREXImplementationAuthority(false, address(factory), address(trexImplementationAuthority));
        Ownable(address(otherIA)).transferOwnership(deployer);

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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, another));
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
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(createX));
        Ownable(address(factory)).transferOwnership(deployer);

        // Deploy non-reference IA
        TREXImplementationAuthority otherIA =
            new TREXImplementationAuthority(false, address(factory), address(trexImplementationAuthority));
        Ownable(address(otherIA)).transferOwnership(deployer);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyReferenceContractCanCall.selector);
        otherIA.changeImplementationAuthority(address(token), address(0));
    }

    /// @notice Should revert when caller is not owner of all impacted contracts
    function test_changeImplementationAuthority_RevertWhen_NotOwnerOfAllContracts() public {
        vm.prank(another);
        vm.expectRevert(ErrorsLib.CallerNotOwnerOfAllImpactedContracts.selector);
        trexImplementationAuthority.changeImplementationAuthority(address(token), address(0));
    }

    /// @notice Should deploy a new authority contract when caller is owner
    function test_changeImplementationAuthority_Success_DeployNewIA() public {
        IAFactory iaFactory = new IAFactory(address(trexFactory));
        vm.prank(deployer);
        trexImplementationAuthority.setIAFactory(address(iaFactory));

        ModularComplianceProxy complianceProxy =
            new ModularComplianceProxy(address(trexImplementationAuthority), address(this));
        ModularCompliance newCompliance = ModularCompliance(address(complianceProxy));
        newCompliance.transferOwnership(deployer);
        vm.prank(deployer);
        newCompliance.acceptOwnership();
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
        ModularComplianceProxy compliance =
            new ModularComplianceProxy(address(trexImplementationAuthority), address(this));
        Ownable(address(compliance)).transferOwnership(deployer);
        vm.prank(deployer);
        ModularCompliance(address(compliance)).acceptOwnership();
        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Deploy another reference IA with different version
        vm.prank(deployer);
        TREXImplementationAuthority otherIA = new TREXImplementationAuthority(true, address(0), address(0));

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
        ModularComplianceProxy compliance =
            new ModularComplianceProxy(address(trexImplementationAuthority), address(this));
        Ownable(address(compliance)).transferOwnership(deployer);
        vm.prank(deployer);
        ModularCompliance(address(compliance)).acceptOwnership();
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
        ModularComplianceProxy compliance =
            new ModularComplianceProxy(address(trexImplementationAuthority), address(this));
        Ownable(address(compliance)).transferOwnership(deployer);
        vm.prank(deployer);
        ModularCompliance(address(compliance)).acceptOwnership();
        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Deploy non-reference IA that fetched version but not deployed by factory
        TREXFactory factory =
            new TREXFactory(address(trexImplementationAuthority), address(idFactory), address(createX));
        Ownable(address(factory)).transferOwnership(deployer);

        TREXImplementationAuthority otherIA =
            new TREXImplementationAuthority(false, address(factory), address(trexImplementationAuthority));
        Ownable(address(otherIA)).transferOwnership(deployer);

        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });
        vm.prank(deployer);
        otherIA.fetchVersion(version);
        vm.prank(deployer);
        otherIA.useTREXVersion(version);

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
        ModularComplianceProxy compliance =
            new ModularComplianceProxy(address(trexImplementationAuthority), address(this));
        Ownable(address(compliance)).transferOwnership(deployer);
        vm.prank(deployer);
        ModularCompliance(address(compliance)).acceptOwnership();
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
    function test_supportsInterface_ReturnsTrue_ForITREXImplementationAuthority() public {
        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getITREXImplementationAuthorityInterfaceId();
        assertTrue(trexImplementationAuthority.supportsInterface(interfaceId));
    }

    /// @notice Should correctly identify the IERC173 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC173() public {
        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getIERC173InterfaceId();
        assertTrue(trexImplementationAuthority.supportsInterface(interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public {
        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getIERC165InterfaceId();
        assertTrue(trexImplementationAuthority.supportsInterface(interfaceId));
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
        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getIIAFactoryInterfaceId();
        assertTrue(iaFactory.supportsInterface(interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID (IAFactory)
    function test_IAFactory_supportsInterface_ReturnsTrue_ForIERC165() public {
        vm.prank(deployer);
        trexImplementationAuthority.setTREXFactory(address(trexFactory));

        IAFactory iaFactory = new IAFactory(address(trexFactory));
        InterfaceIdCalculator calculator = new InterfaceIdCalculator();
        bytes4 interfaceId = calculator.getIERC165InterfaceId();
        assertTrue(iaFactory.supportsInterface(interfaceId));
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

}
