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
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { Create3 } from "@openzeppelin/contracts/utils/Create3.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularCompliance } from "../compliance/modular/ModularCompliance.sol";
import { AccessManagerSetupLib } from "../libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { ITREXImplementationAuthority } from "../proxy/beacon/ITREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "../registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "../registry/implementation/TREXRegistry.sol";
import { IToken } from "../token/IToken.sol";
import { AccessManagedOwnable } from "../utils/AccessManagedOwnable.sol";
import { TREXAccessManager } from "../utils/TREXAccessManager.sol";
import { ITREXFactory } from "./ITREXFactory.sol";

/// @title TREXFactory
/// @notice Deploys T-REX suites at CREATE3 addresses anyone can compute from the salt before the suite exists.
/// @dev Deployment requirement on the IdentityFactory this factory uses: INDIVIDUAL and CORPORATE identity
///      creation for another account (`createIdentityFor`) must never be open to the IdentityFactory
///      authority's `PUBLIC_ROLE`, and neither may any other type that is not single-binding. Such a type binds
///      its new identity to any account set as its only MANAGEMENT key, without a signature from that account,
///      so anyone could bind a predicted token address first. The binding is permanent: the auto-created token
///      identity and a supplied ONCHAINID both revert on the occupied address, and that salt is lost on the
///      chain. Self-deploy (`createIdentity`) binds the caller only and may stay open.
contract TREXFactory is ITREXFactory, AccessManagedOwnable {

    /// the address of the implementation authority contract used in the tokens deployed by the factory
    address private _implementationAuthority;

    /// the address of the Identity Factory used to deploy token OIDs
    address private _idFactory;

    /// the network's trusted gateway registry, wired into every token this factory deploys
    address private _trustedGatewayRegistry;

    /// mapping containing info about the token contracts corresponding to salt already used for CREATE3 deployments
    mapping(string => address) public tokenDeployed;

    /// The contract type each suite contract is predicted and deployed under, so both paths use one spelling.
    string private constant ACCESS_MANAGER = "AccessManager";
    string private constant TOKEN = "Token";
    string private constant REGISTRY = "REGISTRY";
    string private constant IRS = "IRS";
    string private constant MC = "MC";

    constructor(
        address implementationAuthority,
        address idFactory,
        address trustedGatewayRegistry,
        address accessManager
    ) AccessManagedOwnable(accessManager) {
        require(accessManager != address(0), ErrorsLib.ZeroAddress());

        _setImplementationAuthority(implementationAuthority);
        _setIdFactory(idFactory);
        _setTrustedGatewayRegistry(trustedGatewayRegistry);
    }

    /**
     *  @dev See {ITREXFactory-deployTREXSuite}.
     *  With `tokenDetails.accessManager == address(0)` the factory deploys a `TREXAccessManager`, creates a
     *  domain named after the token, assigns the token and its storage, commissions the suite and hands
     *  `ADMIN_ROLE` to `tokenDetails.accessManagerAdmin`. With a supplied manager the factory never calls
     *  it: the suite deploys with no role wiring and is not operable until the issuer commissions it with
     *  `AccessManagerSetupLib.commissionSuite`.
     */
    function deployTREXSuite(string memory salt, TokenDetails calldata tokenDetails, ClaimDetails calldata claimDetails)
        external
        restricted
    {
        _validateDeploymentInputs(salt, tokenDetails, claimDetails);

        _deploySuiteContracts(
            salt, tokenDetails, claimDetails, ITREXImplementationAuthority(_implementationAuthority).beacons()
        );
    }

    /**
     *  @dev See {ITREXFactory-deployTREXSuiteIsolated}.
     *  With `tokenDetails.accessManager == address(0)` the factory deploys a `TREXAccessManager`, creates a
     *  domain named after the token, assigns the token and its storage, commissions the suite and hands
     *  `ADMIN_ROLE` to `tokenDetails.accessManagerAdmin`. With a supplied manager the factory never calls
     *  it: the suite deploys with no role wiring and is not operable until the issuer commissions it with
     *  `AccessManagerSetupLib.commissionSuite`.
     */
    function deployTREXSuiteIsolated(
        string memory salt,
        TokenDetails calldata tokenDetails,
        ClaimDetails calldata claimDetails
    ) external restricted {
        _validateDeploymentInputs(salt, tokenDetails, claimDetails);

        // A reused IRS keeps the beacon that deployed it, so shared upgrades would still reach this suite.
        // A BeaconProxy exposes no beacon getter, so it cannot be checked: isolated suites deploy their own.
        require(tokenDetails.irs == address(0), ErrorsLib.IsolatedSuiteCannotReuseIRS());

        ITREXImplementationAuthority authority = ITREXImplementationAuthority(_implementationAuthority);
        ITREXImplementationAuthority.SuiteImplementations memory impls =
            authority.implementationsFor(authority.currentVersion());

        // The clones are owned by the suite's own AccessManager, so an isolated suite is upgraded through
        // `AccessManager.execute(beacon, upgradeTo(...))`. An unmapped target function resolves to
        // ADMIN_ROLE, so only that AccessManager's admin can upgrade until an operator maps `upgradeTo`
        // to a narrower role. The shared authority's beacons are untouched and never propagate here.
        address manager = tokenDetails.accessManager;
        address accessManagerBeacon;
        if (manager == address(0)) {
            manager = _predictAddress(salt, ACCESS_MANAGER);
            accessManagerBeacon =
                address(new UpgradeableBeacon(impls.accessManagerImplementation, tokenDetails.accessManagerAdmin));
        }
        ITREXImplementationAuthority.SuiteBeacons memory beacons = ITREXImplementationAuthority.SuiteBeacons({
            tokenBeacon: address(new UpgradeableBeacon(impls.tokenImplementation, manager)),
            trexRegistryBeacon: address(new UpgradeableBeacon(impls.trexRegistryImplementation, manager)),
            irsBeacon: address(new UpgradeableBeacon(impls.irsImplementation, manager)),
            mcBeacon: address(new UpgradeableBeacon(impls.mcImplementation, manager)),
            accessManagerBeacon: accessManagerBeacon
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
        if (tokenDetails.accessManager == address(0)) {
            address admin = tokenDetails.accessManagerAdmin;
            require(admin != address(0), ErrorsLib.ZeroAddress());
            // None of these contracts ever acts as the manager's administrator, so naming one would leave the
            // suite with none.
            require(!_isFactoryOrSuiteContract(salt, admin), ErrorsLib.InvalidAccessManagerAdmin());
        } else {
            require(
                tokenDetails.accessManager.code.length != 0,
                ErrorsLib.AccessManagerNotAContract(tokenDetails.accessManager)
            );
        }

        require(claimDetails.issuers.length <= 5, ErrorsLib.MaxClaimIssuersReached(5));
        require(claimDetails.claimTopics.length <= 5, ErrorsLib.MaxClaimTopicsReached(5));
    }

    /// @dev Deploys the beacon proxies against `beacons`, wires them, and records the token.
    ///      Kept in its own frame so both entry points stay inside the stack budget.
    function _deploySuiteContracts(
        string memory salt,
        TokenDetails calldata tokenDetails,
        ClaimDetails calldata claimDetails,
        ITREXImplementationAuthority.SuiteBeacons memory beacons
    ) private returns (address) {
        address manager = tokenDetails.accessManager;
        if (manager == address(0)) {
            manager = _deployAccessManager(salt, beacons.accessManagerBeacon);
        }
        address irs = tokenDetails.irs;
        if (irs == address(0)) {
            irs = _deployIRS(salt, beacons.irsBeacon, manager);
        } else {
            address authority = IAccessManaged(irs).authority();
            require(authority == manager, ErrorsLib.StorageAuthorityMismatch(irs, manager, authority));
        }
        address registry = _deployTREXRegistry(salt, beacons.trexRegistryBeacon, manager, irs, claimDetails);
        address mc = _deployMC(salt, beacons.mcBeacon, tokenDetails, manager);
        address token = _deployToken(salt, beacons.tokenBeacon, tokenDetails, manager, registry, mc);
        tokenDeployed[salt] = token;
        if (tokenDetails.accessManager == address(0)) {
            _handOverAccessManager(manager, tokenDetails.accessManagerAdmin, token, tokenDetails.name);
        }

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

    /// internal setter for the implementation authority, see {ITREXFactory-setImplementationAuthority}
    function _setImplementationAuthority(address implementationAuthorityAddress) internal {
        require(implementationAuthorityAddress != address(0), ErrorsLib.ZeroAddress());
        // should not be possible to set an authority that is missing any of the beacons
        ITREXImplementationAuthority.SuiteBeacons memory beacons =
            ITREXImplementationAuthority(implementationAuthorityAddress).beacons();
        require(
            beacons.tokenBeacon != address(0) && beacons.trexRegistryBeacon != address(0)
                && beacons.irsBeacon != address(0) && beacons.mcBeacon != address(0)
                && beacons.accessManagerBeacon != address(0),
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

    /**
     *  @dev See {ITREXFactory-getTrustedGatewayRegistry}.
     */
    function getTrustedGatewayRegistry() external view returns (address) {
        return _trustedGatewayRegistry;
    }

    /**
     *  @dev See {ITREXFactory-setTrustedGatewayRegistry}.
     */
    function setTrustedGatewayRegistry(address trustedGatewayRegistryAddress) public restricted {
        _setTrustedGatewayRegistry(trustedGatewayRegistryAddress);
    }

    /// internal setter for the trusted gateway registry, see {ITREXFactory-setTrustedGatewayRegistry}
    function _setTrustedGatewayRegistry(address trustedGatewayRegistryAddress) internal {
        require(trustedGatewayRegistryAddress != address(0), ErrorsLib.ZeroAddress());
        _trustedGatewayRegistry = trustedGatewayRegistryAddress;
        emit EventsLib.TrustedGatewayRegistrySet(trustedGatewayRegistryAddress);
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

    /// @dev Whether `account` is this factory or one of the contracts the suite for `salt` will be deployed at.
    function _isFactoryOrSuiteContract(string memory salt, address account) private view returns (bool) {
        return account == address(this) || account == _predictAddress(salt, ACCESS_MANAGER)
            || account == _predictAddress(salt, TOKEN) || account == _predictAddress(salt, REGISTRY)
            || account == _predictAddress(salt, IRS) || account == _predictAddress(salt, MC);
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

    function _deployAccessManager(string memory salt, address accessManagerBeacon) private returns (address) {
        return _deploy(
            salt,
            ACCESS_MANAGER,
            _beaconProxyBytecode(
                accessManagerBeacon, abi.encodeCall(AccessManagerUpgradeable.initialize, (address(this)))
            )
        );
    }

    function _handOverAccessManager(address manager, address admin, address token, string memory name) private {
        TREXAccessManager accessManager = TREXAccessManager(manager);
        uint32 domainId = accessManager.createDomain(name);
        accessManager.assign(domainId, token);
        AccessManagerSetupLib.commissionSuite(accessManager, token);
        accessManager.grantRole(AccessManagerSetupLib.ADMIN_ROLE, admin, 0);
        accessManager.renounceRole(AccessManagerSetupLib.ADMIN_ROLE, address(this));
    }

    function _deployTREXRegistry(
        string memory salt,
        address trexRegistryBeacon,
        address manager,
        address identityStorage,
        ClaimDetails calldata claimDetails
    ) private returns (address) {
        return _deploy(
            salt,
            REGISTRY,
            _beaconProxyBytecode(
                trexRegistryBeacon,
                abi.encodeCall(
                    TREXRegistry.init,
                    (
                        identityStorage,
                        manager,
                        claimDetails.claimTopics,
                        claimDetails.issuers,
                        claimDetails.issuerClaims
                    )
                )
            )
        );
    }

    /// function used to deploy modular compliance contract using CREATE3.
    function _deployMC(string memory salt, address mcBeacon, TokenDetails calldata tokenDetails, address manager)
        private
        returns (address)
    {
        return _deploy(
            salt,
            MC,
            _beaconProxyBytecode(
                mcBeacon,
                abi.encodeCall(
                    ModularCompliance.init,
                    (
                        _predictAddress(salt, TOKEN),
                        manager,
                        tokenDetails.complianceModules,
                        tokenDetails.complianceSettings
                    )
                )
            )
        );
    }

    /// function used to deploy an identity registry storage using CREATE3.
    function _deployIRS(string memory salt, address irsBeacon, address manager) private returns (address) {
        return _deploy(
            salt,
            IRS,
            _beaconProxyBytecode(
                irsBeacon,
                abi.encodeCall(IdentityRegistryStorage.init, (manager, _predictAddress(salt, REGISTRY), _idFactory))
            )
        );
    }

    /// @dev Assembles the creation bytecode of a stock OZ `BeaconProxy` pointed at `beacon` and
    ///  initialized atomically with `initData` inside the proxy constructor.
    function _beaconProxyBytecode(address beacon, bytes memory initData) private pure returns (bytes memory) {
        return bytes.concat(type(BeaconProxy).creationCode, abi.encode(beacon, initData));
    }

    /// Resolves the OID (caller-supplied or minted via `IIdentityFactory.createIdentityFor` against the
    /// Token's predicted CREATE3 address) and deploys the Token proxy. A caller-supplied OID must already
    /// be the IdentityFactory's active binding for that same predicted address: the suite never deploys onto
    /// an address the factory resolves to a different identity, or to none (unbound or revoked). The deployer binds it first by
    /// calling `createIdentityFor(predictedToken, IdentityTypes.ASSET, salt, keys)` on the IdentityFactory
    /// with the role the ASSET policy names, and passes the returned identity as `ONCHAINID`. The caller of
    /// the deploy must be a MANAGEMENT key of that identity.
    /// `predictedToken` is `Create3.computeAddress(bytes20(factory) | keccak256(salt ++ "Token") >> 168, factory)`.
    ///
    /// Minting is gated: the IdentityFactory resolves the role configured for `IdentityTypes.ASSET`
    /// against its own authority, so this factory must hold that role there for the auto-mint path
    /// (i.e. tokenDetails.ONCHAINID == address(0)):
    ///   1. `identityFactory.setIdentityTypePolicy(IdentityTypes.ASSET, assetDeployer, false, true)`
    ///   2. `accessManager.grantRole(assetDeployer, address(this), 0)`
    ///   with `assetDeployer = RolesLib.platform(RolesLib.PlatformRole.ASSET_DEPLOYER)`.
    /// `AccessManagerSetupLib.setupIdentityFactoryPolicy` bundles both. The ASSET module bundle is
    /// registered on the IdentityFactory itself (`setIdentityTypeModules`) as part of its deployment.
    function _deployToken(
        string memory salt,
        address tokenBeacon,
        TokenDetails calldata tokenDetails,
        address manager,
        address identityRegistry,
        address compliance
    ) private returns (address) {
        address predictedToken = _predictAddress(salt, TOKEN);
        address oid = tokenDetails.ONCHAINID;
        if (oid == address(0)) {
            oid = IIdentityFactory(_idFactory)
                .createIdentityFor(predictedToken, IdentityTypes.ASSET, salt, _managementKeys(manager));
        } else {
            // The token address is predictable, so anyone allowed to create ASSET identities can
            // bind it to their own identity before this deploy runs. The binding is permanent, and
            // the token would then answer to one identity while the IdentityFactory answers another.
            // An unbound slot is refused too: this factory never binds a supplied identity, so the
            // slot would stay open for anyone to take once the token is live.
            // `getIdentity` answers only an active binding, so an unbound, a revoked and a squatted slot all fail.
            address boundIdentity = IIdentityFactory(_idFactory)
                .getIdentity(InteroperableAddress.formatEvmV1(block.chainid, predictedToken));
            require(boundIdentity == oid, ErrorsLib.TokenIdentityNotBound(predictedToken, oid));
            // Binding and deploying are two transactions and the salt is not tied to the caller, so another
            // suite deployer could deploy this salt in between with the issuer's identity and its own admin.
            // Only a MANAGEMENT key of the supplied identity may attach it to a token.
            require(
                IERC734(oid).keyHasPurpose(keccak256(abi.encodePacked(msg.sender)), KeyPurposes.MANAGEMENT),
                ErrorsLib.TokenIdentityNotManagedByCaller(oid, msg.sender)
            );
        }
        return
            _deploy(salt, TOKEN, _tokenBytecode(tokenBeacon, tokenDetails, manager, identityRegistry, compliance, oid));
    }

    /// @dev Builds the single-entry MANAGEMENT key set granting `managementKey` control of the minted
    ///  token OID. Modules are not passed here: the IdentityFactory installs the bundle registered for
    ///  the ASSET type via `setIdentityTypeModules`.
    function _managementKeys(address managementKey) private pure returns (Structs.KeyParam[] memory keys) {
        keys = new Structs.KeyParam[](1);
        keys[0] = Structs.KeyParam({
            keyHash: keccak256(abi.encodePacked(managementKey)),
            purpose: KeyPurposes.MANAGEMENT,
            keyType: KeyTypes.ECDSA,
            signerData: abi.encodePacked(managementKey),
            clientData: ""
        });
    }

    function _tokenBytecode(
        address tokenBeacon,
        TokenDetails calldata tokenDetails,
        address manager,
        address identityRegistry,
        address compliance,
        address oid
    ) private view returns (bytes memory) {
        return _beaconProxyBytecode(
            tokenBeacon,
            abi.encodeCall(
                IToken.init,
                (
                    tokenDetails.name,
                    tokenDetails.symbol,
                    tokenDetails.decimals,
                    identityRegistry,
                    compliance,
                    _trustedGatewayRegistry,
                    oid,
                    manager
                )
            )
        );
    }

}
