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
    /// @dev Adds `EventsLib.InvestorIdentityChanged` to the standard behavior: T-REX operators watch it
    ///  to reconcile off-chain investor records when an identity contract is replaced.
    function modifyStoredIdentity(address _userAddress, IIdentity _identity)
        external
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
    {
        _authorizeIdentityWrite();
        IIdentity oldIdentity = _storedIdentity(_userAddress);
        _modifyStoredIdentity(_userAddress, _identity);
        emit EventsLib.InvestorIdentityChanged(_userAddress);
        _signalOverrideChange(_userAddress, oldIdentity, _identity);
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
    ///  identity registry (see `_globalIdentity`).
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
    function isLocallyRegistered(address userAddress) external view override returns (bool) {
        return address(_storedIdentity(userAddress)) != address(0);
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC3643IdentityRegistryStorage).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Signals an override after the standard `IdentityStored`: an override registration logs both
    ///  events, in that order, so an indexer must read the pair rather than stop at `IdentityStored`.
    ///  The country argument is ignored and no `CountryModified` is emitted: T-REX keeps no country here,
    ///  see `modifyStoredInvestorCountry`.
    function _addIdentityToStorage(address userAddress, IIdentity userIdentity, uint16) internal override {
        super._addIdentityToStorage(userAddress, userIdentity, 0);

        IIdentity globalIdentity = _globalIdentity(userAddress);
        if (address(globalIdentity) != address(0) && globalIdentity != userIdentity) {
            emit EventsLib.IdentityOverridden(userAddress, globalIdentity, userIdentity);
        }
    }

    /// @dev Signals at most one override change after the standard events: `IdentityOverridden` when the
    ///  new binding diverges from a non-zero global identity, `IdentityOverrideReleased` when it realigns
    ///  with it. A write that leaves the binding unchanged signals nothing. An indexer tracking the
    ///  override state must read that trailing event, not only the modification pair.
    function _signalOverrideChange(address userAddress, IIdentity oldIdentity, IIdentity newIdentity) private {
        IIdentity globalIdentity = _globalIdentity(userAddress);
        if (address(globalIdentity) == address(0)) return;

        if (globalIdentity != newIdentity) {
            emit EventsLib.IdentityOverridden(userAddress, globalIdentity, newIdentity);
        } else if (oldIdentity != newIdentity) {
            emit EventsLib.IdentityOverrideReleased(userAddress, oldIdentity, globalIdentity);
        }
    }

    /// @dev Deletes the local override only. The wallet does not disappear from the token's view: it falls
    ///  back to the global registry, and when bound there it remains `contains` and potentially
    ///  `isVerified`. Excluding a wallet from a token is a compliance concern, not this function.
    function _removeIdentityFromStorage(address userAddress) internal override {
        IIdentity oldIdentity = _storedIdentity(userAddress);
        super._removeIdentityFromStorage(userAddress);

        IIdentity globalIdentity = _globalIdentity(userAddress);
        if (address(globalIdentity) != address(0) && globalIdentity != oldIdentity) {
            emit EventsLib.IdentityOverrideReleased(userAddress, oldIdentity, globalIdentity);
        }
    }

    /// @dev T-REX keeps no country here, so nothing is written and no `CountryModified` is emitted. The
    ///  country is a compliance concern, owned by the country module bound to the token's
    ///  `ModularCompliance`. The public country setter reverts; this only silences the internal path
    ///  `addIdentityToStorage` takes.
    function _setStoredInvestorCountry(address, uint16) internal override { }

    /// @dev T-REX authorization for the identity-writing functions: the configured AccessManager role.
    function _authorizeIdentityWrite() internal override {
        _checkCanCall(_msgSender(), msg.data);
    }

    /// @dev Binding is authorized by the two dedicated external overrides above, which apply `restricted`
    ///  and `onlySharedAuthority` directly. This hook is therefore never the sole gate on the public path;
    ///  it exists so any future internal caller still passes through the role check.
    function _authorizeRegistryBinding(address) internal override {
        _checkCanCall(_msgSender(), msg.data);
    }

    /// @dev Asks the IdentityFactory of each bound registry in turn and returns the first identity found,
    ///  or the zero identity when none knows the wallet. The factory keys wallets by ERC-7930
    ///  interoperable address, built with `formatEvmV1(block.chainid, wallet)`, so it resolves EVM wallets
    ///  on this chain only. Wallets of another chain type, or the same wallet on another chain, are out of
    ///  scope for this fallback and resolve to the zero identity; bind them locally instead.
    function _globalIdentity(address userAddress) internal view returns (IIdentity identity) {
        bytes memory account = InteroperableAddress.formatEvmV1(block.chainid, userAddress);
        address[] memory registries = _linkedIdentityRegistries();
        for (uint256 i = 0; i < registries.length && address(identity) == address(0); i++) {
            identity = IIdentity(ITREXRegistry(registries[i]).identityFactory().getIdentity(account));
        }
    }

}
