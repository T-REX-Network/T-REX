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
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IERC3643IdentityRegistryStorage } from "../../ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { ERC3643IdentityRegistryStorage } from "../../ERC-3643/base/ERC3643IdentityRegistryStorage.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IIdentityRegistryStorage } from "../interface/IIdentityRegistryStorage.sol";
import { ITREXRegistry } from "../interface/ITREXRegistry.sol";

/// @title IdentityRegistryStorage
/// @notice Local wallet-to-identity bindings shared by the registries bound to it, which all resolve through one
///  IdentityFactory. It holds only its own bindings: a wallet it does not bind resolves, in each registry, through
///  that registry's IdentityFactory.
/// @dev {ERC3643IdentityRegistryStorage} plus AccessManager authorization, the `onlySharedAuthority` guard on
///  binding, sticky bindings, revocation and ERC-165.
contract IdentityRegistryStorage is
    IIdentityRegistryStorage,
    ERC3643IdentityRegistryStorage,
    AccessManagedOwnableUpgradeable
{

    /// @custom:storage-location erc7201:erc3643.storage.TREXIdentityRegistryStorage
    struct Storage {
        /// @dev The status of each local wallet. Only `Revoked` is written. A wallet with no entry is `Active`
        ///  when it has a stored identity, and `None` otherwise.
        mapping(address wallet => IIdentityFactory.AccountStatus) accountStatus;
        /// @dev The IdentityFactory every bound registry resolves through. Set at `init` and never changed, so
        ///  unbinding registries can never lift the check on a write or let a registry on another factory in.
        IIdentityFactory identityFactory;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXIdentityRegistryStorage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0xcb64a18d0bc273a26dd2f33432c876864881ae0a84f136720d41c3286c288f00;

    /// @notice Upper bound on the registries bound to this storage. It caps the cost of enumerating them.
    function MAX_BOUND_REGISTRIES() external pure returns (uint256) {
        return MAX_IDENTITY_REGISTRIES;
    }

    constructor() {
        _disableInitializers();
    }

    /// @dev The initial registry is bound without asking it for its factory: the TREXFactory passes the registry's
    ///  predicted address, which has no code yet.
    function init(address accessManagerAddress, address initialIRAddress, address identityFactoryAddress)
        external
        initializer
    {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
        require(identityFactoryAddress != address(0), ErrorsLib.ZeroAddress());
        __AccessManaged_init(accessManagerAddress);
        _getStorage().identityFactory = IIdentityFactory(identityFactoryAddress);

        if (initialIRAddress != address(0)) {
            _bindIdentityRegistry(initialIRAddress);
        }
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    /// @dev DEPRECATED: this storage keeps no country; always reverts. The country is a compliance
    ///  concern, owned by the country module bound to the token's `ModularCompliance`.
    function modifyStoredInvestorCountry(address, uint16)
        external
        pure
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
    {
        revert ErrorsLib.Deprecated();
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    /// @dev `onlySharedAuthority` is a misconfiguration guard only: `authority()` is spoofable.
    ///  Every registry bound here must resolve through the same IdentityFactory. A registry checks a new local
    ///  binding against its own factory only, so on a storage shared across factories one registry's agent could
    ///  bind a wallet that another registry's factory links to another identity, and change who owns that
    ///  wallet's tokens in the other registry.
    function bindIdentityRegistry(address identityRegistry)
        external
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
        restricted
        onlySharedAuthority(identityRegistry)
    {
        IIdentityFactory storageFactory = _getStorage().identityFactory;
        IIdentityFactory registryFactory = ITREXRegistry(identityRegistry).identityFactory();
        require(
            registryFactory == storageFactory,
            ErrorsLib.IdentityFactoryMismatch(address(storageFactory), address(registryFactory))
        );
        _bindIdentityRegistry(identityRegistry);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function unbindIdentityRegistry(address _identityRegistry)
        external
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
        restricted
    {
        _unbindIdentityRegistry(_identityRegistry);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    /// @dev DEPRECATED: this storage keeps no country; always returns 0. Read the country from the
    ///  country module bound to the token's `ModularCompliance`.
    function storedInvestorCountry(address)
        external
        pure
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
        returns (uint16)
    {
        return 0;
    }

    /// @inheritdoc IIdentityRegistryStorage
    function localAccountStatus(address userAddress) external view override returns (IIdentityFactory.AccountStatus) {
        return _localAccountStatus(userAddress);
    }

    /// @inheritdoc IIdentityRegistryStorage
    function isIdentityRegistryBound(address identityRegistry) external view override returns (bool) {
        return _isIdentityRegistryBound(identityRegistry);
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC3643IdentityRegistryStorage).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev A wallet may be bound only to the identity the storage's IdentityFactory gives it, if that factory knows
    ///  it. The check sits in the storage so it holds for every holder of the writer role, not only
    ///  for a bound registry. The country is ignored, since this storage keeps none.
    function _addIdentityToStorage(address userAddress, IIdentity userIdentity, uint16) internal override {
        require(
            _getStorage().accountStatus[userAddress] != IIdentityFactory.AccountStatus.Revoked,
            ErrorsLib.WalletAlreadyRevoked(userAddress)
        );
        address factoryIdentity = _factoryIdentityOf(userAddress);
        bool factoryKnowsTheWallet = factoryIdentity != address(0);
        bool factoryAgrees = factoryIdentity == address(userIdentity);
        require(
            !factoryKnowsTheWallet || factoryAgrees,
            ErrorsLib.WalletBoundToAnotherIdentity(userAddress, factoryIdentity)
        );
        super._addIdentityToStorage(userAddress, userIdentity, 0);
    }

    /// @dev Always reverts, because a wallet never changes identity. To move an investor to a new identity,
    ///  register a wallet of that identity and force transfer to it.
    function _modifyStoredIdentity(address userAddress, IIdentity userIdentity) internal view override {
        IIdentity boundIdentity = _storedIdentity(userAddress);
        require(address(boundIdentity) != address(0), ErrorsLib.AddressNotYetStored());
        require(
            _getStorage().accountStatus[userAddress] != IIdentityFactory.AccountStatus.Revoked,
            ErrorsLib.WalletAlreadyRevoked(userAddress)
        );
        require(boundIdentity != userIdentity, ErrorsLib.WalletAlreadyLinkedToIdentity(userAddress));
        revert ErrorsLib.WalletBoundToAnotherIdentity(userAddress, address(boundIdentity));
    }

    /// @dev Revokes the wallet, like the IdentityFactory's `revokeAccount`. The wallet keeps its identity, but
    ///  `isVerified` returns false and it can never be bound again. Emits `IdentityRevoked`, not the standard
    ///  `IdentityUnstored`, since the wallet stays in the registry.
    function _removeIdentityFromStorage(address userAddress) internal override {
        require(userAddress != address(0), ErrorsLib.ZeroAddress());
        IIdentity boundIdentity = _storedIdentity(userAddress);
        require(address(boundIdentity) != address(0), ErrorsLib.AddressNotYetStored());
        require(
            _localAccountStatus(userAddress) == IIdentityFactory.AccountStatus.Active,
            ErrorsLib.WalletNotActive(userAddress)
        );

        _getStorage().accountStatus[userAddress] = IIdentityFactory.AccountStatus.Revoked;
        emit EventsLib.IdentityRevoked(userAddress, boundIdentity);
    }

    /// @dev T-REX keeps no country here, so nothing is written and no `CountryModified` is emitted. The
    ///  country is a compliance concern, owned by the country module bound to the token's
    ///  `ModularCompliance`. The public country setter reverts; this only silences the internal path
    ///  `addIdentityToStorage` takes.
    function _setStoredInvestorCountry(address, uint16) internal override { }

    /// @dev T-REX authorization for the identity-writing functions: the configured AccessManager role.
    function _authorizeIdentityWrite() internal override {
        _checkCanCall(_msgSender(), _msgData());
    }

    /// @dev Binding is authorized by the two dedicated external overrides above, which apply `restricted`
    ///  and `onlySharedAuthority` directly. This hook is therefore never the sole gate on the public path;
    ///  it exists so any future internal caller still passes through the role check.
    function _authorizeRegistryBinding(address) internal override {
        _checkCanCall(_msgSender(), _msgData());
    }

    /// @dev The identity the storage's IdentityFactory links the wallet to, revoked or not. Zero when the factory
    ///  does not know the wallet.
    function _factoryIdentityOf(address userAddress) private view returns (address factoryIdentity) {
        bytes memory account = InteroperableAddress.formatEvmV1(block.chainid, userAddress);
        (factoryIdentity,) = _getStorage().identityFactory.getIdentityIncludingRevoked(account);
    }

    /// @dev The status of a local wallet, as described on `Storage.accountStatus`.
    function _localAccountStatus(address userAddress) private view returns (IIdentityFactory.AccountStatus) {
        if (_getStorage().accountStatus[userAddress] == IIdentityFactory.AccountStatus.Revoked) {
            return IIdentityFactory.AccountStatus.Revoked;
        }
        if (address(_storedIdentity(userAddress)) == address(0)) return IIdentityFactory.AccountStatus.None;
        return IIdentityFactory.AccountStatus.Active;
    }

    function _getStorage() private pure returns (Storage storage store) {
        assembly ("memory-safe") {
            store.slot := STORAGE_LOCATION
        }
    }

}
