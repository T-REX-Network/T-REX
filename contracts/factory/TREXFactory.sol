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
pragma solidity ^0.8.30;

import { IIdFactory } from "@onchain-id/solidity/contracts/factory/IIdFactory.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { AccessManagerSetupLib } from "../libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { RolesLib } from "../libraries/RolesLib.sol";
import { ClaimTopicsRegistryProxy } from "../proxy/ClaimTopicsRegistryProxy.sol";
import { IdentityRegistryProxy } from "../proxy/IdentityRegistryProxy.sol";
import { IdentityRegistryStorageProxy } from "../proxy/IdentityRegistryStorageProxy.sol";
import { ModularComplianceProxy } from "../proxy/ModularComplianceProxy.sol";
import { TokenProxy } from "../proxy/TokenProxy.sol";
import { TrustedIssuersRegistryProxy } from "../proxy/TrustedIssuersRegistryProxy.sol";
import { ITREXImplementationAuthority } from "../proxy/authority/ITREXImplementationAuthority.sol";
import { IIdentityRegistryStorage } from "../registry/interface/IIdentityRegistryStorage.sol";
import { Create3 } from "../vendor/openzeppelin/Create3.sol";
import { ITREXFactory } from "./ITREXFactory.sol";

contract TREXFactory is ITREXFactory, Ownable, AccessManaged {

    /// the address of the implementation authority contract used in the tokens deployed by the factory
    address private _implementationAuthority;

    /// the address of the Identity Factory used to deploy token OIDs
    address private _idFactory;

    /// mapping containing info about the token contracts corresponding to salt already used for CREATE3 deployments
    mapping(string => address) public tokenDeployed;

    constructor(address implementationAuthority, address idFactory, address accessManager)
        Ownable(accessManager)
        AccessManaged(accessManager)
    {
        _setImplementationAuthority(implementationAuthority);
        _setIdFactory(idFactory);
    }

    /**
     *  @dev See {ITREXFactory-deployTREXSuite}.
     *
     *  The deployment uses CREATE3 so each suite contract address is a pure function of (factory, salt,
     *  contractType). That determinism lets the factory pre-compute the Token address and bake it into the
     *  ModularCompliance (token binding) and into the on-chain identity wiring before the Token itself is deployed.
     *
     *  Initial claim topics, trusted issuers and compliance modules are baked into the respective `init()`s
     *  (CTR / TIR / MC) — there are no post-deploy `addClaimTopic` / `addTrustedIssuer` / `addModule` loops.
     *
     *  Access control is delegated entirely to the shared AccessManager: per-contract function roles are wired via
     *  {AccessManagerSetupLib} and the agent/admin roles are granted on the AccessManager. The factory must hold the
     *  admin role (roleId 0) on the provided AccessManager.
     */
    // solhint-disable-next-line code-complexity, function-max-lines
    function deployTREXSuite(string memory salt, TokenDetails calldata tokenDetails, ClaimDetails calldata claimDetails)
        external
        override
        restricted
    {
        require(tokenDeployed[salt] == address(0), ErrorsLib.TokenAlreadyDeployed());

        require(tokenDetails.accessManager != address(0), ErrorsLib.ZeroAddress());
        {
            (bool hasAdminRole,) = IAccessManager(tokenDetails.accessManager).hasRole(0, address(this));
            require(hasAdminRole, ErrorsLib.FactoryMissingAdminRoleOnAccessManager());
        }

        require((claimDetails.issuers).length == (claimDetails.issuerClaims).length, ErrorsLib.InvalidClaimPattern());
        require((claimDetails.issuers).length <= 5, ErrorsLib.MaxClaimIssuersReached(5));
        require((claimDetails.claimTopics).length <= 5, ErrorsLib.MaxClaimTopicsReached(5));
        require(
            (tokenDetails.irAgents).length <= 5 && (tokenDetails.tokenAgents).length <= 5, ErrorsLib.MaxAgentsReached(5)
        );
        require((tokenDetails.complianceModules).length <= 30, ErrorsLib.MaxModuleActionsReached(30));
        require(
            (tokenDetails.complianceModules).length >= (tokenDetails.complianceSettings).length,
            ErrorsLib.InvalidCompliancePattern()
        );

        address tir = _deployTIR(salt, tokenDetails.accessManager, claimDetails.issuers, claimDetails.issuerClaims);
        address ctr = _deployCTR(salt, tokenDetails.accessManager, claimDetails.claimTopics);
        address mc = _deployMC(salt, tokenDetails, tokenDetails.accessManager);

        address irs = tokenDetails.irs == address(0) ? _deployIRS(salt, tokenDetails.accessManager) : tokenDetails.irs;

        address ir = _deployIR(salt, tir, ctr, irs, tokenDetails.accessManager);
        require(ir == _predictAddress(salt, "IR"), ErrorsLib.AddressPredictionMismatch());

        address token = _deployToken(salt, tokenDetails, ir, mc, tokenDetails.accessManager);

        // Wire all AccessManager roles / grants / binding (kept out of this frame to bound stack usage).
        _wireSuiteRoles(tokenDetails, tir, ctr, mc, irs, ir, token);

        tokenDeployed[salt] = token;

        emit EventsLib.TREXSuiteDeployed(token, ir, irs, tir, ctr, mc, salt);
    }

    /**
     * @dev Configures the per-contract function roles on the AccessManager (via {AccessManagerSetupLib}) and grants
     *      the agent / admin / identity-admin roles for the freshly deployed suite. Binding the IR to the IRS grants
     *      the IR the AGENT role so it can write to the IRS.
     */
    function _wireSuiteRoles(
        TokenDetails calldata tokenDetails,
        address tir,
        address ctr,
        address mc,
        address irs,
        address ir,
        address token
    ) private {
        IAccessManager accessManager = IAccessManager(tokenDetails.accessManager);

        AccessManagerSetupLib.setupTrustedIssuersRegistryRoles(accessManager, tir);
        AccessManagerSetupLib.setupClaimTopicsRegistryRoles(accessManager, ctr);
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, mc);

        if (tokenDetails.irs == address(0)) {
            AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, irs);
            // The IRS must be able to grant the AGENT role to the Identity Registries it binds.
            accessManager.grantRole(0, irs, 0);
        }

        AccessManagerSetupLib.setupIdentityRegistryRoles(accessManager, ir);

        AccessManagerSetupLib.setupTokenRoles(accessManager, token);
        accessManager.grantRole(RolesLib.AGENT, token, 0);
        accessManager.grantRole(RolesLib.IDENTITY_ADMIN, token, 0);

        // Binding grants the AGENT role to the IR on the AccessManager so it can write to the IRS.
        IIdentityRegistryStorage(irs).bindIdentityRegistry(ir);
        accessManager.grantRole(RolesLib.AGENT, irs, 0);

        for (uint256 i = 0; i < (tokenDetails.irAgents).length; i++) {
            accessManager.grantRole(RolesLib.AGENT, tokenDetails.irAgents[i], 0);
        }
        for (uint256 i = 0; i < (tokenDetails.tokenAgents).length; i++) {
            accessManager.grantRole(RolesLib.AGENT, tokenDetails.tokenAgents[i], 0);
        }
    }

    /**
     *  @dev See {ITREXFactory-getImplementationAuthority}.
     */
    function getImplementationAuthority() external view override returns (address) {
        return _implementationAuthority;
    }

    /**
     *  @dev See {ITREXFactory-getIdFactory}.
     */
    function getIdFactory() external view override returns (address) {
        return _idFactory;
    }

    /**
     *  @dev See {ITREXFactory-getToken}.
     */
    function getToken(string calldata salt) external view override returns (address) {
        return tokenDeployed[salt];
    }

    /**
     *  @dev See {ITREXFactory-setImplementationAuthority}.
     */
    function setImplementationAuthority(address implementationAuthority) external override restricted {
        _setImplementationAuthority(implementationAuthority);
    }

    function _setImplementationAuthority(address implementationAuthority) internal {
        require(implementationAuthority != address(0), ErrorsLib.ZeroAddress());
        // should not be possible to set an implementation authority that is not complete
        require(
            (ITREXImplementationAuthority(implementationAuthority)).getTokenImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority)).getCTRImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority)).getIRImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority)).getIRSImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority)).getMCImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority)).getTIRImplementation() != address(0),
            ErrorsLib.InvalidImplementationAuthority()
        );
        _implementationAuthority = implementationAuthority;
        emit EventsLib.ImplementationAuthoritySet(implementationAuthority);
    }

    /**
     *  @dev See {ITREXFactory-setIdFactory}.
     */
    function setIdFactory(address idFactory) external override restricted {
        _setIdFactory(idFactory);
    }

    function _setIdFactory(address idFactory) internal {
        require(idFactory != address(0), ErrorsLib.ZeroAddress());
        _idFactory = idFactory;
        emit EventsLib.IdFactorySet(idFactory);
    }

    /**
     * @dev Deploys a contract using CREATE3
     * @param salt Base salt for deployment
     * @param contractType Contract type identifier (e.g., "TIR", "CTR")
     * @param bytecode Full creation bytecode including constructor parameters
     */
    function _deploy(string memory salt, string memory contractType, bytes memory bytecode) internal returns (address) {
        address addr = Create3.deploy(0, saltBytes(salt, contractType), bytecode);
        emit EventsLib.Deployed(addr);
        return addr;
    }

    /**
     * @dev Returns the address at which `_deploy(salt, contractType, ...)` would land.
     *      Pure function of (factory address, salt, contractType) — bytecode does not influence the result under
     *      CREATE3, which lets the factory pre-compute one suite contract's address while feeding it into another
     *      contract's constructor (e.g. pre-binding the Token address into the ModularCompliance proxy).
     */
    function _predictAddress(string memory salt, string memory contractType) internal view returns (address) {
        return Create3.computeAddress(saltBytes(salt, contractType), address(this));
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
     *      The contractType discriminator prevents the 6 suite contracts from colliding on a single CREATE3 slot
     *      (they all share the user-provided salt).
     */
    function saltBytes(string memory salt, string memory contractType) private view returns (bytes32) {
        return bytes32(
            abi.encodePacked(address(this), bytes1(0x00), bytes11(keccak256(abi.encodePacked(salt, contractType))))
        );
    }

    /// function used to deploy a trusted issuers registry using CREATE3
    function _deployTIR(
        string memory salt,
        address accessManager,
        address[] memory issuers,
        uint256[][] memory issuerClaims
    ) private returns (address) {
        bytes memory code = type(TrustedIssuersRegistryProxy).creationCode;
        bytes memory constructData = abi.encode(_implementationAuthority, accessManager, issuers, issuerClaims);
        bytes memory bytecode = abi.encodePacked(code, constructData);
        return _deploy(salt, "TIR", bytecode);
    }

    /// function used to deploy a claim topics registry using CREATE3
    function _deployCTR(string memory salt, address accessManager, uint256[] memory _initialTopics)
        private
        returns (address)
    {
        bytes memory code = type(ClaimTopicsRegistryProxy).creationCode;
        bytes memory constructData = abi.encode(_implementationAuthority, accessManager, _initialTopics);
        bytes memory bytecode = abi.encodePacked(code, constructData);
        return _deploy(salt, "CTR", bytecode);
    }

    /// function used to deploy modular compliance contract using CREATE3.
    /// The Token's predicted CREATE3 address is baked in so the compliance binds the Token at init time.
    function _deployMC(string memory salt, TokenDetails calldata tokenDetails, address accessManager)
        private
        returns (address)
    {
        bytes memory code = type(ModularComplianceProxy).creationCode;
        bytes memory constructData = abi.encode(
            _implementationAuthority,
            accessManager,
            _predictAddress(salt, "Token"),
            tokenDetails.complianceModules,
            tokenDetails.complianceSettings
        );
        bytes memory bytecode = abi.encodePacked(code, constructData);
        return _deploy(salt, "MC", bytecode);
    }

    /// function used to deploy an identity registry storage using CREATE3
    function _deployIRS(string memory salt, address accessManager) private returns (address) {
        bytes memory code = type(IdentityRegistryStorageProxy).creationCode;
        bytes memory constructData = abi.encode(_implementationAuthority, accessManager);
        bytes memory bytecode = abi.encodePacked(code, constructData);
        return _deploy(salt, "IRS", bytecode);
    }

    /// function used to deploy an identity registry using CREATE3
    function _deployIR(
        string memory salt,
        address trustedIssuersRegistry,
        address claimTopicsRegistry,
        address identityStorage,
        address accessManager
    ) private returns (address) {
        bytes memory code = type(IdentityRegistryProxy).creationCode;
        bytes memory constructData = abi.encode(
            _implementationAuthority, trustedIssuersRegistry, claimTopicsRegistry, identityStorage, accessManager
        );
        bytes memory bytecode = abi.encodePacked(code, constructData);
        return _deploy(salt, "IR", bytecode);
    }

    /// Resolve the OID (caller-supplied or freshly minted via `IIdFactory.createTokenIdentity` against the Token's
    /// predicted CREATE3 address) and deploy the Token proxy. Asserts the deployed Token's CREATE3 address matches
    /// the prediction reused by the MC + OID wiring.
    function _deployToken(
        string memory salt,
        TokenDetails calldata tokenDetails,
        address identityRegistry,
        address compliance,
        address accessManager
    ) private returns (address) {
        address token = _deploy(
            salt, "Token", _tokenBytecode(salt, tokenDetails, identityRegistry, compliance, accessManager)
        );
        require(token == _predictAddress(salt, "Token"), ErrorsLib.AddressPredictionMismatch());
        return token;
    }

    function _tokenBytecode(
        string memory salt,
        TokenDetails calldata tokenDetails,
        address identityRegistry,
        address compliance,
        address accessManager
    ) private returns (bytes memory) {
        address oid = tokenDetails.ONCHAINID;
        if (oid == address(0)) {
            oid = IIdFactory(_idFactory).createTokenIdentity(_predictAddress(salt, "Token"), tokenDetails.owner, salt);
        }
        return abi.encodePacked(
            type(TokenProxy).creationCode,
            abi.encode(
                _implementationAuthority,
                identityRegistry,
                compliance,
                tokenDetails.name,
                tokenDetails.symbol,
                tokenDetails.decimals,
                oid,
                accessManager
            )
        );
    }

}
