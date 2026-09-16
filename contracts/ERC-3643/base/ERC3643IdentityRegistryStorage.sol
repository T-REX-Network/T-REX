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
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ERC3643ErrorsLib } from "../ERC3643ErrorsLib.sol";
import { IERC3643IdentityRegistryStorage } from "../IERC3643IdentityRegistryStorage.sol";

/// @title ERC3643IdentityRegistryStorage
/// @notice Standard-only base implementing the ERC-3643 Identity Registry Storage surface.
/// @dev Layer 2 of the ERC-3643 / T-REX split (see issue #65). Implements exactly the functions
///  `IERC3643IdentityRegistryStorage` declares, over state held in its own ERC-7201 namespace.
///
///  Identity and country are stored together in one struct because every read of one is, in practice,
///  accompanied by a read of the other, and both are written in the same call at registration.
///
///  Extension happens through the internal hooks. Authorization is left to the two `_authorize*` hooks
///  because the standard specifies no access-control model, and binding is separated from identity
///  writes because the two are governed by different roles in every deployment we know of.
abstract contract ERC3643IdentityRegistryStorage is IERC3643IdentityRegistryStorage {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Bound-registry cap. Each bound registry may write identities, so the set is kept small
    ///  enough that enumerating it stays affordable.
    uint256 internal constant MAX_IDENTITY_REGISTRIES = 300;

    /// @dev The identity contract and country of a stored investor.
    struct StoredIdentity {
        IIdentity identityContract;
        uint16 investorCountry;
    }

    /// @custom:storage-location erc7201:erc3643.storage.IdentityRegistryStorage
    struct ERC3643IdentityRegistryStorageStorage {
        /// @dev Investor wallet to its stored identity record.
        mapping(address user => StoredIdentity) identities;

        /// @dev Identity Registries allowed to write to this storage.
        EnumerableSet.AddressSet identityRegistries;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.IdentityRegistryStorage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant IDENTITY_REGISTRY_STORAGE_STORAGE_LOCATION =
        0x8e8aa323647c3f2580137bf922482bdf62534082dec9617ddb5e7739bad03900;

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function addIdentityToStorage(address _userAddress, IIdentity _identity, uint16 _country) external virtual {
        _authorizeIdentityWrite();
        _addIdentityToStorage(_userAddress, _identity, _country);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function modifyStoredIdentity(address _userAddress, IIdentity _identity) external virtual {
        _authorizeIdentityWrite();
        _modifyStoredIdentity(_userAddress, _identity);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function modifyStoredInvestorCountry(address _userAddress, uint16 _country) external virtual {
        _authorizeIdentityWrite();
        _modifyStoredInvestorCountry(_userAddress, _country);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function removeIdentityFromStorage(address _userAddress) external virtual {
        _authorizeIdentityWrite();
        _removeIdentityFromStorage(_userAddress);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function bindIdentityRegistry(address _identityRegistry) external virtual {
        _authorizeRegistryBinding(_identityRegistry);
        _bindIdentityRegistry(_identityRegistry);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function unbindIdentityRegistry(address _identityRegistry) external virtual {
        _authorizeRegistryBinding(_identityRegistry);
        _unbindIdentityRegistry(_identityRegistry);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function linkedIdentityRegistries() external view virtual returns (address[] memory) {
        return _erc3643IdentityRegistryStorageStorage().identityRegistries.values();
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function storedIdentity(address _userAddress) external view virtual returns (IIdentity) {
        return _storedIdentity(_userAddress);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function storedInvestorCountry(address _userAddress) external view virtual returns (uint16) {
        return _storedInvestorCountry(_userAddress);
    }

    /// @dev Authorization hook for the identity-writing functions. Left abstract on purpose.
    function _authorizeIdentityWrite() internal virtual;

    /// @dev Authorization hook for binding and unbinding registries. Receives the registry address so
    ///  derived contracts can apply per-target checks (a shared authority, for instance).
    function _authorizeRegistryBinding(address identityRegistry) internal virtual;

    /// @dev Stores an identity and country for a wallet that has none yet.
    function _addIdentityToStorage(address userAddress, IIdentity userIdentity, uint16 country) internal virtual {
        require(userAddress != address(0) && address(userIdentity) != address(0), ERC3643ErrorsLib.ZeroAddress());

        ERC3643IdentityRegistryStorageStorage storage s = _erc3643IdentityRegistryStorageStorage();
        require(
            address(s.identities[userAddress].identityContract) == address(0), ERC3643ErrorsLib.AddressAlreadyStored()
        );
        s.identities[userAddress].identityContract = userIdentity;
        s.identities[userAddress].investorCountry = country;
        emit IdentityStored(userAddress, userIdentity);
        // The standard store event omits the country; emit the same event `modifyStoredInvestorCountry` uses.
        emit CountryModified(userAddress, country);
    }

    /// @dev Replaces the identity contract of an already-stored wallet.
    function _modifyStoredIdentity(address userAddress, IIdentity userIdentity) internal virtual {
        require(userAddress != address(0) && address(userIdentity) != address(0), ERC3643ErrorsLib.ZeroAddress());
        ERC3643IdentityRegistryStorageStorage storage s = _erc3643IdentityRegistryStorageStorage();
        IIdentity oldIdentity = s.identities[userAddress].identityContract;
        require(address(oldIdentity) != address(0), ERC3643ErrorsLib.AddressNotYetStored());
        s.identities[userAddress].identityContract = userIdentity;
        emit IdentityModified(oldIdentity, userIdentity);
    }

    /// @dev Replaces the country of an already-stored wallet.
    function _modifyStoredInvestorCountry(address userAddress, uint16 country) internal virtual {
        require(userAddress != address(0), ERC3643ErrorsLib.ZeroAddress());
        ERC3643IdentityRegistryStorageStorage storage s = _erc3643IdentityRegistryStorageStorage();
        require(
            address(s.identities[userAddress].identityContract) != address(0), ERC3643ErrorsLib.AddressNotYetStored()
        );
        s.identities[userAddress].investorCountry = country;
        emit CountryModified(userAddress, country);
    }

    /// @dev Deletes a wallet's stored identity record.
    function _removeIdentityFromStorage(address userAddress) internal virtual {
        require(userAddress != address(0), ERC3643ErrorsLib.ZeroAddress());
        ERC3643IdentityRegistryStorageStorage storage s = _erc3643IdentityRegistryStorageStorage();
        IIdentity oldIdentity = s.identities[userAddress].identityContract;
        require(address(oldIdentity) != address(0), ERC3643ErrorsLib.AddressNotYetStored());
        delete s.identities[userAddress];
        emit IdentityUnstored(userAddress, oldIdentity);
    }

    /// @dev Adds a registry to the bound set. Callers are responsible for rejecting the zero address.
    function _bindIdentityRegistry(address identityRegistry) internal virtual {
        ERC3643IdentityRegistryStorageStorage storage s = _erc3643IdentityRegistryStorageStorage();
        require(
            s.identityRegistries.length() < MAX_IDENTITY_REGISTRIES,
            ERC3643ErrorsLib.MaxIRByIRSReached(MAX_IDENTITY_REGISTRIES)
        );

        s.identityRegistries.add(identityRegistry);
        emit IdentityRegistryBound(identityRegistry);
    }

    /// @dev Removes a registry from the bound set.
    function _unbindIdentityRegistry(address identityRegistry) internal virtual {
        require(identityRegistry != address(0), ERC3643ErrorsLib.ZeroAddress());
        ERC3643IdentityRegistryStorageStorage storage s = _erc3643IdentityRegistryStorageStorage();
        require(s.identityRegistries.remove(identityRegistry), ERC3643ErrorsLib.IdentityRegistryNotStored());

        emit IdentityRegistryUnbound(identityRegistry);
    }

    /// @dev Reads the stored identity of a wallet, separate from the external getter so derived
    ///  contracts can consult the standard record without re-entering their own overridden view.
    function _storedIdentity(address userAddress) internal view virtual returns (IIdentity) {
        return _erc3643IdentityRegistryStorageStorage().identities[userAddress].identityContract;
    }

    /// @dev Reads the stored country of a wallet.
    function _storedInvestorCountry(address userAddress) internal view virtual returns (uint16) {
        return _erc3643IdentityRegistryStorageStorage().identities[userAddress].investorCountry;
    }

    /// @dev Whether a registry is bound to this storage.
    function _isIdentityRegistryBound(address identityRegistry) internal view returns (bool) {
        return _erc3643IdentityRegistryStorageStorage().identityRegistries.contains(identityRegistry);
    }

    function _erc3643IdentityRegistryStorageStorage()
        internal
        pure
        returns (ERC3643IdentityRegistryStorageStorage storage s)
    {
        assembly ("memory-safe") {
            s.slot := IDENTITY_REGISTRY_STORAGE_STORAGE_LOCATION
        }
    }

}
