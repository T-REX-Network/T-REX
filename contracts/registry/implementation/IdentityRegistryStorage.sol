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

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ERC3643EventsLib } from "../../ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { AgentRoleUpgradeable } from "../../roles/AgentRoleUpgradeable.sol";
import { IERC173 } from "../../roles/IERC173.sol";
import { IERC3643IdentityRegistryStorage, IIdentityRegistryStorage } from "../interface/IIdentityRegistryStorage.sol";

contract IdentityRegistryStorage is IIdentityRegistryStorage, AgentRoleUpgradeable, IERC165 {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev struct containing the identity contract and the country of the user
    struct Identity {
        IIdentity identityContract;
        uint16 investorCountry;
    }

    /// @custom:storage-location erc7201:ERC3643.storage.IdentityRegistryStorage
    struct Storage {
        /// @dev mapping between a user address and the corresponding identity
        mapping(address user => Identity) identities;

        /// @dev set of Identity Registries linked to this storage
        EnumerableSet.AddressSet identityRegistries;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.IdentityRegistryStorage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0x6d25db4721129739b3a7e96c2537b7170fb9cfd72348ce376c7a189a3ab3ba00;

    constructor() {
        _disableInitializers();
    }

    function init(address _owner, address _initialIR) external initializer {
        __Ownable_init(_owner);
        if (_initialIR != address(0)) {
            _bindIdentityRegistry(_initialIR);
        }
    }

    /**
     *  @dev See {IIdentityRegistryStorage-addIdentityToStorage}.
     */
    function addIdentityToStorage(address _userAddress, IIdentity _identity, uint16 _country)
        external
        override
        onlyAgent
    {
        require(_userAddress != address(0) && address(_identity) != address(0), ErrorsLib.ZeroAddress());

        Storage storage s = _getStorage();
        require(address(s.identities[_userAddress].identityContract) == address(0), ErrorsLib.AddressAlreadyStored());
        s.identities[_userAddress].identityContract = _identity;
        s.identities[_userAddress].investorCountry = _country;
        emit ERC3643EventsLib.IdentityStored(_userAddress, _identity);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-modifyStoredIdentity}.
     */
    function modifyStoredIdentity(address _userAddress, IIdentity _identity) external override onlyAgent {
        require(_userAddress != address(0) && address(_identity) != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(address(s.identities[_userAddress].identityContract) != address(0), ErrorsLib.AddressNotYetStored());
        IIdentity oldIdentity = s.identities[_userAddress].identityContract;
        s.identities[_userAddress].identityContract = _identity;
        emit ERC3643EventsLib.IdentityModified(oldIdentity, _identity);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-modifyStoredInvestorCountry}.
     */
    function modifyStoredInvestorCountry(address _userAddress, uint16 _country) external override onlyAgent {
        require(_userAddress != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(address(s.identities[_userAddress].identityContract) != address(0), ErrorsLib.AddressNotYetStored());
        s.identities[_userAddress].investorCountry = _country;
        emit ERC3643EventsLib.CountryModified(_userAddress, _country);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-removeIdentityFromStorage}.
     */
    function removeIdentityFromStorage(address _userAddress) external override onlyAgent {
        require(_userAddress != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(address(s.identities[_userAddress].identityContract) != address(0), ErrorsLib.AddressNotYetStored());
        IIdentity oldIdentity = s.identities[_userAddress].identityContract;
        delete s.identities[_userAddress];
        emit ERC3643EventsLib.IdentityUnstored(_userAddress, oldIdentity);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-bindIdentityRegistry}.
     */
    function bindIdentityRegistry(address _identityRegistry) external override onlyOwner {
        _bindIdentityRegistry(_identityRegistry);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-unbindIdentityRegistry}.
     */
    function unbindIdentityRegistry(address _identityRegistry) external override onlyOwner {
        require(_identityRegistry != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(s.identityRegistries.remove(_identityRegistry), ErrorsLib.IdentityRegistryNotStored());

        removeAgent(_identityRegistry);
        emit ERC3643EventsLib.IdentityRegistryUnbound(_identityRegistry);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-linkedIdentityRegistries}.
     */
    function linkedIdentityRegistries() external view override returns (address[] memory) {
        return _getStorage().identityRegistries.values();
    }

    /**
     *  @dev See {IIdentityRegistryStorage-storedIdentity}.
     */
    function storedIdentity(address _userAddress) external view override returns (IIdentity) {
        return _getStorage().identities[_userAddress].identityContract;
    }

    /**
     *  @dev See {IIdentityRegistryStorage-storedInvestorCountry}.
     */
    function storedInvestorCountry(address _userAddress) external view override returns (uint16) {
        return _getStorage().identities[_userAddress].investorCountry;
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IERC3643IdentityRegistryStorage).interfaceId
            || interfaceId == type(IERC173).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Internal helper shared between the public `bindIdentityRegistry` (gated by `onlyOwner`) and the
    ///      `init` flow where the factory pre-binds the identity registry it predicted via CREATE3.
    function _bindIdentityRegistry(address _identityRegistry) internal {
        require(_identityRegistry != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(s.identityRegistries.length() < 300, ErrorsLib.MaxIRByIRSReached(300));
        _addAgent(_identityRegistry);
        s.identityRegistries.add(_identityRegistry);
        emit ERC3643EventsLib.IdentityRegistryBound(_identityRegistry);
    }

    function _getStorage() internal pure returns (Storage storage s) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := STORAGE_LOCATION
        }
    }

}
