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
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ModularCompliance } from "../compliance/modular/ModularCompliance.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { IdentityModulesLib } from "../libraries/IdentityModulesLib.sol";
import { RolesLib } from "../libraries/RolesLib.sol";
import { ITREXImplementationAuthority } from "../proxy/beacon/ITREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "../registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "../registry/implementation/TREXRegistry.sol";
import { IIdentityRegistryStorage } from "../registry/interface/IIdentityRegistryStorage.sol";
import { Token } from "../token/Token.sol";
import { AccessManagedOwnable } from "../utils/AccessManagedOwnable.sol";
import { Create3 } from "../vendor/openzeppelin/Create3.sol";
import { ITREXFactory } from "./ITREXFactory.sol";

contract TREXFactory is ITREXFactory, AccessManagedOwnable {

    /// the address of the implementation authority contract used in the tokens deployed by the factory
    address private _implementationAuthority;

    /// the address of the Identity Factory used to deploy token OIDs
    address private _idFactory;

    /// the ONCHAINID KeyApprovalModule singleton installed on token OIDs minted by this factory
    address private _keyApprovalModule;

    /// the ONCHAINID ERC734Validator singleton installed on token OIDs minted by this factory
    address private _validatorModule;

    /// mapping containing info about the token contracts corresponding to salt already used for CREATE3 deployments
    mapping(string => address) public tokenDeployed;

    constructor(
        address implementationAuthority,
        address idFactory,
        address keyApprovalModule,
        address validatorModule,
        address accessManager
    ) AccessManagedOwnable(accessManager) {
        require(accessManager != address(0), ErrorsLib.ZeroAddress());

        _setImplementationAuthority(implementationAuthority);
        _setIdFactory(idFactory);
        _setIdentityModules(keyApprovalModule, validatorModule);
    }

    /**
     *  @dev See {ITREXFactory-deployTREXSuite}.
     */
    function deployTREXSuite(string memory salt, TokenDetails calldata tokenDetails, ClaimDetails calldata claimDetails)
        external
        restricted
    {
        _validateDeploymentInputs(salt, tokenDetails, claimDetails);

        _deploySuiteContracts(
            salt, tokenDetails, claimDetails, ITREXImplementationAuthority(_implementationAuthority).current()
        );
    }

    /**
     *  @dev See {ITREXFactory-deployTREXSuiteIsolated}.
     */
    function deployTREXSuiteIsolated(
        string memory salt,
        TokenDetails calldata tokenDetails,
        ClaimDetails calldata claimDetails
    ) external restricted {
        _validateDeploymentInputs(salt, tokenDetails, claimDetails);

        ITREXImplementationAuthority authority = ITREXImplementationAuthority(_implementationAuthority);
        ITREXImplementationAuthority.SuiteImplementations memory impls =
            authority.implementationsFor(authority.currentVersion());

        // The clones are owned by the suite's own AccessManager, so an isolated suite is upgraded through
        // `AccessManager.execute(beacon, upgradeTo(...))`. An unmapped target function resolves to
        // ADMIN_ROLE, so only that AccessManager's admin can upgrade until an operator maps `upgradeTo`
        // to a narrower role. The shared authority's beacons are untouched and never propagate here.
        address beaconOwner = tokenDetails.accessManager;
        ITREXImplementationAuthority.SuiteBeacons memory beacons = ITREXImplementationAuthority.SuiteBeacons({
            tokenBeacon: address(new UpgradeableBeacon(impls.tokenImplementation, beaconOwner)),
            trexRegistryBeacon: address(new UpgradeableBeacon(impls.trexRegistryImplementation, beaconOwner)),
            irsBeacon: address(new UpgradeableBeacon(impls.irsImplementation, beaconOwner)),
            mcBeacon: address(new UpgradeableBeacon(impls.mcImplementation, beaconOwner))
        });

        address token = _deploySuiteContracts(salt, tokenDetails, claimDetails, beacons);

        emit EventsLib.IsolatedSuiteDeployed(token, beacons);
    }

    /// @dev Shared input validation for both deployment entry points, so they stay in lock-step.
    function _validateDeploymentInputs(
        string memory salt,
        TokenDetails calldata tokenDetails,
        ClaimDetails calldata claimDetails
    ) private view {
        require(tokenDeployed[salt] == address(0), ErrorsLib.TokenAlreadyDeployed());
        require(tokenDetails.accessManager != address(0), ErrorsLib.ZeroAddress());

        require(claimDetails.issuers.length <= 5, ErrorsLib.MaxClaimIssuersReached(5));
        require(claimDetails.claimTopics.length <= 5, ErrorsLib.MaxClaimTopicsReached(5));
        require(
            tokenDetails.irAgents.length <= 5 && tokenDetails.tokenAgents.length <= 5, ErrorsLib.MaxAgentsReached(5)
        );
    }

    /// @dev Deploys the 4 beacon proxies against `beacons`, wires them, and records the token.
    ///      Kept in its own frame so both entry points stay inside the stack budget.
    function _deploySuiteContracts(
        string memory salt,
        TokenDetails calldata tokenDetails,
        ClaimDetails calldata claimDetails,
        ITREXImplementationAuthority.SuiteBeacons memory beacons
    ) private returns (address) {
        address irs = tokenDetails.irs;
        if (irs == address(0)) {
            irs = _deployIRS(salt, beacons.irsBeacon, tokenDetails);
        }

        address registry = _deployTREXRegistry(salt, beacons.trexRegistryBeacon, tokenDetails, irs, claimDetails);
        address mc = _deployMC(salt, beacons.mcBeacon, tokenDetails);

        // a reused IRS must share the suite's AccessManager; the bind reverts otherwise (restricted guard)
        if (tokenDetails.irs != address(0)) {
            _bindReusedIRS(IAccessManager(tokenDetails.accessManager), irs, registry);
        }

        address token = _deployToken(salt, beacons.tokenBeacon, tokenDetails, registry, mc);
        tokenDeployed[salt] = token;

        _grantAgentRoles(tokenDetails, token, registry);

        emit EventsLib.TREXSuiteDeployed(token, registry, irs, mc, salt);
        return token;
    }

    /**
     *  @dev See {ITREXFactory-getImplementationAuthority}.
     */
    function getImplementationAuthority() external view returns (address) {
        return _implementationAuthority;
    }

    /**
     *  @dev See {ITREXFactory-getIdFactory}.
     */
    function getIdFactory() external view returns (address) {
        return _idFactory;
    }

    /**
     *  @dev See {ITREXFactory-getIdentityModules}.
     */
    function getIdentityModules() external view returns (address keyApprovalModule, address validatorModule) {
        return (_keyApprovalModule, _validatorModule);
    }

    /**
     *  @dev See {ITREXFactory-getToken}.
     */
    function getToken(string calldata salt) external view returns (address) {
        return tokenDeployed[salt];
    }

    /**
     *  @dev See {ITREXFactory-setImplementationAuthority}.
     */
    function setImplementationAuthority(address implementationAuthorityAddress) public restricted {
        _setImplementationAuthority(implementationAuthorityAddress);
    }

    /**
     *  @dev See {ITREXFactory-setIdFactory}.
     */
    function setIdFactory(address idFactoryAddress) public restricted {
        _setIdFactory(idFactoryAddress);
    }

    /**
     *  @dev See {ITREXFactory-setIdentityModules}.
     */
    function setIdentityModules(address keyApprovalModuleAddress, address validatorModuleAddress) public restricted {
        _setIdentityModules(keyApprovalModuleAddress, validatorModuleAddress);
    }

    /// internal setter for the implementation authority, see {ITREXFactory-setImplementationAuthority}
    function _setImplementationAuthority(address implementationAuthorityAddress) internal {
        require(implementationAuthorityAddress != address(0), ErrorsLib.ZeroAddress());
        // should not be possible to set an authority that is missing any of the 4 beacons
        ITREXImplementationAuthority.SuiteBeacons memory beacons =
            ITREXImplementationAuthority(implementationAuthorityAddress).current();
        require(
            beacons.tokenBeacon != address(0) && beacons.trexRegistryBeacon != address(0)
                && beacons.irsBeacon != address(0) && beacons.mcBeacon != address(0),
            ErrorsLib.InvalidImplementationAuthority()
        );
        _implementationAuthority = implementationAuthorityAddress;
        emit EventsLib.ImplementationAuthoritySet(implementationAuthorityAddress);
    }

    /// internal setter for the identity factory, see {ITREXFactory-setIdFactory}
    function _setIdFactory(address idFactoryAddress) internal {
        require(idFactoryAddress != address(0), ErrorsLib.ZeroAddress());
        _idFactory = idFactoryAddress;
        emit EventsLib.IdFactorySet(idFactoryAddress);
    }

    /// internal setter for the ONCHAINID module singletons, see {ITREXFactory-setIdentityModules}
    function _setIdentityModules(address keyApprovalModuleAddress, address validatorModuleAddress) internal {
        require(keyApprovalModuleAddress != address(0) && validatorModuleAddress != address(0), ErrorsLib.ZeroAddress());
        _keyApprovalModule = keyApprovalModuleAddress;
        _validatorModule = validatorModuleAddress;
        emit EventsLib.IdentityModulesSet(keyApprovalModuleAddress, validatorModuleAddress);
    }

    /**
     * @dev Deploys a contract using CREATE3
     * @param salt Base salt for deployment
     * @param contractType Contract type identifier (e.g., "IR", "IRS")
     * @param bytecode Full creation bytecode including constructor parameters
     */
    function _deploy(string memory salt, string memory contractType, bytes memory bytecode) internal returns (address) {
        address addr = Create3.deploy(0, _saltBytes(salt, contractType), bytecode);
        emit EventsLib.Deployed(addr);
        return addr;
    }

    /**
     * @dev Returns the address at which `_deploy(salt, contractType, ...)` would land.
     *      Pure function of (factory address, salt, contractType) — bytecode does not influence the result under
     *      CREATE3, which lets the factory pre-compute one suite contract's address while feeding it into another
     *      contract's constructor (e.g. pre-binding the IR address into the IRS proxy).
     */
    function _predictAddress(string memory salt, string memory contractType) internal view returns (address) {
        return Create3.computeAddress(_saltBytes(salt, contractType), address(this));
    }

    /**
     * @dev Computes the CREATE3 salt for a given (salt, contractType) pair.
     *      Salt layout (32 bytes) — preserved from the previous CreateX integration so the per-factory address
     *      derivation stays unchanged should an operator deploy this factory at the same address on multiple
     *      chains.
     *      1) 20 bytes: factory address
     *      2) 1 byte: 0x00
     *      3) 11 bytes: bytes11(keccak256(salt, contractType))
     *
     *      The contractType discriminator prevents the 4 suite contracts from colliding on a single CREATE3 slot
     *      (they all share the user-provided salt).
     */
    function _saltBytes(string memory salt, string memory contractType) private view returns (bytes32) {
        return bytes20(address(this)) | keccak256(bytes(string.concat(salt, contractType))) >> 168;
    }

    /// function used to deploy the merged eligibility registry using CREATE3.
    /// The deployed contract is a stock OZ `BeaconProxy` whose beacon resolves to the current
    /// `TREXRegistry` implementation; `init(...)` is invoked atomically through the proxy constructor,
    /// seeding claim topics and issuers so the factory needs no OWNER privilege over a fresh registry.
    /// Deployed under "REGISTRY" so `_deployIRS` can pre-bind its address via `_predictAddress(salt, "REGISTRY")`.
    function _deployTREXRegistry(
        string memory salt,
        address trexRegistryBeacon,
        TokenDetails calldata tokenDetails,
        address identityStorage,
        ClaimDetails calldata claimDetails
    ) private returns (address) {
        return _deploy(
            salt,
            "REGISTRY",
            _beaconProxyBytecode(
                trexRegistryBeacon,
                abi.encodeCall(
                    TREXRegistry.init,
                    (
                        identityStorage,
                        tokenDetails.accessManager,
                        claimDetails.claimTopics,
                        claimDetails.issuers,
                        claimDetails.issuerClaims
                    )
                )
            )
        );
    }

    /// function used to deploy modular compliance contract using CREATE3.
    function _deployMC(string memory salt, address mcBeacon, TokenDetails calldata tokenDetails)
        private
        returns (address)
    {
        return _deploy(
            salt,
            "MC",
            _beaconProxyBytecode(
                mcBeacon,
                abi.encodeCall(
                    ModularCompliance.init,
                    (
                        _predictAddress(salt, "Token"),
                        tokenDetails.accessManager,
                        tokenDetails.complianceModules,
                        tokenDetails.complianceSettings
                    )
                )
            )
        );
    }

    /// function used to deploy an identity registry storage using CREATE3.
    function _deployIRS(string memory salt, address irsBeacon, TokenDetails calldata tokenDetails)
        private
        returns (address)
    {
        return _deploy(
            salt,
            "IRS",
            _beaconProxyBytecode(
                irsBeacon,
                abi.encodeCall(
                    IdentityRegistryStorage.init, (tokenDetails.accessManager, _predictAddress(salt, "REGISTRY"))
                )
            )
        );
    }

    /// @dev Assembles the creation bytecode of a stock OZ `BeaconProxy` pointed at `beacon` and
    ///  initialized atomically with `initData` inside the proxy constructor.
    function _beaconProxyBytecode(address beacon, bytes memory initData) private pure returns (bytes memory) {
        return bytes.concat(type(BeaconProxy).creationCode, abi.encode(beacon, initData));
    }

    /// Resolves the OID (caller-supplied or minted via `IIdentityFactory.createIdentityFor` against the
    /// Token's predicted CREATE3 address) and deploys the Token proxy. Asserts the deployed Token's
    /// CREATE3 address matches the prediction used by the MC + OID wiring.
    ///
    /// Minting is gated: the IdentityFactory resolves the role configured for `IdentityTypes.ASSET`
    /// against its own authority, so this factory must hold that role there for the auto-mint path
    /// (i.e. tokenDetails.ONCHAINID == address(0)):
    ///   1. `identityFactory.setIdentityTypePolicy(IdentityTypes.ASSET, RolesLib.ASSET_DEPLOYER, false)`
    ///   2. `accessManager.grantRole(RolesLib.ASSET_DEPLOYER, address(this), 0)`
    /// `AccessManagerSetupLib.setupIdentityFactoryPolicy` bundles both.
    function _deployToken(
        string memory salt,
        address tokenBeacon,
        TokenDetails calldata tokenDetails,
        address identityRegistry,
        address compliance
    ) private returns (address) {
        address predictedToken = _predictAddress(salt, "Token");
        address oid = tokenDetails.ONCHAINID;
        if (oid == address(0)) {
            oid = IIdentityFactory(_idFactory)
                .createIdentityFor(
                    predictedToken,
                    IdentityTypes.ASSET,
                    salt,
                    IdentityModulesLib.managementKeys(tokenDetails.accessManager),
                    IdentityModulesLib.legacyQueueModules(_keyApprovalModule, _validatorModule)
                );
        }
        address token =
            _deploy(salt, "Token", _tokenBytecode(tokenBeacon, tokenDetails, identityRegistry, compliance, oid));
        return token;
    }

    function _tokenBytecode(
        address tokenBeacon,
        TokenDetails calldata tokenDetails,
        address identityRegistry,
        address compliance,
        address oid
    ) private pure returns (bytes memory) {
        return _beaconProxyBytecode(
            tokenBeacon,
            abi.encodeCall(
                Token.init,
                (
                    tokenDetails.name,
                    tokenDetails.symbol,
                    tokenDetails.decimals,
                    identityRegistry,
                    compliance,
                    oid,
                    tokenDetails.accessManager
                )
            )
        );
    }

    /// Binds a new IR onto a reused IRS using a transient IRS_BINDER grant.
    /// bindIdentityRegistry is gated to IRS_BINDER (see AccessManagerSetupLib): the factory holds no
    /// standing privilege over the IRS, so it self-grants IRS_BINDER for the single bind call and
    /// revokes it immediately after, leaving no residual authority. Requires the factory to hold the
    /// admin of IRS_BINDER (AGENT_ADMIN) on `accessManager`.
    function _bindReusedIRS(IAccessManager accessManager, address irs, address identityRegistry) private {
        accessManager.grantRole(RolesLib.IRS_BINDER, address(this), 0);
        IIdentityRegistryStorage(irs).bindIdentityRegistry(identityRegistry);
        accessManager.revokeRole(RolesLib.IRS_BINDER, address(this));
    }

    /// Grants the AGENT role to the token, the identity registry and the configured agents.
    /// Requires the factory to hold the admin role of AGENT on `tokenDetails.accessManager`.
    function _grantAgentRoles(TokenDetails calldata tokenDetails, address token, address identityRegistry) private {
        IAccessManager accessManager = IAccessManager(tokenDetails.accessManager);

        accessManager.grantRole(RolesLib.AGENT, token, 0);
        accessManager.grantRole(RolesLib.AGENT, identityRegistry, 0);
        for (uint256 i = 0; i < tokenDetails.irAgents.length; i++) {
            accessManager.grantRole(RolesLib.AGENT, tokenDetails.irAgents[i], 0);
        }
        for (uint256 i = 0; i < tokenDetails.tokenAgents.length; i++) {
            accessManager.grantRole(RolesLib.AGENT, tokenDetails.tokenAgents[i], 0);
        }
    }

}
