// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { IERC3643ClaimTopicsRegistry } from "contracts/ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "contracts/ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ITREXMessaging } from "contracts/interop/ITREXMessaging.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";
import { IToken } from "contracts/token/IToken.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { Utils } from "test/unit/helpers/Utils.sol";

/// @notice The manager's own surface: domains, the suite layout it writes, and who may write it. The layout
///         is asserted row by row so this file is the readable spec of which role opens which function.
contract TREXAccessManagerUnitTest is Test {

    uint64 internal constant ADMIN_ROLE = 0;

    TREXAccessManager internal manager;
    address internal outsider = makeAddr("outsider");
    address internal issuerAdmin = makeAddr("issuerAdmin");
    address internal token = makeAddr("token");
    address internal registry = makeAddr("registry");
    address internal identityStorage = makeAddr("identityStorage");
    address internal compliance = makeAddr("compliance");

    function setUp() public {
        // The placeholders have no code, so the suite `setupSuite` reads from `token` is mocked.
        _mockSuite(token, registry, identityStorage, compliance);
        manager = TREXAccessManager(
            address(
                new ERC1967Proxy(
                    address(new TREXAccessManager()),
                    abi.encodeCall(AccessManagerUpgradeable.initialize, (address(this)))
                )
            )
        );
    }

    // ============================================================
    // initializeSuite: the factory path
    // ============================================================

    /// @notice One call in the proxy constructor gives an operable suite with the issuer as the only admin.
    function test_initializeSuite_LaysTheSuiteOutWithTheIssuerAsOnlyAdmin() public {
        TREXAccessManager fresh = TREXAccessManager(
            address(
                new ERC1967Proxy(
                    address(new TREXAccessManager()),
                    abi.encodeCall(
                        TREXAccessManager.initializeSuite,
                        (issuerAdmin, "Acme Bonds", token, registry, identityStorage, compliance)
                    )
                )
            )
        );

        (bool issuerIsAdmin,) = fresh.hasRole(ADMIN_ROLE, issuerAdmin);
        (bool deployerIsAdmin,) = fresh.hasRole(ADMIN_ROLE, address(this));
        assertTrue(issuerIsAdmin, "the issuer admin holds ADMIN_ROLE");
        assertFalse(deployerIsAdmin, "the deployer holds nothing");
        assertEq(fresh.domainCount(), 1);
        assertEq(fresh.domainName(1), "Acme Bonds");
        assertEq(fresh.domainOf(token), 1);
        assertEq(fresh.domainOf(registry), 1);
        assertEq(fresh.domainOf(identityStorage), 1);
        assertEq(fresh.domainOf(compliance), 1);
        _assertSuiteLayout(fresh, 1, 1);
    }

    function test_initializeSuite_RevertWhen_CalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        manager.initializeSuite(issuerAdmin, "again", token, registry, identityStorage, compliance);
    }

    function test_initializeSuite_RevertWhen_AdminIsZero() public {
        address implementation = address(new TREXAccessManager());
        bytes memory initData = abi.encodeCall(
            TREXAccessManager.initializeSuite, (address(0), "Acme Bonds", token, registry, identityStorage, compliance)
        );
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerInvalidInitialAdmin.selector, address(0)));
        new ERC1967Proxy(implementation, initData);
    }

    // ============================================================
    // createDomain and setupSuite: the issuer path
    // ============================================================

    function test_createDomain_NumbersFromOneAndStoresTheName() public {
        vm.expectEmit(true, false, false, true, address(manager));
        emit EventsLib.DomainCreated(1, "Fund A");
        uint32 first = manager.createDomain("Fund A");
        uint32 second = manager.createDomain("Fund B");

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(manager.domainCount(), 2);
        assertEq(manager.domainName(1), "Fund A");
        assertEq(manager.domainName(2), "Fund B");
    }

    function test_setupSuite_AssignsTheFourContractsAndWritesTheLayout() public {
        uint32 fund = manager.createDomain("Fund A");

        vm.expectEmit(true, true, false, true, address(manager));
        emit EventsLib.DomainAssigned(fund, token);
        manager.setupSuite(fund, token);

        assertEq(manager.domainOf(token), fund);
        assertEq(manager.domainOf(registry), fund);
        assertEq(manager.domainOf(identityStorage), fund);
        assertEq(manager.domainOf(compliance), fund);
        _assertSuiteLayout(manager, fund, fund);
    }

    /// @notice The storage keeps the domain it was first set up in, so a second fund sharing it writes
    ///         through the first fund's `IRS_WRITER`, and its role admins are set for both domains.
    function test_setupSuite_SharedStorageKeepsItsFirstDomain() public {
        uint32 fundA = manager.createDomain("Fund A");
        uint32 fundB = manager.createDomain("Fund B");
        address otherToken = makeAddr("otherToken");
        address otherRegistry = makeAddr("otherRegistry");
        address otherCompliance = makeAddr("otherCompliance");
        manager.setupSuite(fundA, token);

        _mockSuite(otherToken, otherRegistry, identityStorage, otherCompliance);
        manager.setupSuite(fundB, otherToken);

        assertEq(manager.domainOf(identityStorage), fundA, "storage stays in the first domain");
        assertEq(manager.domainOf(otherToken), fundB);
        assertEq(manager.domainOf(otherRegistry), fundB);
        assertEq(manager.domainOf(otherCompliance), fundB);
        _assertRow(manager, otherToken, IERC3643.mint.selector, fundB, RolesLib.Role.AGENT_MINTER);
        _assertRow(
            manager, otherRegistry, IERC3643IdentityRegistry.registerIdentity.selector, fundB, RolesLib.Role.AGENT
        );
        _assertRow(manager, otherCompliance, IModularCompliance.addModule.selector, fundB, RolesLib.Role.OWNER);
        _assertRow(
            manager,
            identityStorage,
            IERC3643IdentityRegistryStorage.addIdentityToStorage.selector,
            fundA,
            RolesLib.Role.IRS_WRITER
        );
        (bool otherTokenIsAgent,) = manager.hasRole(RolesLib.forDomain(fundB, RolesLib.Role.AGENT), otherToken);
        (bool otherRegistryWrites,) =
            manager.hasRole(RolesLib.forDomain(fundA, RolesLib.Role.IRS_WRITER), otherRegistry);
        assertTrue(otherTokenIsAgent, "the second token acts as an agent of its own domain");
        assertTrue(otherRegistryWrites, "the second registry writes through the first domain");
        _assertAdmin(manager, fundB, RolesLib.Role.AGENT, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(manager, fundA, RolesLib.Role.IRS_BINDER, RolesLib.Role.AGENT_ADMIN);
    }

    function test_setupSuite_RevertWhen_DomainDoesNotExist() public {
        manager.createDomain("Fund A");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DomainNotFound.selector, 2));
        manager.setupSuite(2, token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DomainNotFound.selector, 0));
        manager.setupSuite(0, token);
    }

    /// @notice A second run would reset every row the admin changed since to the default.
    function test_setupSuite_RevertWhen_TheTokenIsAlreadySetUp() public {
        uint32 fund = manager.createDomain("Fund A");
        manager.setupSuite(fund, token);
        uint64 treasuryRole = RolesLib.forDomain(fund, bytes32("TREASURY"));
        bytes4[] memory forcedTransfer = new bytes4[](1);
        forcedTransfer[0] = IERC3643.forcedTransfer.selector;
        manager.setTargetFunctionRole(token, forcedTransfer, treasuryRole);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, token, fund));
        manager.setupSuite(fund, token);

        assertEq(
            manager.getTargetFunctionRole(token, IERC3643.forcedTransfer.selector),
            treasuryRole,
            "the admin's own mapping is kept"
        );
    }

    /// @notice A run into another domain would move the token, registry and compliance and leave the storage
    ///         and the token's old `AGENT` grant behind.
    function test_setupSuite_RevertWhen_TheTokenIsSetUpInAnotherDomain() public {
        uint32 fundA = manager.createDomain("Fund A");
        uint32 fundB = manager.createDomain("Fund B");
        manager.setupSuite(fundA, token);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, token, fundA));
        manager.setupSuite(fundB, token);

        assertEq(manager.domainOf(token), fundA, "the token stays in its domain");
        assertEq(manager.domainOf(registry), fundA, "the registry stays in its domain");
    }

    /// @notice The factory path sets the suite up at initialization, so the issuer cannot run it a second time.
    function test_setupSuite_RevertWhen_TheSuiteWasSetUpAtInitialization() public {
        TREXAccessManager fresh = TREXAccessManager(
            address(
                new ERC1967Proxy(
                    address(new TREXAccessManager()),
                    abi.encodeCall(
                        TREXAccessManager.initializeSuite,
                        (issuerAdmin, "Acme Bonds", token, registry, identityStorage, compliance)
                    )
                )
            )
        );

        vm.prank(issuerAdmin);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SuiteAlreadySetUp.selector, token, 1));
        fresh.setupSuite(1, token);
    }

    function test_setupSuite_RevertWhen_TokenIsZero() public {
        uint32 fund = manager.createDomain("Fund A");

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        manager.setupSuite(fund, address(0));
    }

    /// @notice A token that reports no compliance is not a complete suite, so nothing is set up for it.
    function test_setupSuite_RevertWhen_TheTokenReportsAZeroSibling() public {
        uint32 fund = manager.createDomain("Fund A");
        address brokenToken = makeAddr("brokenToken");
        _mockSuite(brokenToken, registry, identityStorage, address(0));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        manager.setupSuite(fund, brokenToken);
    }

    /// @notice The registry, storage and compliance come from the token, never from the caller, so the four
    ///         addresses set up together always belong to one suite.
    function test_setupSuite_ReadsTheSuiteFromTheToken() public {
        uint32 fund = manager.createDomain("Fund A");

        vm.expectCall(token, abi.encodeCall(IERC3643.identityRegistry, ()));
        vm.expectCall(token, abi.encodeCall(IERC3643.compliance, ()));
        vm.expectCall(registry, abi.encodeCall(IERC3643IdentityRegistry.identityStorage, ()));
        manager.setupSuite(fund, token);

        assertEq(manager.domainOf(registry), fund);
        assertEq(manager.domainOf(identityStorage), fund);
        assertEq(manager.domainOf(compliance), fund);
    }

    // ============================================================
    // Who may write: OpenZeppelin's onlyAuthorized, admin-only by default
    // ============================================================

    function test_createDomainAndSetupSuite_RevertWhen_CallerIsNotAdmin() public {
        uint32 first = manager.createDomain("Fund A");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, outsider, ADMIN_ROLE)
        );
        manager.createDomain("Fund B");
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, outsider, ADMIN_ROLE)
        );
        manager.setupSuite(first, token);
    }

    function test_createDomainAndSetupSuite_RevertWhen_ADelayedAdminCallsDirectly() public {
        address delayedAdmin = makeAddr("delayedAdmin");
        manager.grantRole(ADMIN_ROLE, delayedAdmin, 1 days);
        uint32 first = manager.createDomain("Fund A");
        // Computed before `expectRevert`: the cheatcode binds to the next external call.
        bytes32 createOperationId = _createDomainOperationId(delayedAdmin, "Fund B");
        bytes32 setupOperationId = _setupSuiteOperationId(delayedAdmin, first);

        vm.prank(delayedAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, createOperationId));
        manager.createDomain("Fund B");
        vm.prank(delayedAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, setupOperationId));
        manager.setupSuite(first, token);
    }

    function test_createDomainAndSetupSuite_Success_WhenADelayedAdminSchedulesAndExecutes() public {
        address delayedAdmin = makeAddr("delayedAdmin");
        manager.grantRole(ADMIN_ROLE, delayedAdmin, 1 days);
        bytes memory createCall = abi.encodeCall(TREXAccessManager.createDomain, ("Fund A"));
        bytes memory setupCall = abi.encodeCall(TREXAccessManager.setupSuite, (1, token));

        vm.startPrank(delayedAdmin);
        manager.schedule(address(manager), createCall, uint48(block.timestamp + 1 days));
        manager.schedule(address(manager), setupCall, uint48(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        manager.execute(address(manager), createCall);
        manager.execute(address(manager), setupCall);
        vm.stopPrank();

        assertEq(manager.domainCount(), 1);
        assertEq(manager.domainOf(token), 1);
    }

    function test_createDomainAndSetupSuite_AreAdminOnlyByDefaultAndVisible() public view {
        assertEq(manager.getTargetFunctionRole(address(manager), TREXAccessManager.createDomain.selector), ADMIN_ROLE);
        assertEq(manager.getTargetFunctionRole(address(manager), TREXAccessManager.setupSuite.selector), ADMIN_ROLE);
    }

    function test_domainOf_IsZeroForUnassignedTargets() public view {
        assertEq(manager.domainOf(token), 0);
    }

    // ============================================================
    // Storage
    // ============================================================

    function test_storageLocation_MatchesTheERC7201Location() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.TREXAccessManager"),
            0x9ee5333472569314e77d439560942818930bfd1bd85e664704fdf0ed68f91e00
        );
    }

    function test_storageLayout_CountSitsAtOffsetZero() public {
        manager.createDomain("Fund A");
        manager.createDomain("Fund B");
        bytes32 slot = 0x9ee5333472569314e77d439560942818930bfd1bd85e664704fdf0ed68f91e00;
        assertEq(uint32(uint256(vm.load(address(manager), slot))), 2);
    }

    // ============================================================
    // The layout, row by row
    // ============================================================

    /// @dev Every row the manager writes for a suite in `domainId` whose storage sits in `storageDomainId`.
    function _assertSuiteLayout(TREXAccessManager target, uint32 domainId, uint32 storageDomainId) private view {
        // Token
        _assertRow(target, token, IERC3643.setName.selector, domainId, RolesLib.Role.TOKEN_MANAGER);
        _assertRow(target, token, IERC3643.setSymbol.selector, domainId, RolesLib.Role.TOKEN_MANAGER);
        _assertRow(target, token, IERC3643.setOnchainID.selector, domainId, RolesLib.Role.IDENTITY_MANAGER);
        _assertRow(target, token, IERC3643.setIdentityRegistry.selector, domainId, RolesLib.Role.IDENTITY_MANAGER);
        _assertRow(target, token, IERC3643.setCompliance.selector, domainId, RolesLib.Role.IDENTITY_MANAGER);
        _assertRow(target, token, ITREXMessaging.setRoute.selector, domainId, RolesLib.Role.IDENTITY_MANAGER);
        _assertRow(target, token, ITREXMessaging.setPeer.selector, domainId, RolesLib.Role.IDENTITY_MANAGER);
        _assertRow(target, token, IToken.dispatchMintInstruction.selector, domainId, RolesLib.Role.AGENT);
        _assertRow(target, token, IToken.dispatchRecallInstruction.selector, domainId, RolesLib.Role.AGENT);
        _assertRow(target, token, IERC3643.mint.selector, domainId, RolesLib.Role.AGENT_MINTER);
        _assertRow(target, token, IERC3643.burn.selector, domainId, RolesLib.Role.AGENT_BURNER);
        _assertRow(target, token, IERC3643.freezePartialTokens.selector, domainId, RolesLib.Role.AGENT_PARTIAL_FREEZER);
        _assertRow(
            target, token, IERC3643.unfreezePartialTokens.selector, domainId, RolesLib.Role.AGENT_PARTIAL_FREEZER
        );
        _assertRow(target, token, IERC3643.setAddressFrozen.selector, domainId, RolesLib.Role.AGENT_ADDRESS_FREEZER);
        _assertRow(target, token, IERC3643.recoveryAddress.selector, domainId, RolesLib.Role.AGENT_RECOVERY_ADDRESS);
        _assertRow(target, token, IERC3643.forcedTransfer.selector, domainId, RolesLib.Role.AGENT_FORCED_TRANSFER);
        _assertRow(target, token, IERC3643.pause.selector, domainId, RolesLib.Role.AGENT_PAUSER);
        _assertRow(target, token, IERC3643.unpause.selector, domainId, RolesLib.Role.AGENT_PAUSER);
        // Registry
        _assertRow(
            target,
            registry,
            IERC3643IdentityRegistry.setIdentityRegistryStorage.selector,
            domainId,
            RolesLib.Role.OWNER
        );
        _assertRow(target, registry, ITREXRegistry.disableEligibilityChecks.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(target, registry, ITREXRegistry.enableEligibilityChecks.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(
            target, registry, IERC3643TrustedIssuersRegistry.addTrustedIssuer.selector, domainId, RolesLib.Role.OWNER
        );
        _assertRow(
            target, registry, IERC3643TrustedIssuersRegistry.removeTrustedIssuer.selector, domainId, RolesLib.Role.OWNER
        );
        _assertRow(
            target,
            registry,
            IERC3643TrustedIssuersRegistry.updateIssuerClaimTopics.selector,
            domainId,
            RolesLib.Role.OWNER
        );
        _assertRow(target, registry, IERC3643ClaimTopicsRegistry.addClaimTopic.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(
            target, registry, IERC3643ClaimTopicsRegistry.removeClaimTopic.selector, domainId, RolesLib.Role.OWNER
        );
        _assertRow(target, registry, ITREXRegistry.addClaimTopicForIdentityType.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(
            target, registry, ITREXRegistry.removeClaimTopicForIdentityType.selector, domainId, RolesLib.Role.OWNER
        );
        _assertRow(target, registry, IERC3643IdentityRegistry.registerIdentity.selector, domainId, RolesLib.Role.AGENT);
        _assertRow(
            target, registry, IERC3643IdentityRegistry.batchRegisterIdentity.selector, domainId, RolesLib.Role.AGENT
        );
        _assertRow(target, registry, IERC3643IdentityRegistry.updateIdentity.selector, domainId, RolesLib.Role.AGENT);
        _assertRow(target, registry, IERC3643IdentityRegistry.deleteIdentity.selector, domainId, RolesLib.Role.AGENT);
        // Identity storage, in its own domain
        _assertRow(
            target,
            identityStorage,
            IERC3643IdentityRegistryStorage.bindIdentityRegistry.selector,
            storageDomainId,
            RolesLib.Role.IRS_BINDER
        );
        _assertRow(
            target,
            identityStorage,
            IERC3643IdentityRegistryStorage.unbindIdentityRegistry.selector,
            storageDomainId,
            RolesLib.Role.OWNER
        );
        _assertRow(
            target,
            identityStorage,
            IERC3643IdentityRegistryStorage.addIdentityToStorage.selector,
            storageDomainId,
            RolesLib.Role.IRS_WRITER
        );
        _assertRow(
            target,
            identityStorage,
            IERC3643IdentityRegistryStorage.modifyStoredIdentity.selector,
            storageDomainId,
            RolesLib.Role.IRS_WRITER
        );
        _assertRow(
            target,
            identityStorage,
            IERC3643IdentityRegistryStorage.removeIdentityFromStorage.selector,
            storageDomainId,
            RolesLib.Role.IRS_WRITER
        );
        // Compliance
        _assertRow(target, compliance, IModularCompliance.addModule.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(target, compliance, IModularCompliance.addAndSetModule.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(target, compliance, IModularCompliance.removeModule.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(target, compliance, IModularCompliance.forceRemoveModule.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(target, compliance, IModularCompliance.callModuleFunction.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(target, compliance, IModularCompliance.resyncModuleTypes.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(target, compliance, IComplianceLedger.fixPosition.selector, domainId, RolesLib.Role.OWNER);
        _assertRow(target, compliance, RolesLib.BIND_UNBIND_TOKEN, domainId, RolesLib.Role.OWNER);
        _assertRow(
            target,
            compliance,
            ITransferValidation.setDefaultValidityWindow.selector,
            domainId,
            RolesLib.Role.COMPLIANCE_MANAGER
        );
        _assertRow(
            target,
            compliance,
            ITransferValidation.setReconciliationWindow.selector,
            domainId,
            RolesLib.Role.COMPLIANCE_MANAGER
        );
        _assertRow(
            target,
            compliance,
            ITransferValidation.setIssuancePaused.selector,
            domainId,
            RolesLib.Role.COMPLIANCE_MANAGER
        );
        _assertRow(
            target, compliance, ITransferValidation.requestTransferValidation.selector, domainId, RolesLib.Role.AGENT
        );
        _assertRow(
            target,
            compliance,
            ITransferValidation.discardExpiredValidations.selector,
            domainId,
            RolesLib.Role.VALIDATION_KEEPER
        );
        _assertRow(
            target,
            compliance,
            ITransferValidation.resolveStuckValidation.selector,
            domainId,
            RolesLib.Role.VALIDATION_KEEPER
        );
        // Who hands out which role
        _assertAdmin(target, domainId, RolesLib.Role.AGENT, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.AGENT_MINTER, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.AGENT_BURNER, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.AGENT_PARTIAL_FREEZER, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.AGENT_ADDRESS_FREEZER, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.AGENT_RECOVERY_ADDRESS, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.AGENT_FORCED_TRANSFER, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.AGENT_PAUSER, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.IRS_BINDER, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.VALIDATION_KEEPER, RolesLib.Role.AGENT_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.TOKEN_MANAGER, RolesLib.Role.SUITE_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.IDENTITY_MANAGER, RolesLib.Role.SUITE_ADMIN);
        _assertAdmin(target, domainId, RolesLib.Role.COMPLIANCE_MANAGER, RolesLib.Role.SUITE_ADMIN);
        assertEq(target.getRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.OWNER)), ADMIN_ROLE);
        assertEq(target.getRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.SUITE_ADMIN)), ADMIN_ROLE);
        assertEq(target.getRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN)), ADMIN_ROLE);
        assertEq(target.getRoleAdmin(RolesLib.forDomain(storageDomainId, RolesLib.Role.IRS_WRITER)), ADMIN_ROLE);
        // The suite's own contracts
        (bool tokenIsAgent,) = target.hasRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT), token);
        (bool registryWrites,) = target.hasRole(RolesLib.forDomain(storageDomainId, RolesLib.Role.IRS_WRITER), registry);
        assertTrue(tokenIsAgent, "the token acts as an agent of its registry");
        assertTrue(registryWrites, "the registry writes into the storage");
    }

    function _assertRow(
        TREXAccessManager target,
        address contractAddress,
        bytes4 selector,
        uint32 domainId,
        RolesLib.Role role
    ) private view {
        assertEq(target.getTargetFunctionRole(contractAddress, selector), RolesLib.forDomain(domainId, role));
    }

    function _assertAdmin(TREXAccessManager target, uint32 domainId, RolesLib.Role role, RolesLib.Role admin)
        private
        view
    {
        assertEq(target.getRoleAdmin(RolesLib.forDomain(domainId, role)), RolesLib.forDomain(domainId, admin));
    }

    /// @dev Makes the code-less `suiteToken` answer like a deployed token whose suite is the three other
    ///      addresses. `setupSuite` reads exactly these three getters.
    function _mockSuite(address suiteToken, address suiteRegistry, address suiteStorage, address suiteCompliance)
        private
    {
        vm.mockCall(suiteToken, abi.encodeCall(IERC3643.identityRegistry, ()), abi.encode(suiteRegistry));
        vm.mockCall(suiteToken, abi.encodeCall(IERC3643.compliance, ()), abi.encode(suiteCompliance));
        vm.mockCall(
            suiteRegistry, abi.encodeCall(IERC3643IdentityRegistry.identityStorage, ()), abi.encode(suiteStorage)
        );
    }

    function _createDomainOperationId(address caller, string memory name) private view returns (bytes32) {
        return manager.hashOperation(caller, address(manager), abi.encodeCall(TREXAccessManager.createDomain, (name)));
    }

    function _setupSuiteOperationId(address caller, uint32 domainId) private view returns (bytes32) {
        return manager.hashOperation(
            caller, address(manager), abi.encodeCall(TREXAccessManager.setupSuite, (domainId, token))
        );
    }

}
