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

import { IERC3643 } from "../../ERC-3643/IERC3643.sol";
import { IERC3643IdentityRegistry } from "../../ERC-3643/IERC3643IdentityRegistry.sol";
import { ITREXFactory } from "../../factory/ITREXFactory.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { AccessManagedOwnable } from "../../utils/AccessManagedOwnable.sol";
import { IProxy } from "../interface/IProxy.sol";
import { IIAFactory } from "./IIAFactory.sol";
import { ITREXImplementationAuthority } from "./ITREXImplementationAuthority.sol";

contract TREXImplementationAuthority is ITREXImplementationAuthority, AccessManagedOwnable {

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

    /**
     *  @dev Constructor of the ImplementationAuthority contract
     *  @param referenceStatus boolean value determining if the contract
     *  is the main IA or an auxiliary contract
     *  @param trexFactory the address of TREXFactory referencing the main IA
     *  if `referenceStatus` is true then `trexFactory` at deployment is set
     *  on zero address. In that scenario, call `setTREXFactory` post-deployment
     *  @param iaFactory the address for the factory of IA contracts
     *  @param accessManager the AccessManager governing the restricted functions
     *  emits `ImplementationAuthoritySet` event
     *  emits a `IAFactorySet` event
     */
    constructor(bool referenceStatus, address trexFactory, address iaFactory, address accessManager)
        AccessManagedOwnable(accessManager)
    {
        require(accessManager != address(0), ErrorsLib.ZeroAddress());

        _reference = referenceStatus;
        _trexFactory = trexFactory;
        _iaFactory = iaFactory;
        emit EventsLib.ImplementationAuthoritySetWithStatus(referenceStatus, trexFactory);
        emit EventsLib.IAFactorySet(iaFactory);

        // Auxiliary contracts pin the reference contract's current version at deployment,
        // so the version is set without an external (restricted) call from the IAFactory.
        if (!referenceStatus) {
            Version memory version = ITREXImplementationAuthority(getReferenceContract()).getCurrentVersion();
            _fetchVersion(version);
            _useTREXVersion(version);
        }
    }

    /**
     *  @dev See {ITREXImplementationAuthority-setTREXFactory}.
     */
    function setTREXFactory(address trexFactory) external restricted {
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
    function setIAFactory(address iaFactory) external restricted {
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
    function addAndUseTREXVersion(Version calldata _version, TREXContracts calldata _trex) external restricted {
        _addTREXVersion(_version, _trex);
        _useTREXVersion(_version);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-fetchVersion}.
     */
    function fetchVersion(Version calldata _version) external {
        _fetchVersion(_version);
    }

    function _fetchVersion(Version memory version) internal {
        require(!isReferenceContract(), ErrorsLib.CannotCallOnReferenceContract());

        bytes32 bVersion = _versionToBytes(version);
        require(_contracts[bVersion].tokenImplementation == address(0), ErrorsLib.VersionAlreadyFetched());

        _contracts[bVersion] = ITREXImplementationAuthority(getReferenceContract()).getContracts(version);

        emit EventsLib.TREXVersionFetched(version, _contracts[bVersion]);
        emit EventsLib.TREXRegistryImplementationSet(_contracts[bVersion].trexRegistryImplementation);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-changeImplementationAuthority}.
     *  Restricted to the configured AccessManager role.
     */
    function changeImplementationAuthority(address _token, address _newImplementationAuthority) external restricted {
        require(_token != address(0), ErrorsLib.ZeroAddress());
        require(
            _newImplementationAuthority != address(0) || isReferenceContract(), ErrorsLib.OnlyReferenceContractCanCall()
        );

        address _ir = address(IERC3643(_token).identityRegistry());
        address _mc = address(IERC3643(_token).compliance());
        address _irs = address(IERC3643IdentityRegistry(_ir).identityStorage());

        if (_newImplementationAuthority == address(0)) {
            _newImplementationAuthority = IIAFactory(_iaFactory).deployIA(_token);
        } else {
            require(
                _versionToBytes(ITREXImplementationAuthority(_newImplementationAuthority).getCurrentVersion())
                    == _versionToBytes(_currentVersion),
                ErrorsLib.VersionOfNewIAMustBeTheSameAsCurrentIA()
            );
            require(
                !ITREXImplementationAuthority(_newImplementationAuthority).isReferenceContract()
                    || _newImplementationAuthority == getReferenceContract(),
                ErrorsLib.NewIAIsNotAReferenceContract()
            );
            require(
                IIAFactory(_iaFactory).deployedByFactory(_newImplementationAuthority)
                    || _newImplementationAuthority == getReferenceContract(),
                ErrorsLib.InvalidImplementationAuthority()
            );
        }

        IProxy(_token).setImplementationAuthority(_newImplementationAuthority);
        IProxy(_ir).setImplementationAuthority(_newImplementationAuthority);
        IProxy(_mc).setImplementationAuthority(_newImplementationAuthority);
        // IRS can be shared by multiple tokens, and therefore could have been updated already
        if (IProxy(_irs).getImplementationAuthority() == address(this)) {
            IProxy(_irs).setImplementationAuthority(_newImplementationAuthority);
        }
        emit EventsLib.ImplementationAuthorityChanged(_token, _newImplementationAuthority);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getCurrentVersion}.
     */
    function getCurrentVersion() external view returns (Version memory) {
        return _currentVersion;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getContracts}.
     */
    function getContracts(Version calldata _version) external view returns (TREXContracts memory) {
        return _contracts[_versionToBytes(_version)];
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getTREXFactory}.
     */
    function getTREXFactory() external view returns (address) {
        return _trexFactory;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getTokenImplementation}.
     */
    function getTokenImplementation() external view returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].tokenImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getIRSImplementation}.
     */
    function getIRSImplementation() external view returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].irsImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getMCImplementation}.
     */
    function getMCImplementation() external view returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].mcImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getTREXRegistryImplementation}.
     */
    function getTREXRegistryImplementation() external view returns (address) {
        return _contracts[_versionToBytes(_currentVersion)].trexRegistryImplementation;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-addTREXVersion}.
     */
    function addTREXVersion(Version calldata _version, TREXContracts calldata _trex) public restricted {
        _addTREXVersion(_version, _trex);
    }

    function _addTREXVersion(Version calldata _version, TREXContracts calldata _trex) internal {
        require(isReferenceContract(), ErrorsLib.OnlyReferenceContractCanCall());
        require(
            _contracts[_versionToBytes(_version)].tokenImplementation == address(0), ErrorsLib.VersionAlreadyExists()
        );

        require(
            _trex.tokenImplementation != address(0) && _trex.irsImplementation != address(0)
                && _trex.mcImplementation != address(0) && _trex.trexRegistryImplementation != address(0),
            ErrorsLib.ZeroAddress()
        );

        _contracts[_versionToBytes(_version)] = _trex;
        emit EventsLib.TREXVersionAdded(_version, _trex);
        emit EventsLib.TREXRegistryImplementationSet(_trex.trexRegistryImplementation);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-useTREXVersion}.
     */
    function useTREXVersion(Version calldata _version) public restricted {
        _useTREXVersion(_version);
    }

    function _useTREXVersion(Version memory _version) internal {
        require(_versionToBytes(_version) != _versionToBytes(_currentVersion), ErrorsLib.VersionAlreadyInUse());
        require(_contracts[_versionToBytes(_version)].tokenImplementation != address(0), ErrorsLib.NonExistingVersion());

        _currentVersion = _version;
        emit EventsLib.VersionUpdated(_version);
    }

    /**
     *  @dev See {ITREXImplementationAuthority-isReferenceContract}.
     */
    function isReferenceContract() public view returns (bool) {
        return _reference;
    }

    /**
     *  @dev See {ITREXImplementationAuthority-getReferenceContract}.
     */
    function getReferenceContract() public view returns (address) {
        return ITREXFactory(_trexFactory).getImplementationAuthority();
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ITREXImplementationAuthority).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     *  @dev casting function Version => bytes to allow compare values easier
     */
    function _versionToBytes(Version memory _version) private pure returns (bytes32) {
        return bytes32(keccak256(abi.encodePacked(_version.major, _version.minor, _version.patch)));
    }

}
