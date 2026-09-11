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
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ERC3643EventsLib } from "../../ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IERC3643IdentityRegistryStorage, IIdentityRegistryStorage } from "../interface/IIdentityRegistryStorage.sol";
import { ITREXRegistry } from "../interface/ITREXRegistry.sol";

/// @title IdentityRegistryStorage
/// @notice Wallet-to-identity bindings shared by the registries bound to it. This storage is a local override
///  layer on top of the global ONCHAINID identity registry (the `IdentityFactory` of each bound registry): a
///  wallet with no local binding resolves through the global registry, and a locally stored binding takes
///  precedence over the global one for every token wired to this storage.
/// @dev A local binding that shadows a different global identity is signalled by `IdentityOverridden` at
///  registration time and never blocked.
contract IdentityRegistryStorage is IIdentityRegistryStorage, AccessManagedOwnableUpgradeable {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:ERC3643.storage.IdentityRegistryStorage
    struct Storage {
        /// @dev mapping between a user address and the corresponding identity
        mapping(address user => IIdentity) identities;

        /// @dev set of Identity Registries linked to this storage
        EnumerableSet.AddressSet identityRegistries;
    }

    // keccak256(abi.encode(uint256(keccak256("ERC3643.storage.IdentityRegistryStorage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0x6d25db4721129739b3a7e96c2537b7170fb9cfd72348ce376c7a189a3ab3ba00;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract
    /// @param accessManagerAddress the address of the access manager
    /// @param initialIRAddress the Identity Registry to bind at deploy time, or the zero address to bind none
    function init(address accessManagerAddress, address initialIRAddress) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
        __AccessManaged_init(accessManagerAddress);

        if (initialIRAddress != address(0)) {
            _bindIdentityRegistry(initialIRAddress);
        }
    }

    /**
     *  @dev See {IIdentityRegistryStorage-addIdentityToStorage}.
     *  @dev The binding stored here overrides, for every token wired to this storage, whatever the global
     *  ONCHAINID identity registry returns for the wallet. When the global registry already binds the wallet
     *  to another identity, `IdentityOverridden` is emitted and the registration proceeds.
     *  @dev The country argument is ignored: this storage keeps wallet-to-identity bindings only. The
     *  country is a compliance concern, read from the country module bound to the token's
     *  `ModularCompliance`.
     */
    function addIdentityToStorage(address _userAddress, IIdentity _identity, uint16) external restricted {
        require(_userAddress != address(0) && address(_identity) != address(0), ErrorsLib.ZeroAddress());

        Storage storage s = _getStorage();
        require(address(s.identities[_userAddress]) == address(0), ErrorsLib.AddressAlreadyStored());
        s.identities[_userAddress] = _identity;

        emit ERC3643EventsLib.IdentityStored(_userAddress, _identity);

        IIdentity globalIdentity = _globalIdentity(_userAddress);
        if (address(globalIdentity) != address(0) && globalIdentity != _identity) {
            emit EventsLib.IdentityOverridden(_userAddress, globalIdentity, _identity);
        }
    }

    /**
     *  @dev See {IIdentityRegistryStorage-modifyStoredIdentity}.
     */
    function modifyStoredIdentity(address _userAddress, IIdentity _identity) external restricted {
        require(_userAddress != address(0) && address(_identity) != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(address(s.identities[_userAddress]) != address(0), ErrorsLib.AddressNotYetStored());
        IIdentity oldIdentity = s.identities[_userAddress];
        s.identities[_userAddress] = _identity;
        emit ERC3643EventsLib.IdentityModified(oldIdentity, _identity);
        emit EventsLib.InvestorIdentityChanged(_userAddress);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-modifyStoredInvestorCountry}.
     *  @dev DEPRECATED: this storage keeps no country; always reverts. The country is a compliance
     *  concern, owned by the country module bound to the token's `ModularCompliance`.
     */
    function modifyStoredInvestorCountry(address, uint16) external pure {
        revert ErrorsLib.Deprecated();
    }

    /**
     *  @dev See {IIdentityRegistryStorage-removeIdentityFromStorage}.
     */
    function removeIdentityFromStorage(address _userAddress) external restricted {
        require(_userAddress != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(address(s.identities[_userAddress]) != address(0), ErrorsLib.AddressNotYetStored());
        IIdentity oldIdentity = s.identities[_userAddress];
        delete s.identities[_userAddress];
        emit ERC3643EventsLib.IdentityUnstored(_userAddress, oldIdentity);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-bindIdentityRegistry}.
     */
    function bindIdentityRegistry(address identityRegistry) external restricted onlySharedAuthority(identityRegistry) {
        _bindIdentityRegistry(identityRegistry);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-unbindIdentityRegistry}.
     */
    function unbindIdentityRegistry(address _identityRegistry) external restricted {
        require(_identityRegistry != address(0), ErrorsLib.ZeroAddress());
        Storage storage s = _getStorage();
        require(s.identityRegistries.remove(_identityRegistry), ErrorsLib.IdentityRegistryNotStored());

        emit ERC3643EventsLib.IdentityRegistryUnbound(_identityRegistry);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-linkedIdentityRegistries}.
     */
    function linkedIdentityRegistries() external view returns (address[] memory) {
        return _getStorage().identityRegistries.values();
    }

    /**
     *  @dev See {IIdentityRegistryStorage-isLocallyStored}.
     */
    function isLocallyStored(address _userAddress) external view override returns (bool) {
        return address(_getStorage().identities[_userAddress]) != address(0);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-storedIdentity}.
     *  @dev The local binding takes precedence; without one, the wallet resolves through the global
     *  identity registry (see `_globalIdentity`).
     */
    function storedIdentity(address _userAddress) external view returns (IIdentity) {
        IIdentity identity = _getStorage().identities[_userAddress];
        if (address(identity) != address(0)) {
            return identity;
        }
        return _globalIdentity(_userAddress);
    }

    /**
     *  @dev See {IIdentityRegistryStorage-storedInvestorCountry}.
     *  @dev DEPRECATED: this storage keeps no country; always returns 0. Read the country from the
     *  country module bound to the token's `ModularCompliance`.
     */
    function storedInvestorCountry(address) external pure returns (uint16) {
        return 0;
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC3643IdentityRegistryStorage).interfaceId || super.supportsInterface(interfaceId);
    }

    function _bindIdentityRegistry(address _identityRegistry) internal {
        // Note: callers (init and bindIdentityRegistry) already reject the zero address before reaching
        // here -- init via its `if (initialIRAddress != address(0))` guard, and the public
        // bindIdentityRegistry via its `onlySharedAuthority` modifier -- so no zero-address check is needed.
        Storage storage s = _getStorage();
        require(s.identityRegistries.length() < 300, ErrorsLib.MaxIRByIRSReached(300));

        s.identityRegistries.add(_identityRegistry);
        emit ERC3643EventsLib.IdentityRegistryBound(_identityRegistry);
    }

    /**
     *  @dev Asks the IdentityFactory of each bound registry in turn and returns the first identity found,
     *  or the zero identity when none knows the wallet. The factory keys wallets by ERC-7930
     *  interoperable address.
     */
    function _globalIdentity(address _userAddress) internal view returns (IIdentity identity) {
        Storage storage s = _getStorage();
        bytes memory account = InteroperableAddress.formatEvmV1(block.chainid, _userAddress);
        uint256 count = s.identityRegistries.length();
        for (uint256 i = 0; i < count && address(identity) == address(0); i++) {
            identity = IIdentity(ITREXRegistry(s.identityRegistries.at(i)).identityFactory().getIdentity(account));
        }
    }

    function _getStorage() internal pure returns (Storage storage s) {
        assembly ("memory-safe") {
            s.slot := STORAGE_LOCATION
        }
    }

}
