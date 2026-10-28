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

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643ClaimTopicsRegistry } from "../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "../ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ITransferValidation } from "../compliance/modular/ITransferValidation.sol";
import { ModularCompliance } from "../compliance/modular/ModularCompliance.sol";
import { ITREXFactory } from "../factory/ITREXFactory.sol";
import { ITREXMessaging } from "../interop/ITREXMessaging.sol";
import { TrustedGatewayRegistry } from "../interop/TrustedGatewayRegistry.sol";
import { TREXImplementationAuthority } from "../proxy/beacon/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "../registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "../registry/implementation/TREXRegistry.sol";
import { IIdentityRegistryStorage } from "../registry/interface/IIdentityRegistryStorage.sol";
import { IToken } from "../token/IToken.sol";
import { TREXAccessManager } from "../utils/TREXAccessManager.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { RolesLib } from "./RolesLib.sol";

/// @title AccessManagerSetupLib
/// @notice Library for setting up roles and functions in AccessManager for the TREX suite contracts
library AccessManagerSetupLib {

    struct SelectorRole {
        bytes4 selector;
        RolesLib.Role role;
    }

    struct RoleAdmin {
        RolesLib.Role role;
        RolesLib.Role admin;
    }

    uint64 internal constant ADMIN_ROLE = 0;
    uint64 internal constant PUBLIC_ROLE = RolesLib.PUBLIC_ROLE;

    function setupTokenRoles(IAccessManager accessManager, address token, uint32 domainId) internal {
        _apply(accessManager, token, tokenTable(), domainId);
    }

    function setupIdentityRegistryStorageRoles(
        IAccessManager accessManager,
        address identityRegistryStorage,
        uint32 domainId
    ) internal {
        _apply(accessManager, identityRegistryStorage, storageTable(), domainId);
    }

    function setupTREXRegistryRoles(IAccessManager accessManager, address registry, uint32 domainId) internal {
        _apply(accessManager, registry, registryTable(), domainId);
    }

    function setupModularComplianceRoles(IAccessManager accessManager, address modularCompliance, uint32 domainId)
        internal
    {
        _apply(accessManager, modularCompliance, complianceTable(), domainId);
    }

    function tokenTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](19);
        table[0] = SelectorRole(IERC3643.setName.selector, RolesLib.Role.TOKEN_MANAGER);
        table[1] = SelectorRole(IERC3643.setSymbol.selector, RolesLib.Role.TOKEN_MANAGER);
        table[2] = SelectorRole(IERC3643.setOnchainID.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[3] = SelectorRole(IERC3643.setIdentityRegistry.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[4] = SelectorRole(IERC3643.setCompliance.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[5] = SelectorRole(ITREXMessaging.setRoute.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[6] = SelectorRole(ITREXMessaging.setPeer.selector, RolesLib.Role.IDENTITY_MANAGER);
        table[7] = SelectorRole(IToken.delegateOut.selector, RolesLib.Role.AGENT);
        table[8] = SelectorRole(IToken.instructRecall.selector, RolesLib.Role.AGENT);
        table[9] = SelectorRole(IToken.resend.selector, RolesLib.Role.AGENT);
        table[10] = SelectorRole(IERC3643.mint.selector, RolesLib.Role.AGENT_MINTER);
        table[11] = SelectorRole(IERC3643.burn.selector, RolesLib.Role.AGENT_BURNER);
        table[12] = SelectorRole(IERC3643.freezePartialTokens.selector, RolesLib.Role.AGENT_PARTIAL_FREEZER);
        table[13] = SelectorRole(IERC3643.unfreezePartialTokens.selector, RolesLib.Role.AGENT_PARTIAL_FREEZER);
        table[14] = SelectorRole(IERC3643.setAddressFrozen.selector, RolesLib.Role.AGENT_ADDRESS_FREEZER);
        table[15] = SelectorRole(IERC3643.recoveryAddress.selector, RolesLib.Role.AGENT_RECOVERY_ADDRESS);
        table[16] = SelectorRole(IERC3643.forcedTransfer.selector, RolesLib.Role.AGENT_FORCED_TRANSFER);
        table[17] = SelectorRole(IERC3643.pause.selector, RolesLib.Role.AGENT_PAUSER);
        table[18] = SelectorRole(IERC3643.unpause.selector, RolesLib.Role.AGENT_PAUSER);
    }

    function registryTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](14);
        table[0] = SelectorRole(IERC3643IdentityRegistry.setIdentityRegistryStorage.selector, RolesLib.Role.OWNER);
        table[1] = SelectorRole(TREXRegistry.disableEligibilityChecks.selector, RolesLib.Role.OWNER);
        table[2] = SelectorRole(TREXRegistry.enableEligibilityChecks.selector, RolesLib.Role.OWNER);
        table[3] = SelectorRole(IERC3643TrustedIssuersRegistry.addTrustedIssuer.selector, RolesLib.Role.OWNER);
        table[4] = SelectorRole(IERC3643TrustedIssuersRegistry.removeTrustedIssuer.selector, RolesLib.Role.OWNER);
        table[5] = SelectorRole(IERC3643TrustedIssuersRegistry.updateIssuerClaimTopics.selector, RolesLib.Role.OWNER);
        table[6] = SelectorRole(IERC3643ClaimTopicsRegistry.addClaimTopic.selector, RolesLib.Role.OWNER);
        table[7] = SelectorRole(IERC3643ClaimTopicsRegistry.removeClaimTopic.selector, RolesLib.Role.OWNER);
        table[8] = SelectorRole(TREXRegistry.addClaimTopicForIdentityType.selector, RolesLib.Role.OWNER);
        table[9] = SelectorRole(TREXRegistry.removeClaimTopicForIdentityType.selector, RolesLib.Role.OWNER);
        // {_requireFreshOrInDomain} reads this row to tell which domain a registry is in.
        table[10] = SelectorRole(IERC3643IdentityRegistry.registerIdentity.selector, RolesLib.Role.AGENT);
        table[11] = SelectorRole(IERC3643IdentityRegistry.batchRegisterIdentity.selector, RolesLib.Role.AGENT);
        table[12] = SelectorRole(IERC3643IdentityRegistry.updateIdentity.selector, RolesLib.Role.AGENT);
        table[13] = SelectorRole(IERC3643IdentityRegistry.deleteIdentity.selector, RolesLib.Role.AGENT);
    }

    function storageTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](5);
        table[0] = SelectorRole(IdentityRegistryStorage.bindIdentityRegistry.selector, RolesLib.Role.IRS_BINDER);
        table[1] = SelectorRole(IdentityRegistryStorage.unbindIdentityRegistry.selector, RolesLib.Role.OWNER);
        // {_requireFreshOrInDomain} reads this row to tell which domain a storage is in.
        table[2] = SelectorRole(IERC3643IdentityRegistryStorage.addIdentityToStorage.selector, RolesLib.Role.IRS_WRITER);
        table[3] = SelectorRole(IERC3643IdentityRegistryStorage.modifyStoredIdentity.selector, RolesLib.Role.IRS_WRITER);
        table[4] =
            SelectorRole(IERC3643IdentityRegistryStorage.removeIdentityFromStorage.selector, RolesLib.Role.IRS_WRITER);
    }

    function complianceTable() internal pure returns (SelectorRole[] memory table) {
        table = new SelectorRole[](14);
        table[0] = SelectorRole(ModularCompliance.removeModule.selector, RolesLib.Role.OWNER);
        table[1] = SelectorRole(ModularCompliance.forceRemoveModule.selector, RolesLib.Role.OWNER);
        table[2] = SelectorRole(ModularCompliance.addAndSetModule.selector, RolesLib.Role.OWNER);
        // {_requireFreshOrInDomain} reads this row to tell which domain a compliance is in.
        table[3] = SelectorRole(ModularCompliance.addModule.selector, RolesLib.Role.OWNER);
        table[4] = SelectorRole(ModularCompliance.callModuleFunction.selector, RolesLib.Role.OWNER);
        table[5] = SelectorRole(RolesLib.BIND_UNBIND_TOKEN, RolesLib.Role.OWNER);
        table[6] = SelectorRole(ModularCompliance.resyncModuleTypes.selector, RolesLib.Role.OWNER);
        table[7] = SelectorRole(ModularCompliance.setDefaultValidityWindow.selector, RolesLib.Role.COMPLIANCE_MANAGER);
        table[8] = SelectorRole(ModularCompliance.setReconciliationWindow.selector, RolesLib.Role.COMPLIANCE_MANAGER);
        table[9] = SelectorRole(ModularCompliance.setIssuancePaused.selector, RolesLib.Role.COMPLIANCE_MANAGER);
        table[10] = SelectorRole(ITransferValidation.requestTransferValidation.selector, RolesLib.Role.AGENT);
        table[11] = SelectorRole(ModularCompliance.discardExpiredValidations.selector, RolesLib.Role.VALIDATION_KEEPER);
        table[12] = SelectorRole(ModularCompliance.resolveStuckValidation.selector, RolesLib.Role.VALIDATION_KEEPER);
        table[13] = SelectorRole(ModularCompliance.fixPosition.selector, RolesLib.Role.OWNER);
    }

    function roleAdminTable() internal pure returns (RoleAdmin[] memory table) {
        table = new RoleAdmin[](13);
        table[0] = RoleAdmin(RolesLib.Role.AGENT, RolesLib.Role.AGENT_ADMIN);
        table[1] = RoleAdmin(RolesLib.Role.AGENT_MINTER, RolesLib.Role.AGENT_ADMIN);
        table[2] = RoleAdmin(RolesLib.Role.AGENT_BURNER, RolesLib.Role.AGENT_ADMIN);
        table[3] = RoleAdmin(RolesLib.Role.AGENT_PARTIAL_FREEZER, RolesLib.Role.AGENT_ADMIN);
        table[4] = RoleAdmin(RolesLib.Role.AGENT_ADDRESS_FREEZER, RolesLib.Role.AGENT_ADMIN);
        table[5] = RoleAdmin(RolesLib.Role.AGENT_RECOVERY_ADDRESS, RolesLib.Role.AGENT_ADMIN);
        table[6] = RoleAdmin(RolesLib.Role.AGENT_FORCED_TRANSFER, RolesLib.Role.AGENT_ADMIN);
        table[7] = RoleAdmin(RolesLib.Role.AGENT_PAUSER, RolesLib.Role.AGENT_ADMIN);
        table[8] = RoleAdmin(RolesLib.Role.IRS_BINDER, RolesLib.Role.AGENT_ADMIN);
        table[9] = RoleAdmin(RolesLib.Role.VALIDATION_KEEPER, RolesLib.Role.AGENT_ADMIN);
        table[10] = RoleAdmin(RolesLib.Role.TOKEN_MANAGER, RolesLib.Role.SUITE_ADMIN);
        table[11] = RoleAdmin(RolesLib.Role.IDENTITY_MANAGER, RolesLib.Role.SUITE_ADMIN);
        table[12] = RoleAdmin(RolesLib.Role.COMPLIANCE_MANAGER, RolesLib.Role.SUITE_ADMIN);
    }

    /// @notice Commissions the suite of `token` into the domain the manager assigned it to. The identity
    ///         storage joins that same domain: a fresh storage is assigned to it, a storage already in it
    ///         keeps its rows, and a storage of another domain is refused. The same rule holds for the
    ///         registry and the compliance: a fresh one joins the domain, one already set up in another
    ///         domain is refused.
    /// @dev Why a storage belongs to one domain: it holds one record per wallet, whichever registry wrote
    ///      it. If a registry of domain B wrote into the storage of domain A, an agent of B could register
    ///      wallets under, and revoke the wallets of, A's holders through B's registry. So every registry
    ///      bound to a storage holds `IRS_WRITER` in the storage's domain. Tokens of one domain still share
    ///      a storage. The isolation is between the domains' roles, not from the manager's admin: every
    ///      domain of one manager shares its `ADMIN_ROLE`, which can grant `IRS_WRITER` of any domain by hand.
    /// @dev Why a registry and a compliance belong to one domain: commissioning maps their functions to the
    ///      roles of the token's domain. Two tokens of one domain may share a registry (share classes of one
    ///      fund, say) and the rows just get written again with the same roles. A second token of another
    ///      domain would move the registry's rows to its own domain and lock the first domain's agents out
    ///      of their own registry, so it is refused.
    /// @dev Two things say which domain a storage is in, and both are checked. The manager's domain record
    ///      (`domainOf`) is checked here, so a storage recorded in another domain is refused even before its
    ///      rows are mapped. The storage's own selector rows, which actually decide who may write it, are
    ///      checked in {_commission} together with the registry's and the compliance's rows, so a contract
    ///      mapped to another domain is refused whichever form of `commissionSuite` is called and whatever
    ///      the record says.
    function commissionSuite(TREXAccessManager accessManager, address token) internal {
        uint32 domainId = accessManager.domainOf(token);
        require(domainId != 0, ErrorsLib.NotAssigned(token));
        address registry = _registryOf(token);
        address identityRegistryStorage = _storageOf(registry);

        uint32 recordedDomainId = accessManager.domainOf(identityRegistryStorage);
        if (recordedDomainId == 0) {
            accessManager.assign(domainId, identityRegistryStorage);
        } else {
            require(
                recordedDomainId == domainId, ErrorsLib.SuiteAlreadySetUp(identityRegistryStorage, recordedDomainId)
            );
        }

        _commission(accessManager, token, registry, identityRegistryStorage, domainId);
    }

    /// @notice The pure form of {commissionSuite}, for any `IAccessManager`: the caller names the domain, and
    ///         the suite's four contracts, the storage included, are all set up in it.
    /// @dev A plain `IAccessManager` keeps no record of domains, so this form reads the domain a contract is
    ///      in from the contract's own selector rows, see {_commission}: a storage, a registry or a
    ///      compliance whose rows belong to another domain is refused, a fresh one is mapped to `domainId`.
    function commissionSuite(IAccessManager accessManager, address token, uint32 domainId) internal {
        address registry = _registryOf(token);
        _commission(accessManager, token, registry, _storageOf(registry), domainId);
    }

    /// @notice Maps the factory's five functions to the roles that own their subjects. `suiteDeployerRole` uses the
    ///         factory: it deploys suites. Each setter decides something for every later suite, so it goes to the
    ///         role that already owns that subject: `versionManagerRole` repoints the implementation authority,
    ///         which decides the code new suites run; `interopManagerRole` repoints the trusted gateway registry,
    ///         which decides the bridges new tokens trust; `platformOwnerRole` repoints the identity factory, which
    ///         creates new tokens' identities. No role exists only to configure the factory, so nobody can go
    ///         around the version manager or the interop manager by repointing the factory. The ids are data, not
    ///         constants: a {RolesLib.PlatformRole}, a name through {RolesLib.platform(bytes32)} or a raw id.
    /// @dev Refuses the shapes that would let a suite deployer change what later suites get: the suite deployer
    ///      role as any of the three setter roles, `ADMIN_ROLE` as the suite deployer role (an admin can grant
    ///      itself any role), and the public role for any of the four. `ADMIN_ROLE` as a setter role is fine,
    ///      since admins can do everything anyway.
    /// @dev This is a check on the ids, not a separation guarantee: the role hierarchy the manager keeps
    ///      (`getRoleAdmin`) can later make the suite deployer role the admin of a setter role, and nothing here
    ///      can prevent that.
    function setupTREXFactoryRoles(
        IAccessManager accessManager,
        address trexFactory,
        uint64 suiteDeployerRole,
        uint64 versionManagerRole,
        uint64 interopManagerRole,
        uint64 platformOwnerRole
    ) internal {
        require(
            suiteDeployerRole != versionManagerRole && suiteDeployerRole != interopManagerRole
                && suiteDeployerRole != platformOwnerRole,
            ErrorsLib.SuiteDeployerCannotConfigureFactory()
        );
        require(suiteDeployerRole != ADMIN_ROLE, ErrorsLib.SuiteDeployerCannotConfigureFactory());
        _requireNotPublicRole(suiteDeployerRole);
        _requireNotPublicRole(versionManagerRole);
        _requireNotPublicRole(interopManagerRole);
        _requireNotPublicRole(platformOwnerRole);

        // Building suites.
        bytes4[] memory deployFunctions = new bytes4[](2);
        deployFunctions[0] = ITREXFactory.deployTREXSuite.selector;
        deployFunctions[1] = ITREXFactory.deployTREXSuiteIsolated.selector;
        accessManager.setTargetFunctionRole(trexFactory, deployFunctions, suiteDeployerRole);

        // Which code new suites run.
        bytes4[] memory versionFunctions = new bytes4[](1);
        versionFunctions[0] = ITREXFactory.setImplementationAuthority.selector;
        accessManager.setTargetFunctionRole(trexFactory, versionFunctions, versionManagerRole);

        // Which bridges new tokens trust.
        bytes4[] memory interopFunctions = new bytes4[](1);
        interopFunctions[0] = ITREXFactory.setTrustedGatewayRegistry.selector;
        accessManager.setTargetFunctionRole(trexFactory, interopFunctions, interopManagerRole);

        // Who creates new tokens' identities.
        bytes4[] memory identityFunctions = new bytes4[](1);
        identityFunctions[0] = ITREXFactory.setIdFactory.selector;
        accessManager.setTargetFunctionRole(trexFactory, identityFunctions, platformOwnerRole);
    }

    /// @dev Every platform function configures something all suites depend on; none may be open to anyone.
    function _requireNotPublicRole(uint64 role) private pure {
        require(role != PUBLIC_ROLE, ErrorsLib.PlatformRoleCannotBePublic());
    }

    function setupTrustedGatewayRegistryRoles(IAccessManager accessManager, address trustedGatewayRegistry) internal {
        bytes4[] memory functions = new bytes4[](1);
        functions[0] = TrustedGatewayRegistry.setTrustedGateway.selector;
        accessManager.setTargetFunctionRole(
            trustedGatewayRegistry, functions, RolesLib.platform(RolesLib.PlatformRole.INTEROP_MANAGER)
        );
    }

    /// @notice Wires the two prerequisites the {TREXFactory} auto-mint path needs, so a deployer does
    ///         not have to rediscover them. Without both, `deployTREXSuite` reverts with
    ///         `NotAuthorizedForIdentityType` whenever `TokenDetails.ONCHAINID` is left at zero.
    /// @dev Call order does not matter, but both must land before the first auto-mint deploy.
    ///      1. Register the `ASSET` type on the IdentityFactory, gated behind the platform ASSET_DEPLOYER
    ///         role and with self-deploy off: only a registered factory mints token OIDs, and a token
    ///         must not be able to sign one for itself.
    ///      2. Grant that role to the TREX factory.
    /// @dev `accessManager` MUST be the IdentityFactory's own authority, which is not necessarily the
    ///      suite AccessManager: `createIdentityFor` resolves the role against `authority()` on the
    ///      IdentityFactory. Granting the role on the wrong manager leaves the auto-mint path reverting.
    /// @dev The caller must be able to reach both calls: `setIdentityTypePolicy` is `restricted` on the
    ///      IdentityFactory, and `grantRole` requires the caller to be the role's admin.
    /// @dev The ASSET module bundle is ONCHAINID configuration, registered on the IdentityFactory
    ///      via `setIdentityTypeModules` as part of its own deployment. An identity minted for a
    ///      type without modules cannot initialize, so that registration must also land before the
    ///      first auto-mint deploy.
    /// @param accessManager The IdentityFactory's authority, where the role is resolved
    /// @param identityFactory The ONCHAINID IdentityFactory that mints token OIDs
    /// @param trexFactory The TREX factory that calls `createIdentityFor` on the auto-mint path
    function setupIdentityFactoryPolicy(
        IAccessManager accessManager,
        IIdentityFactory identityFactory,
        address trexFactory
    ) internal {
        uint64 assetDeployer = RolesLib.platform(RolesLib.PlatformRole.ASSET_DEPLOYER);
        // ASSET is single-binding: a token OID binds to exactly one token and cannot be re-linked.
        identityFactory.setIdentityTypePolicy(IdentityTypes.ASSET, assetDeployer, false, true);
        accessManager.grantRole(assetDeployer, trexFactory, 0);
    }

    function setupTREXImplementationAuthorityRoles(IAccessManager accessManager, address trexImplementationAuthority)
        internal
    {
        bytes4[] memory functions = new bytes4[](3);
        functions[0] = TREXImplementationAuthority.publish.selector;
        functions[1] = TREXImplementationAuthority.upgrade.selector;
        functions[2] = TREXImplementationAuthority.publishAndUpgrade.selector;
        accessManager.setTargetFunctionRole(
            trexImplementationAuthority, functions, RolesLib.platform(RolesLib.PlatformRole.VERSION_MANAGER)
        );
    }

    function setupRoleAdmins(IAccessManager accessManager, uint32 domainId) internal {
        RoleAdmin[] memory table = roleAdminTable();
        for (uint256 i = 0; i < table.length; i++) {
            accessManager.setRoleAdmin(
                RolesLib.forDomain(domainId, table[i].role), RolesLib.forDomain(domainId, table[i].admin)
            );
        }
    }

    /// @dev The three contracts a second token can share, the storage, the registry and the compliance, are
    ///      checked first, so a refused suite leaves nothing behind. Then the token is made an agent of its
    ///      registry (recovery, cross-chain instructions), and the registry a writer of the storage, since
    ///      only a registry writes into a storage, never a person. Both grants land in the suite's own domain.
    function _commission(
        IAccessManager accessManager,
        address token,
        address registry,
        address identityRegistryStorage,
        uint32 domainId
    ) private {
        address compliance = _complianceOf(token);
        _requireFreshOrInDomain(
            accessManager,
            identityRegistryStorage,
            IERC3643IdentityRegistryStorage.addIdentityToStorage.selector,
            domainId
        );
        _requireFreshOrInDomain(accessManager, registry, IERC3643IdentityRegistry.registerIdentity.selector, domainId);
        _requireFreshOrInDomain(accessManager, compliance, ModularCompliance.addModule.selector, domainId);

        accessManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.AGENT), token, 0);
        accessManager.grantRole(RolesLib.forDomain(domainId, RolesLib.Role.IRS_WRITER), registry, 0);

        setupTokenRoles(accessManager, token, domainId);
        setupTREXRegistryRoles(accessManager, registry, domainId);
        setupModularComplianceRoles(accessManager, compliance, domainId);
        setupRoleAdmins(accessManager, domainId);
        if (!IIdentityRegistryStorage(identityRegistryStorage).isIdentityRegistryBound(registry)) {
            IERC3643IdentityRegistryStorage(identityRegistryStorage).bindIdentityRegistry(registry);
        }
        setupIdentityRegistryStorageRoles(accessManager, identityRegistryStorage, domainId);
    }

    /// @dev Refuses a suite contract whose rows belong to another domain. One row of `target` is read, the
    ///      row of `selector`, chosen as the function that decides who controls the contract: who may write a
    ///      storage (`addIdentityToStorage`), who may admit investors through a registry (`registerIdentity`),
    ///      who may change the rules of a compliance (`addModule`). Three cases:
    ///      1. The row is `ADMIN_ROLE`: no row was ever set, the contract is fresh and is let through. It will
    ///         be mapped to `domainId` by the caller.
    ///      2. The row is a role of `domainId`: the contract is already in this domain, let through. Its rows
    ///         are written again with the same roles.
    ///      3. The row is a role of another domain: refused with `SuiteAlreadySetUp(target, thatDomain)`.
    ///      The domain a role belongs to is the upper half of its id, see {RolesLib.forDomain}.
    function _requireFreshOrInDomain(IAccessManager accessManager, address target, bytes4 selector, uint32 domainId)
        private
        view
    {
        uint64 role = accessManager.getTargetFunctionRole(target, selector);
        if (role == ADMIN_ROLE) return;

        (uint32 targetDomainId,,) = RolesLib.decode(role);
        require(targetDomainId == domainId, ErrorsLib.SuiteAlreadySetUp(target, targetDomainId));
    }

    /// @dev Walks `table` as runs of consecutive same-role entries and maps each run with one
    ///  `setTargetFunctionRole`. The tables above keep every role's selectors consecutive; a table that
    ///  interleaves roles still maps every selector correctly, since the manager writes per selector, it
    ///  only spends one extra call per extra run.
    function _apply(IAccessManager accessManager, address target, SelectorRole[] memory table, uint32 domainId)
        private
    {
        uint256 start;
        while (start < table.length) {
            RolesLib.Role role = table[start].role;
            uint256 end = start;
            while (end < table.length && table[end].role == role) {
                end++;
            }
            bytes4[] memory selectors = new bytes4[](end - start);
            for (uint256 i = start; i < end; i++) {
                selectors[i - start] = table[i].selector;
            }
            accessManager.setTargetFunctionRole(target, selectors, RolesLib.forDomain(domainId, role));
            start = end;
        }
    }

    function _registryOf(address token) private view returns (address) {
        return address(IERC3643(token).identityRegistry());
    }

    function _storageOf(address registry) private view returns (address) {
        return address(IERC3643IdentityRegistry(registry).identityStorage());
    }

    function _complianceOf(address token) private view returns (address) {
        return address(IERC3643(token).compliance());
    }

}
