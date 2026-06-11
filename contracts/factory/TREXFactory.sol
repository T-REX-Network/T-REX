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

import { IIdFactory } from "@onchain-id/solidity/contracts/factory/IIdFactory.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

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
     */
    function deployTREXSuite(string memory salt, TokenDetails calldata tokenDetails, ClaimDetails calldata claimDetails)
        external
        restricted
    {
        require(tokenDeployed[salt] == address(0), ErrorsLib.TokenAlreadyDeployed());

        require(tokenDetails.accessManager != address(0), ErrorsLib.ZeroAddress());
        require(claimDetails.issuers.length <= 5, ErrorsLib.MaxClaimIssuersReached(5));
        require(claimDetails.claimTopics.length <= 5, ErrorsLib.MaxClaimTopicsReached(5));
        require(
            tokenDetails.irAgents.length <= 5 && tokenDetails.tokenAgents.length <= 5, ErrorsLib.MaxAgentsReached(5)
        );
        require(tokenDetails.complianceModules.length <= 25, ErrorsLib.MaxModulesReached(25));

        address tir = _deployTIR(salt, tokenDetails.accessManager, claimDetails.issuers, claimDetails.issuerClaims);
        address ctr = _deployCTR(salt, tokenDetails.accessManager, claimDetails.claimTopics);

        address irs = tokenDetails.irs;
        if (irs == address(0)) {
            irs = _deployIRS(salt, tokenDetails);
        }

        address ir = _deployIR(salt, tokenDetails, tir, ctr, irs);
        require(ir == _predictAddress(salt, "IR"), ErrorsLib.AddressPredictionMismatch());
        address mc = _deployMC(salt, tokenDetails);

        // a reused IRS must be governed by the same AccessManager as the rest of the suite
        if (tokenDetails.irs != address(0)) {
            require(IAccessManaged(irs).authority() == tokenDetails.accessManager, ErrorsLib.AuthorityMismatch());
            IIdentityRegistryStorage(irs).bindIdentityRegistry(ir);
        }

        address token = _deployToken(salt, tokenDetails, ir, mc);
        tokenDeployed[salt] = token;

        _grantAgentRoles(tokenDetails, token, ir);

        emit EventsLib.TREXSuiteDeployed(token, ir, irs, tir, ctr, mc, salt);
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
        // should not be possible to set an implementation authority that is not complete
        require(
            (ITREXImplementationAuthority(implementationAuthorityAddress)).getTokenImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthorityAddress)).getCTRImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthorityAddress)).getIRImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthorityAddress)).getIRSImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthorityAddress)).getMCImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthorityAddress)).getTIRImplementation() != address(0),
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
     * @dev Deploys a contract using CREATE3
     * @param salt Base salt for deployment
     * @param contractType Contract type identifier (e.g., "TIR", "CTR")
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
     *      The contractType discriminator prevents the 6 suite contracts from colliding on a single CREATE3 slot
     *      (they all share the user-provided salt).
     */
    function _saltBytes(string memory salt, string memory contractType) private view returns (bytes32) {
        return bytes20(address(this)) | keccak256(bytes(string.concat(salt, contractType))) >> 168;
    }

    /// function used to deploy a trusted issuers registry using CREATE3
    function _deployTIR(
        string memory salt,
        address accessManagerAddress,
        address[] memory issuers,
        uint256[][] memory issuerClaims
    ) private returns (address) {
        return _deploy(
            salt,
            "TIR",
            bytes.concat(
                type(TrustedIssuersRegistryProxy).creationCode,
                abi.encode(_implementationAuthority, accessManagerAddress, issuers, issuerClaims)
            )
        );
    }

    /// function used to deploy a claim topics registry using CREATE3
    function _deployCTR(string memory salt, address accessManagerAddress, uint256[] memory initialTopics)
        private
        returns (address)
    {
        return _deploy(
            salt,
            "CTR",
            bytes.concat(
                type(ClaimTopicsRegistryProxy).creationCode,
                abi.encode(_implementationAuthority, accessManagerAddress, initialTopics)
            )
        );
    }

    /// function used to deploy modular compliance contract using CREATE3
    function _deployMC(string memory salt, TokenDetails calldata tokenDetails) private returns (address) {
        return _deploy(
            salt,
            "MC",
            bytes.concat(
                type(ModularComplianceProxy).creationCode,
                abi.encode(
                    _implementationAuthority,
                    _predictAddress(salt, "Token"),
                    tokenDetails.accessManager,
                    tokenDetails.complianceModules,
                    tokenDetails.complianceSettings
                )
            )
        );
    }

    function _deployIRS(string memory salt, TokenDetails calldata tokenDetails) private returns (address) {
        return _deploy(
            salt,
            "IRS",
            bytes.concat(
                type(IdentityRegistryStorageProxy).creationCode,
                abi.encode(_implementationAuthority, tokenDetails.accessManager, _predictAddress(salt, "IR"))
            )
        );
    }

    /// function used to deploy an identity registry using CREATE3
    function _deployIR(
        string memory salt,
        TokenDetails calldata tokenDetails,
        address trustedIssuersRegistry,
        address claimTopicsRegistry,
        address identityStorage
    ) private returns (address) {
        return _deploy(
            salt,
            "IR",
            bytes.concat(
                type(IdentityRegistryProxy).creationCode,
                abi.encode(
                    _implementationAuthority,
                    trustedIssuersRegistry,
                    claimTopicsRegistry,
                    identityStorage,
                    tokenDetails.accessManager
                )
            )
        );
    }

    /// Resolves the OID (caller-supplied or minted via `IIdFactory.createTokenIdentity` against the
    /// Token's predicted CREATE3 address) and deploys the Token proxy. Asserts the deployed Token's
    /// CREATE3 address matches the prediction used by the MC + OID wiring.
    function _deployToken(
        string memory salt,
        TokenDetails calldata tokenDetails,
        address identityRegistry,
        address compliance
    ) private returns (address) {
        address predictedToken = _predictAddress(salt, "Token");
        address oid = tokenDetails.ONCHAINID;
        if (oid == address(0)) {
            oid = IIdFactory(_idFactory).createTokenIdentity(predictedToken, tokenDetails.accessManager, salt);
        }
        address token = _deploy(salt, "Token", _tokenBytecode(tokenDetails, identityRegistry, compliance, oid));
        require(token == predictedToken, ErrorsLib.AddressPredictionMismatch());
        return token;
    }

    function _tokenBytecode(
        TokenDetails calldata tokenDetails,
        address identityRegistry,
        address compliance,
        address oid
    ) private view returns (bytes memory) {
        return bytes.concat(
            type(TokenProxy).creationCode,
            abi.encode(
                _implementationAuthority,
                identityRegistry,
                compliance,
                tokenDetails.name,
                tokenDetails.symbol,
                tokenDetails.decimals,
                oid,
                tokenDetails.accessManager
            )
        );
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
