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

pragma solidity 0.8.30;

import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643ClaimTopicsRegistry } from "../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "../ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { IComplianceLedger } from "../compliance/modular/IComplianceLedger.sol";
import { IModularCompliance } from "../compliance/modular/IModularCompliance.sol";
import { ITransferValidation } from "../compliance/modular/ITransferValidation.sol";
import { ITREXMessaging } from "../interop/ITREXMessaging.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { RolesLib } from "../libraries/RolesLib.sol";
import { ITREXRegistry } from "../registry/interface/ITREXRegistry.sol";
import { IToken } from "../token/IToken.sol";

/// @title TREXAccessManager
/// @notice The AccessManager of a T-REX suite. It knows the suite's own role layout: which role opens
///         which function of the token, the registry, the identity storage and the compliance, and
///         which role hands out which. A suite is operable the moment this manager is initialized.
/// @dev Two ways to get a configured manager:
///      - `initializeSuite` is what the {TREXFactory} calls in the proxy constructor. The issuer's admin is
///        the manager's admin from the first block; the factory never holds a role here. The four suite
///        addresses are CREATE3 predictions, so the suite can be wired before it is deployed.
///      - `initialize(admin)` (inherited) plus `createDomain` and `setupSuite` is the path for a manager an
///        issuer runs themselves, including one manager hosting several suites in one or several domains.
///      Role ids are packed per domain through {RolesLib.forDomain}, so two suites in different domains of
///      one manager share no role. Domains live in this contract's own ERC-7201 namespace. No OpenZeppelin
///      internal is overridden; the writers use OpenZeppelin's `onlyAuthorized`, admin-only by default.
contract TREXAccessManager is AccessManagerUpgradeable {

    /// @custom:storage-location erc7201:erc3643.storage.TREXAccessManager
    struct DomainStorage {
        /// @dev Domains created so far; ids are dense, starting at 1.
        uint32 count;
        /// @dev The human name a domain was created with, for tooling.
        mapping(uint32 domainId => string name) names;
        /// @dev The domain a suite contract was set up in; 0 means none.
        mapping(address target => uint32 domainId) domainOf;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXAccessManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DOMAIN_STORAGE_LOCATION =
        0x9ee5333472569314e77d439560942818930bfd1bd85e664704fdf0ed68f91e00;

    /// @dev Grants made to the suite's own contracts carry no execution delay.
    uint32 private constant NO_EXECUTION_DELAY = 0;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a manager for one freshly deployed suite: `admin` is the manager's admin, a domain
    ///         named `suiteName` is created, and the four suite contracts are set up in it.
    /// @dev Meant for the proxy constructor, where the suite addresses are CREATE3 predictions. Nothing is
    ///      read from those addresses, so they need not exist yet.
    /// @param admin The account that administers this manager, the issuer's key, never the factory
    /// @param suiteName The name the suite's domain is created with
    /// @param token The suite's token
    /// @param registry The suite's TREXRegistry
    /// @param identityStorage The suite's IdentityRegistryStorage
    /// @param compliance The suite's ModularCompliance
    function initializeSuite(
        address admin,
        string calldata suiteName,
        address token,
        address registry,
        address identityStorage,
        address compliance
    ) external initializer {
        __AccessManager_init(admin);
        uint32 domainId = _createDomain(suiteName);
        _setupSuite(domainId, token, registry, identityStorage, compliance);
    }

    /// @notice Creates a domain. A domain is an issuer or fund with one team across its suites.
    /// @param name The human name of the domain
    /// @return domainId The new domain's id, dense from 1
    function createDomain(string calldata name) external onlyAuthorized returns (uint32 domainId) {
        return _createDomain(name);
    }

    /// @notice Wires the suite of `token` into `domainId`: maps every privileged function of its four
    ///         contracts to the domain's roles, sets which role administers which, and grants the two roles
    ///         the suite's own contracts hold. Runs once per token.
    /// @dev The registry, the identity storage and the compliance are read from the token, so the four
    ///      addresses always belong to one suite. The token must already be deployed; a suite that does not
    ///      exist yet is set up through `initializeSuite`.
    /// @dev Refused for a token that already has a domain. Running it again would reset every row the admin
    ///      changed since to the default, and running it with another domain would move the token, registry
    ///      and compliance while the storage and the token's old `AGENT` grant stay behind. A function added
    ///      by a later manager version is mapped with `setTargetFunctionRole`.
    /// @dev The identity storage keeps the domain it was first set up in, so a storage shared by
    ///      several domains is written only through roles of the first. Binding a registry to a shared
    ///      storage is not done here: a fresh storage binds its first registry at init, a reused one is
    ///      bound by a holder of `IRS_BINDER`.
    /// @dev A new domain and its first suite take one transaction: the manager inherits OpenZeppelin's
    ///      `multicall`, so the admin sends `createDomain(name)` and `setupSuite(domainCount() + 1, token)`
    ///      together. The id is `domainCount() + 1` because ids are dense and only admins create domains.
    /// @param domainId An existing domain
    /// @param token The suite's token
    function setupSuite(uint32 domainId, address token) external onlyAuthorized {
        require(token != address(0), ErrorsLib.ZeroAddress());
        uint32 currentDomainId = _getDomainStorage().domainOf[token];
        require(currentDomainId == 0, ErrorsLib.SuiteAlreadySetUp(token, currentDomainId));
        IERC3643IdentityRegistry registry = IERC3643(token).identityRegistry();
        _setupSuite(
            domainId,
            token,
            address(registry),
            address(registry.identityStorage()),
            address(IERC3643(token).compliance())
        );
    }

    /// @notice The domain a suite contract was set up in, 0 for none.
    function domainOf(address target) external view returns (uint32) {
        return _getDomainStorage().domainOf[target];
    }

    /// @notice The name a domain was created with.
    function domainName(uint32 domainId) external view returns (string memory) {
        return _getDomainStorage().names[domainId];
    }

    /// @notice How many domains exist; ids run from 1 to this number.
    function domainCount() external view returns (uint32) {
        return _getDomainStorage().count;
    }

    // ============================================================
    // Suite setup
    // ============================================================

    function _createDomain(string memory name) private returns (uint32 domainId) {
        DomainStorage storage domainStorage = _getDomainStorage();
        domainId = ++domainStorage.count;
        domainStorage.names[domainId] = name;
        emit EventsLib.DomainCreated(domainId, name);
    }

    /// @dev Internal rather than private so a test subclass can set up a single suite contract on its own.
    function _setupSuite(uint32 domainId, address token, address registry, address identityStorage, address compliance)
        internal
    {
        DomainStorage storage domainStorage = _getDomainStorage();
        require(domainId != 0 && domainId <= domainStorage.count, ErrorsLib.DomainNotFound(domainId));

        _assignToDomain(domainId, token);
        _assignToDomain(domainId, registry);
        _assignToDomain(domainId, compliance);
        // A storage shared across domains keeps the domain of its first suite; see {setupSuite}.
        uint32 storageDomainId = domainStorage.domainOf[identityStorage];
        if (storageDomainId == 0) {
            _assignToDomain(domainId, identityStorage);
            storageDomainId = domainId;
        }

        _setTokenFunctionRoles(token, domainId);
        _setRegistryFunctionRoles(registry, domainId);
        _setComplianceFunctionRoles(compliance, domainId);
        _setStorageFunctionRoles(identityStorage, storageDomainId);
        _setRoleAdmins(domainId);
        if (storageDomainId != domainId) {
            _setRoleAdmins(storageDomainId);
        }

        // The token registers wallets on recovery and dispatches cross-chain instructions, so it acts as
        // an agent of its registry. Only the registry writes into the storage, never a person.
        _grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT), token, 0, NO_EXECUTION_DELAY);
        _grantRole(RolesLib.forDomain(storageDomainId, RolesLib.Role.IRS_WRITER), registry, 0, NO_EXECUTION_DELAY);
    }

    function _assignToDomain(uint32 domainId, address target) private {
        require(target != address(0), ErrorsLib.ZeroAddress());
        _getDomainStorage().domainOf[target] = domainId;
        emit EventsLib.DomainAssigned(domainId, target);
    }

    // ============================================================
    // The suite's role layout, one row per function
    // ============================================================

    function _setTokenFunctionRoles(address token, uint32 domainId) private {
        // Renaming the token.
        uint64 tokenManagerRole = RolesLib.forDomain(domainId, RolesLib.Role.TOKEN_MANAGER);
        _setTargetFunctionRole(token, IERC3643.setName.selector, tokenManagerRole);
        _setTargetFunctionRole(token, IERC3643.setSymbol.selector, tokenManagerRole);

        // Repointing what the token obeys and where it talks to.
        uint64 identityManagerRole = RolesLib.forDomain(domainId, RolesLib.Role.IDENTITY_MANAGER);
        _setTargetFunctionRole(token, IERC3643.setOnchainID.selector, identityManagerRole);
        _setTargetFunctionRole(token, IERC3643.setIdentityRegistry.selector, identityManagerRole);
        _setTargetFunctionRole(token, IERC3643.setCompliance.selector, identityManagerRole);
        _setTargetFunctionRole(token, ITREXMessaging.setRoute.selector, identityManagerRole);
        _setTargetFunctionRole(token, ITREXMessaging.setPeer.selector, identityManagerRole);

        // Cross-chain instructions.
        uint64 agentRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT);
        _setTargetFunctionRole(token, IToken.dispatchMintInstruction.selector, agentRole);
        _setTargetFunctionRole(token, IToken.dispatchRecallInstruction.selector, agentRole);

        // From here on, one agent verb per role. Each batch has a row of its own, on the role of its single-item
        // function: without one it falls back to ADMIN_ROLE, and an agent granted with an execution delay could
        // not schedule it at all.

        // Minting.
        uint64 minterRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT_MINTER);
        _setTargetFunctionRole(token, IERC3643.mint.selector, minterRole);
        _setTargetFunctionRole(token, IERC3643.batchMint.selector, minterRole);

        // Burning.
        uint64 burnerRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT_BURNER);
        _setTargetFunctionRole(token, IERC3643.burn.selector, burnerRole);
        _setTargetFunctionRole(token, IERC3643.batchBurn.selector, burnerRole);

        // Freezing part of a balance, and releasing it.
        uint64 partialFreezerRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT_PARTIAL_FREEZER);
        _setTargetFunctionRole(token, IERC3643.freezePartialTokens.selector, partialFreezerRole);
        _setTargetFunctionRole(token, IERC3643.batchFreezePartialTokens.selector, partialFreezerRole);
        _setTargetFunctionRole(token, IERC3643.unfreezePartialTokens.selector, partialFreezerRole);
        _setTargetFunctionRole(token, IERC3643.batchUnfreezePartialTokens.selector, partialFreezerRole);

        // Freezing a whole wallet.
        uint64 addressFreezerRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADDRESS_FREEZER);
        _setTargetFunctionRole(token, IERC3643.setAddressFrozen.selector, addressFreezerRole);
        _setTargetFunctionRole(token, IERC3643.batchSetAddressFrozen.selector, addressFreezerRole);

        // Moving tokens without the holder.
        uint64 forcedTransferRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT_FORCED_TRANSFER);
        _setTargetFunctionRole(token, IERC3643.forcedTransfer.selector, forcedTransferRole);
        _setTargetFunctionRole(token, IERC3643.batchForcedTransfer.selector, forcedTransferRole);

        // Moving a lost wallet's balance to a new wallet.
        uint64 recoveryRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT_RECOVERY_ADDRESS);
        _setTargetFunctionRole(token, IERC3643.recoveryAddress.selector, recoveryRole);

        // Stopping every transfer, and resuming.
        uint64 pauserRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT_PAUSER);
        _setTargetFunctionRole(token, IERC3643.pause.selector, pauserRole);
        _setTargetFunctionRole(token, IERC3643.unpause.selector, pauserRole);
    }

    function _setRegistryFunctionRoles(address registry, uint32 domainId) private {
        // The rules of eligibility: which storage, who is trusted, what is required, whether checks run at all.
        uint64 ownerRole = RolesLib.forDomain(domainId, RolesLib.Role.OWNER);
        _setTargetFunctionRole(registry, IERC3643IdentityRegistry.setIdentityRegistryStorage.selector, ownerRole);
        _setTargetFunctionRole(registry, ITREXRegistry.disableEligibilityChecks.selector, ownerRole);
        _setTargetFunctionRole(registry, ITREXRegistry.enableEligibilityChecks.selector, ownerRole);
        _setTargetFunctionRole(registry, IERC3643TrustedIssuersRegistry.addTrustedIssuer.selector, ownerRole);
        _setTargetFunctionRole(registry, IERC3643TrustedIssuersRegistry.removeTrustedIssuer.selector, ownerRole);
        _setTargetFunctionRole(registry, IERC3643TrustedIssuersRegistry.updateIssuerClaimTopics.selector, ownerRole);
        _setTargetFunctionRole(registry, IERC3643ClaimTopicsRegistry.addClaimTopic.selector, ownerRole);
        _setTargetFunctionRole(registry, IERC3643ClaimTopicsRegistry.removeClaimTopic.selector, ownerRole);
        _setTargetFunctionRole(registry, ITREXRegistry.addClaimTopicForIdentityType.selector, ownerRole);
        _setTargetFunctionRole(registry, ITREXRegistry.removeClaimTopicForIdentityType.selector, ownerRole);

        // Onboarding investors.
        uint64 agentRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT);
        _setTargetFunctionRole(registry, IERC3643IdentityRegistry.registerIdentity.selector, agentRole);
        _setTargetFunctionRole(registry, IERC3643IdentityRegistry.batchRegisterIdentity.selector, agentRole);
        _setTargetFunctionRole(registry, IERC3643IdentityRegistry.updateIdentity.selector, agentRole);
        _setTargetFunctionRole(registry, IERC3643IdentityRegistry.deleteIdentity.selector, agentRole);
    }

    function _setStorageFunctionRoles(address identityStorage, uint32 domainId) private {
        // Attaching a registry to the storage.
        uint64 storageBinderRole = RolesLib.forDomain(domainId, RolesLib.Role.IRS_BINDER);
        _setTargetFunctionRole(
            identityStorage, IERC3643IdentityRegistryStorage.bindIdentityRegistry.selector, storageBinderRole
        );

        // Detaching one.
        uint64 ownerRole = RolesLib.forDomain(domainId, RolesLib.Role.OWNER);
        _setTargetFunctionRole(
            identityStorage, IERC3643IdentityRegistryStorage.unbindIdentityRegistry.selector, ownerRole
        );

        // Writing investor records: registries only, `IRS_WRITER` is granted to them in {_setupSuite}.
        uint64 storageWriterRole = RolesLib.forDomain(domainId, RolesLib.Role.IRS_WRITER);
        _setTargetFunctionRole(
            identityStorage, IERC3643IdentityRegistryStorage.addIdentityToStorage.selector, storageWriterRole
        );
        _setTargetFunctionRole(
            identityStorage, IERC3643IdentityRegistryStorage.modifyStoredIdentity.selector, storageWriterRole
        );
        _setTargetFunctionRole(
            identityStorage, IERC3643IdentityRegistryStorage.removeIdentityFromStorage.selector, storageWriterRole
        );
    }

    function _setComplianceFunctionRoles(address compliance, uint32 domainId) private {
        // The rules themselves: which modules run, and a position fixed by hand. `bindToken` and `unbindToken`
        // share one virtual selector, see {RolesLib.BIND_UNBIND_TOKEN}.
        uint64 ownerRole = RolesLib.forDomain(domainId, RolesLib.Role.OWNER);
        _setTargetFunctionRole(compliance, IModularCompliance.addModule.selector, ownerRole);
        _setTargetFunctionRole(compliance, IModularCompliance.addAndSetModule.selector, ownerRole);
        _setTargetFunctionRole(compliance, IModularCompliance.removeModule.selector, ownerRole);
        _setTargetFunctionRole(compliance, IModularCompliance.forceRemoveModule.selector, ownerRole);
        _setTargetFunctionRole(compliance, IModularCompliance.callModuleFunction.selector, ownerRole);
        _setTargetFunctionRole(compliance, IModularCompliance.resyncModuleTypes.selector, ownerRole);
        _setTargetFunctionRole(compliance, IComplianceLedger.fixPosition.selector, ownerRole);
        _setTargetFunctionRole(compliance, RolesLib.BIND_UNBIND_TOKEN, ownerRole);

        // Cross-chain validation policy.
        uint64 complianceManagerRole = RolesLib.forDomain(domainId, RolesLib.Role.COMPLIANCE_MANAGER);
        _setTargetFunctionRole(compliance, ITransferValidation.setDefaultValidityWindow.selector, complianceManagerRole);
        _setTargetFunctionRole(compliance, ITransferValidation.setReconciliationWindow.selector, complianceManagerRole);
        _setTargetFunctionRole(compliance, ITransferValidation.setIssuancePaused.selector, complianceManagerRole);

        // Issuing a validation.
        uint64 agentRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT);
        _setTargetFunctionRole(compliance, ITransferValidation.requestTransferValidation.selector, agentRole);

        // Cleaning up expired or stuck validations.
        uint64 validationKeeperRole = RolesLib.forDomain(domainId, RolesLib.Role.VALIDATION_KEEPER);
        _setTargetFunctionRole(compliance, ITransferValidation.discardExpiredValidations.selector, validationKeeperRole);
        _setTargetFunctionRole(compliance, ITransferValidation.resolveStuckValidation.selector, validationKeeperRole);
    }

    /// @dev Who hands out which role. The key that appoints never acts: `AGENT_ADMIN` and `SUITE_ADMIN` open
    ///      no suite function. `OWNER`, `SUITE_ADMIN`, `AGENT_ADMIN` and `IRS_WRITER` keep the manager's
    ///      `ADMIN_ROLE` as their admin.
    function _setRoleAdmins(uint32 domainId) private {
        // The agent family is appointed by AGENT_ADMIN.
        uint64 agentAdminRole = RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADMIN);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_MINTER), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_BURNER), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_PARTIAL_FREEZER), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_ADDRESS_FREEZER), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_RECOVERY_ADDRESS), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_FORCED_TRANSFER), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.AGENT_PAUSER), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.IRS_BINDER), agentAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.VALIDATION_KEEPER), agentAdminRole);

        // The configuration managers are appointed by SUITE_ADMIN.
        uint64 suiteAdminRole = RolesLib.forDomain(domainId, RolesLib.Role.SUITE_ADMIN);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.TOKEN_MANAGER), suiteAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.IDENTITY_MANAGER), suiteAdminRole);
        _setRoleAdmin(RolesLib.forDomain(domainId, RolesLib.Role.COMPLIANCE_MANAGER), suiteAdminRole);
    }

    function _getDomainStorage() private pure returns (DomainStorage storage domainStorage) {
        assembly ("memory-safe") {
            domainStorage.slot := DOMAIN_STORAGE_LOCATION
        }
    }

}
