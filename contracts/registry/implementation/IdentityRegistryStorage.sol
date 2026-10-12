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
/// @notice Wallet-to-identity bindings shared by the registries bound to it. This storage is a local
///  override layer on top of the global ONCHAINID identity registry (the `IdentityFactory` of each bound
///  registry): a wallet with no local binding resolves through the global registry, and a locally stored
///  binding takes precedence over the global one for every token wired to this storage.
/// @dev {ERC3643IdentityRegistryStorage} plus AccessManager authorization, the `onlySharedAuthority`
///  guard on binding, the global fallback, the override signals and ERC-165. A local binding that shadows
///  a different global identity is signalled by `IdentityOverridden`, and the end of that divergence by
///  `IdentityOverrideReleased`.
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
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXIdentityRegistryStorage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0xcb64a18d0bc273a26dd2f33432c876864881ae0a84f136720d41c3286c288f00;

    /// @notice Upper bound on the registries bound to this storage. It caps the cost of the global
    ///  fallback, which asks the IdentityFactory of every bound registry in turn (one external call each)
    ///  whenever a wallet has no local binding.
    function MAX_BOUND_REGISTRIES() external pure returns (uint256) {
        return MAX_IDENTITY_REGISTRIES;
    }

    constructor() {
        _disableInitializers();
    }

    function init(address accessManagerAddress, address initialIRAddress) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
        __AccessManaged_init(accessManagerAddress);

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
    function bindIdentityRegistry(address identityRegistry)
        external
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
        restricted
        onlySharedAuthority(identityRegistry)
    {
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
    /// @dev The local binding takes precedence; without one, the wallet resolves through the global
    ///  identity registry (see `_globalIdentity`). A revoked wallet still returns its identity.
    function storedIdentity(address _userAddress)
        external
        view
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
        returns (IIdentity)
    {
        IIdentity localIdentity = _storedIdentity(_userAddress);
        if (address(localIdentity) != address(0)) {
            return localIdentity;
        }
        return _globalIdentity(_userAddress);
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

    /// @dev Reverts if the wallet was revoked, or if the IdentityFactory links it to another identity. Binding
    ///  the same identity as the factory is allowed. The country is ignored, since this storage keeps none.
    function _addIdentityToStorage(address userAddress, IIdentity userIdentity, uint16) internal override {
        require(
            _getStorage().accountStatus[userAddress] != IIdentityFactory.AccountStatus.Revoked,
            ErrorsLib.WalletAlreadyRevoked(userAddress)
        );
        super._addIdentityToStorage(userAddress, userIdentity, 0);

        IIdentity globalIdentity = _globalIdentity(userAddress);
        require(
            address(globalIdentity) == address(0) || globalIdentity == userIdentity,
            ErrorsLib.WalletBoundToAnotherIdentity(userAddress, address(globalIdentity))
        );
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

    /// @dev Asks the IdentityFactory of each bound registry in turn and returns the first identity found,
    ///  or the zero identity when none knows the wallet. A revoked binding still answers: this is the
    ///  attribution read behind `identity` and `contains`, and a wallet that holds tokens must keep its owner
    ///  after the investor revokes it, so the compliance can still debit the right position on a burn, a
    ///  recovery or a forced transfer. Whether the wallet may still act is the admission read, `isVerified`,
    ///  which asks the factory for the status itself. The factory keys wallets by ERC-7930
    ///  interoperable address, built with `formatEvmV1(block.chainid, wallet)`, so it resolves EVM wallets
    ///  on this chain only. Wallets of another chain type, or the same wallet on another chain, are out of
    ///  scope for this fallback and resolve to the zero identity; bind them locally instead.
    function _globalIdentity(address userAddress) internal view returns (IIdentity identity) {
        bytes memory account = InteroperableAddress.formatEvmV1(block.chainid, userAddress);
        address[] memory registries = _linkedIdentityRegistries();
        for (uint256 i = 0; i < registries.length && address(identity) == address(0); i++) {
            (address resolved,) = ITREXRegistry(registries[i]).identityFactory().getIdentityIncludingRevoked(account);
            identity = IIdentity(resolved);
        }
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
