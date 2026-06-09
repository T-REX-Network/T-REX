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

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
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

contract TREXFactory is ITREXFactory, Ownable {

    /// the address of the implementation authority contract used in the tokens deployed by the factory
    address private _implementationAuthority;

    /// the address of the Identity Factory used to deploy token OIDs
    address private _idFactory;

    /// mapping containing info about the token contracts corresponding to salt already used for CREATE3 deployments
    mapping(string => address) public tokenDeployed;

    /// constructor is setting the implementation authority and the Identity Factory of the TREX factory
    constructor(address implementationAuthority_, address idFactory_) Ownable(msg.sender) {
        setImplementationAuthority(implementationAuthority_);
        setIdFactory(idFactory_);
    }

    /**
     *  @dev See {ITREXFactory-deployTREXSuite}.
     */
    // solhint-disable-next-line code-complexity, function-max-lines
    function deployTREXSuite(
        string memory _salt,
        TokenDetails calldata _tokenDetails,
        ClaimDetails calldata _claimDetails
    ) external onlyOwner {
        require(tokenDeployed[_salt] == address(0), ErrorsLib.TokenAlreadyDeployed());
        require(_claimDetails.issuers.length == _claimDetails.issuerClaims.length, ErrorsLib.InvalidClaimPattern());
        require(_claimDetails.issuers.length <= 5, ErrorsLib.MaxClaimIssuersReached(5));
        require(_claimDetails.claimTopics.length <= 5, ErrorsLib.MaxClaimTopicsReached(5));
        require(
            _tokenDetails.irAgents.length <= 5 && _tokenDetails.tokenAgents.length <= 5, ErrorsLib.MaxAgentsReached(5)
        );
        require(_tokenDetails.complianceModules.length <= 25, ErrorsLib.MaxModulesReached(25));
        require(
            _tokenDetails.complianceModules.length >= _tokenDetails.complianceSettings.length,
            ErrorsLib.InvalidCompliancePattern()
        );

        address tir = _deployTIR(
            _salt, _implementationAuthority, _tokenDetails.owner, _claimDetails.issuers, _claimDetails.issuerClaims
        );
        address ctr = _deployCTR(_salt, _implementationAuthority, _tokenDetails.owner, _claimDetails.claimTopics);

        address irs = _tokenDetails.irs;
        if (irs == address(0)) {
            irs = _deployIRS(_salt, _tokenDetails);
        }

        address ir = _deployIR(_salt, _tokenDetails, tir, ctr, irs);
        require(ir == _predictAddress(_salt, "IR"), ErrorsLib.AddressPredictionMismatch());
        address mc = _deployMC(_salt, _tokenDetails);

        // For a freshly-deployed IRS, the binding is folded into init; for a reused IRS, the binding is
        // still applied here (the factory must be owner of the reused IRS, same precondition as before
        // the refactor).
        if (_tokenDetails.irs != address(0)) {
            IIdentityRegistryStorage(irs).bindIdentityRegistry(ir);
        }

        address token = _deployToken(_salt, _tokenDetails, ir, mc);
        tokenDeployed[_salt] = token;

        emit EventsLib.TREXSuiteDeployed(token, ir, irs, tir, ctr, mc, _salt);
    }

    /**
     *  @dev See {ITREXFactory-recoverContractOwnership}.
     */
    function recoverContractOwnership(address _contract, address _newOwner) external onlyOwner {
        (Ownable(_contract)).transferOwnership(_newOwner);
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
    function getToken(string calldata _salt) external view returns (address) {
        return tokenDeployed[_salt];
    }

    /**
     *  @dev See {ITREXFactory-setImplementationAuthority}.
     */
    function setImplementationAuthority(address implementationAuthority_) public onlyOwner {
        require(implementationAuthority_ != address(0), ErrorsLib.ZeroAddress());
        // should not be possible to set an implementation authority that is not complete
        require(
            (ITREXImplementationAuthority(implementationAuthority_)).getTokenImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority_)).getCTRImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority_)).getIRImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority_)).getIRSImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority_)).getMCImplementation() != address(0)
                && (ITREXImplementationAuthority(implementationAuthority_)).getTIRImplementation() != address(0),
            ErrorsLib.InvalidImplementationAuthority()
        );
        _implementationAuthority = implementationAuthority_;
        emit EventsLib.ImplementationAuthoritySet(implementationAuthority_);
    }

    /**
     *  @dev See {ITREXFactory-setIdFactory}.
     */
    function setIdFactory(address idFactory_) public onlyOwner {
        require(idFactory_ != address(0), ErrorsLib.ZeroAddress());
        _idFactory = idFactory_;
        emit EventsLib.IdFactorySet(idFactory_);
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
        return bytes32(
            abi.encodePacked(address(this), bytes1(0x00), bytes11(keccak256(abi.encodePacked(salt, contractType))))
        );
    }

    /// function used to deploy a trusted issuers registry using CREATE3
    function _deployTIR(
        string memory _salt,
        address implementationAuthority_,
        address _owner,
        address[] memory _issuers,
        uint256[][] memory _issuerClaims
    ) private returns (address) {
        bytes memory _code = type(TrustedIssuersRegistryProxy).creationCode;
        bytes memory _constructData = abi.encode(implementationAuthority_, _owner, _issuers, _issuerClaims);
        bytes memory bytecode = abi.encodePacked(_code, _constructData);
        return _deploy(_salt, "TIR", bytecode);
    }

    /// function used to deploy a claim topics registry using CREATE3
    function _deployCTR(
        string memory _salt,
        address implementationAuthority_,
        address _owner,
        uint256[] memory _initialTopics
    ) private returns (address) {
        bytes memory _code = type(ClaimTopicsRegistryProxy).creationCode;
        bytes memory _constructData = abi.encode(implementationAuthority_, _owner, _initialTopics);
        bytes memory bytecode = abi.encodePacked(_code, _constructData);
        return _deploy(_salt, "CTR", bytecode);
    }

    /// function used to deploy modular compliance contract using CREATE3
    function _deployMC(string memory _salt, TokenDetails calldata _tokenDetails) private returns (address) {
        bytes memory _code = type(ModularComplianceProxy).creationCode;
        bytes memory _constructData = abi.encode(
            _implementationAuthority,
            _predictAddress(_salt, "Token"),
            _tokenDetails.owner,
            _tokenDetails.complianceModules,
            _tokenDetails.complianceSettings
        );
        bytes memory bytecode = abi.encodePacked(_code, _constructData);
        return _deploy(_salt, "MC", bytecode);
    }

    function _deployIRS(string memory _salt, TokenDetails calldata _tokenDetails) private returns (address) {
        bytes memory _code = type(IdentityRegistryStorageProxy).creationCode;
        bytes memory _constructData =
            abi.encode(_implementationAuthority, _tokenDetails.owner, _predictAddress(_salt, "IR"));
        bytes memory bytecode = abi.encodePacked(_code, _constructData);
        return _deploy(_salt, "IRS", bytecode);
    }

    /// Deploy the IR with the Token's predicted CREATE3 address baked in so the IR grants the agent
    /// role to the Token at init time, and the factory never needs to call `addAgent` post-deploy.
    function _deployIR(
        string memory _salt,
        TokenDetails calldata _tokenDetails,
        address _trustedIssuersRegistry,
        address _claimTopicsRegistry,
        address _identityStorage
    ) private returns (address) {
        bytes memory _code = type(IdentityRegistryProxy).creationCode;
        bytes memory _constructData = abi.encode(
            _implementationAuthority,
            _trustedIssuersRegistry,
            _claimTopicsRegistry,
            _identityStorage,
            _tokenDetails.owner,
            _tokenDetails.irAgents,
            _predictAddress(_salt, "Token")
        );
        bytes memory bytecode = abi.encodePacked(_code, _constructData);
        return _deploy(_salt, "IR", bytecode);
    }

    /// Resolve the OID (caller-supplied or freshly minted via `IIdFactory.createTokenIdentity` against
    /// the Token's predicted CREATE3 address) and deploy the Token proxy whose `init` carries the final
    /// owner, configured agents and the resolved OID. Asserts the deployed Token's CREATE3 address
    /// matches the prediction reused by the IR + MC + OID wiring.
    function _deployToken(
        string memory _salt,
        TokenDetails calldata _tokenDetails,
        address _identityRegistry,
        address _compliance
    ) private returns (address) {
        address predictedToken = _predictAddress(_salt, "Token");
        address oid = _tokenDetails.ONCHAINID;
        if (oid == address(0)) {
            oid = IIdFactory(_idFactory).createTokenIdentity(predictedToken, _tokenDetails.owner, _salt);
        }
        address token = _deploy(_salt, "Token", _tokenBytecode(_tokenDetails, _identityRegistry, _compliance, oid));
        require(token == predictedToken, ErrorsLib.AddressPredictionMismatch());
        return token;
    }

    function _tokenBytecode(
        TokenDetails calldata _tokenDetails,
        address _identityRegistry,
        address _compliance,
        address _oid
    ) private view returns (bytes memory) {
        return abi.encodePacked(
            type(TokenProxy).creationCode,
            abi.encode(
                _implementationAuthority,
                _identityRegistry,
                _compliance,
                _tokenDetails.name,
                _tokenDetails.symbol,
                _tokenDetails.decimals,
                _oid,
                _tokenDetails.owner,
                _tokenDetails.tokenAgents
            )
        );
    }

}
