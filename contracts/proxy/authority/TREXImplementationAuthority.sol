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

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AccessManaged, IAccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IERC3643IdentityRegistry } from "../../ERC-3643/IERC3643IdentityRegistry.sol";
import { ITREXFactory } from "../../factory/ITREXFactory.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { RolesLib } from "../../libraries/RolesLib.sol";
import { IERC173 } from "../../roles/IERC173.sol";
import { IToken } from "../../token/IToken.sol";
import { IProxy } from "../interface/IProxy.sol";
import { IIAFactory } from "./IIAFactory.sol";
import { ITREXImplementationAuthority } from "./ITREXImplementationAuthority.sol";

contract TREXImplementationAuthority is ITREXImplementationAuthority, Ownable, AccessManaged, IERC165 {

    /// variables
    /// current version
    Version private _currentVersion;

    /// mapping to get contracts of each version
    mapping(bytes32 => TREXContracts) private _contracts;

    /// reference ImplementationAuthority used by the TREXFactory
    bool private _reference;

    /// address of TREXFactory contract
    address private _trexFactory;

    /// address of factory for TREXImplementationAuthority contracts
    address private _iaFactory;

    /// functions

    /**
     *  @dev Constructor of the ImplementationAuthority contract
     *  @param referenceStatus boolean value determining if the contract
     *  is the main IA or an auxiliary contract
     *  @param trexFactory the address of TREXFactory referencing the main IA
     *  if `referenceStatus` is true then `trexFactory` at deployment is set
     *  on zero address. In that scenario, call `setTREXFactory` post-deployment
     *  @param iaFactory the address for the factory of IA contracts
     *  emits `ImplementationAuthoritySet` event
     *  emits a `IAFactorySet` event
     */
    constructor(bool referenceStatus, address trexFactory, address iaFactory, address accessManager)
        Ownable(accessManager)
        AccessManaged(accessManager)
    {
        _reference = referenceStatus;
        _trexFactory = trexFactory;
        _iaFactory = iaFactory;
        emit EventsLib.ImplementationAuthoritySetWithStatus(referenceStatus, trexFactory);
        emit EventsLib.IAFactorySet(iaFactory);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-setTREXFactory}.
     */
    function setTREXFactory(address trexFactory) external override restricted {
        require(
            isReferenceContract() && ITREXFactory(trexFactory).getImplementationAuthority() == address(this),
            ErrorsLib.OnlyReferenceContractCanCall()
        );
        _trexFactory = trexFactory;
        emit EventsLib.TREXFactorySet(trexFactory);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-setIAFactory}.
     */
    function setIAFactory(address iaFactory) external override restricted {
        require(
            isReferenceContract() && ITREXFactory(_trexFactory).getImplementationAuthority() == address(this),
            ErrorsLib.OnlyReferenceContractCanCall()
        );
        _iaFactory = iaFactory;
        emit EventsLib.IAFactorySet(iaFactory);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-useTREXVersion}.
     */
    function addAndUseTREXVersion(Version calldata _version, TREXContracts calldata _trex)
        external
        override
        restricted
    {
        addTREXVersion(_version, _trex);
        useTREXVersion(_version);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-fetchVersionList}.
     */
    function fetchVersion(Version calldata _version) external override {
        require(!isReferenceContract(), ErrorsLib.CannotCallOnReferenceContract());
        require(
            _contracts[_versionToBytes(_version)].tokenImplementation == address(0), ErrorsLib.VersionAlreadyFetched()
        );

        _contracts[_versionToBytes(_version)] =
            ITREXImplementationAuthority(getReferenceContract()).getContracts(_version);
        emit EventsLib.TREXVersionFetched(_version, _contracts[_versionToBytes(_version)]);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-changeImplementationAuthority}.
     */
    // solhint-disable-next-line code-complexity, function-max-lines
    function changeImplementationAuthority(address token, address newImplementationAuthority) external override {
        require(token != address(0), ErrorsLib.ZeroAddress());
        require(
            newImplementationAuthority != address(0) || isReferenceContract(), ErrorsLib.OnlyReferenceContractCanCall()
        );

        address ir = address(IToken(token).identityRegistry());
        address mc = address(IToken(token).compliance());
        address irs = address(IERC3643IdentityRegistry(ir).identityStorage());
        address ctr = address(IERC3643IdentityRegistry(ir).topicsRegistry());
        address tir = address(IERC3643IdentityRegistry(ir).issuersRegistry());

        // calling this function requires ownership of ALL contracts of the T-REX suite
        require(
            _isOwner(token) && _isOwner(ir) && _isOwner(mc) && _isOwner(irs) && _isOwner(ctr) && _isOwner(tir),
            ErrorsLib.CallerNotOwnerOfAllImpactedContracts()
        );

        if (newImplementationAuthority == address(0)) {
            newImplementationAuthority = IIAFactory(_iaFactory).deployIA(token, authority());
        } else {
            require(
                _versionToBytes(ITREXImplementationAuthority(newImplementationAuthority).getCurrentVersion())
                    == _versionToBytes(_currentVersion),
                ErrorsLib.VersionOfNewIAMustBeTheSameAsCurrentIA()
            );
            require(
                !ITREXImplementationAuthority(newImplementationAuthority).isReferenceContract()
                    || newImplementationAuthority == getReferenceContract(),
                ErrorsLib.NewIAIsNotAReferenceContract()
            );
            require(
                IIAFactory(_iaFactory).deployedByFactory(newImplementationAuthority)
                    || newImplementationAuthority == getReferenceContract(),
                ErrorsLib.InvalidImplementationAuthority()
            );
        }

        IProxy(token).setImplementationAuthority(newImplementationAuthority);
        IProxy(ir).setImplementationAuthority(newImplementationAuthority);
        IProxy(mc).setImplementationAuthority(newImplementationAuthority);
        IProxy(ctr).setImplementationAuthority(newImplementationAuthority);
        IProxy(tir).setImplementationAuthority(newImplementationAuthority);
        // IRS can be shared by multiple tokens, and therefore could have been updated already
        if (IProxy(irs).getImplementationAuthority() == address(this)) {
            IProxy(irs).setImplementationAuthority(newImplementationAuthority);
        }
        emit EventsLib.ImplementationAuthorityChanged(token, newImplementationAuthority);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getCurrentVersion}.
     */
    function getCurrentVersion() external view override returns (Version memory) {
        return _currentVersion;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getContracts}.
     */
    function getContracts(Version calldata _version) external view override returns (TREXContracts memory) {
        return _contracts[_versionToBytes(_version)];
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getTREXFactory}.
     */
    function getTREXFactory() external view override returns (address) {
        return _trexFactory;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getTokenImplementation}.
     */
    function getTokenImplementation() external view override returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].tokenImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getCTRImplementation}.
     */
    function getCTRImplementation() external view override returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].ctrImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getIRImplementation}.
     */
    function getIRImplementation() external view override returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].irImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getIRSImplementation}.
     */
    function getIRSImplementation() external view override returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].irsImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getTIRImplementation}.
     */
    function getTIRImplementation() external view override returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].tirImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getMCImplementation}.
     */
    function getMCImplementation() external view override returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].mcImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-addTREXVersion}.
     */
    function addTREXVersion(Version calldata _version, TREXContracts calldata _trex) public override restricted {
        require(isReferenceContract(), ErrorsLib.OnlyReferenceContractCanCall());
        require(
            _contracts[_versionToBytes(_version)].tokenImplementation == address(0), ErrorsLib.VersionAlreadyExists()
        );

        require(
            _trex.ctrImplementation != address(0) && _trex.irImplementation != address(0)
                && _trex.irsImplementation != address(0) && _trex.mcImplementation != address(0)
                && _trex.tirImplementation != address(0) && _trex.tokenImplementation != address(0),
            ErrorsLib.ZeroAddress()
        );

        _contracts[_versionToBytes(_version)] = _trex;
        emit EventsLib.TREXVersionAdded(_version, _trex);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-useTREXVersion}.
     */
    function useTREXVersion(Version calldata _version) public override restricted {
        require(_versionToBytes(_version) != _versionToBytes(_currentVersion), ErrorsLib.VersionAlreadyInUse());
        require(_contracts[_versionToBytes(_version)].tokenImplementation != address(0), ErrorsLib.NonExistingVersion());

        _currentVersion = _version;
        emit EventsLib.VersionUpdated(_version);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-isReferenceContract}.
     */
    function isReferenceContract() public view override returns (bool) {
        return _reference;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getReferenceContract}.
     */
    function getReferenceContract() public view override returns (address) {
        return ITREXFactory(_trexFactory).getImplementationAuthority();
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(ITREXImplementationAuthority).interfaceId || interfaceId == type(IERC173).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /**
     *  @dev casting function Version => bytes to allow compare values easier
     */
    function _versionToBytes(Version memory _version) private pure returns (bytes32) {
        return bytes32(keccak256(abi.encodePacked(_version.major, _version.minor, _version.patch)));
    }

    function _isOwner(address _contract) private view returns (bool) {
        (bool isOwner,) = IAccessManager(IAccessManaged(_contract).authority()).hasRole(RolesLib.OWNER, msg.sender);
        return isOwner;
    }

}
