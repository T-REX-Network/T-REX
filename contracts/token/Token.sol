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

import {
    ERC20PermitUpgradeable,
    ERC20Upgradeable,
    IERC20Permit
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643Compliance } from "../ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { ERC3643Token } from "../ERC-3643/base/ERC3643Token.sol";
import { IModularCompliance } from "../compliance/modular/IModularCompliance.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { ITREXRegistry } from "../registry/interface/ITREXRegistry.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../utils/AccessManagedOwnableUpgradeable.sol";

/// @title Token
/// @dev The T-REX security token: {ERC3643Token} plus AccessManager authorization, validation on the
/// collaborator setters, the spender check on `transferFrom`, the extra recovery preconditions,
/// ERC-2612 permit and ERC-165.
contract Token is ERC3643Token, ERC20PermitUpgradeable, AccessManagedOwnableUpgradeable {

    string internal constant VERSION = "5.0.0";

    /// @custom:storage-location erc7201:erc3643.storage.TREXToken
    struct TokenStorage {
        uint8 decimals;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXToken")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOKEN_STORAGE_LOCATION =
        0x05378669fd58b6f9251e6d5461e60e18b8b3fdf11d70481ba6f9fc72a4bfc600;

    constructor() {
        _disableInitializers();
    }

    function init(
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals,
        address identityRegistryAddress,
        address complianceAddress,
        address onchainIdAddress,
        address accessManagerAddress
    ) external initializer {
        require(
            identityRegistryAddress != address(0) && complianceAddress != address(0)
                && accessManagerAddress != address(0),
            ErrorsLib.ZeroAddress()
        );
        require(bytes(tokenName).length > 0 && bytes(tokenSymbol).length > 0, ErrorsLib.EmptyString());
        require(tokenDecimals <= 18, ErrorsLib.DecimalsOutOfRange(tokenDecimals));

        __ERC20_init(tokenName, tokenSymbol);
        __ERC20Permit_init(tokenName);
        __Pausable_init();
        __AccessManaged_init(accessManagerAddress);

        _tokenStorage().decimals = tokenDecimals;
        _initERC3643(identityRegistryAddress, complianceAddress, onchainIdAddress);

        _pause();
    }

    /* ----- Main token properties ----- */

    /// @inheritdoc IERC20Metadata
    function decimals() public view override(ERC3643Token, ERC20Upgradeable) returns (uint8) {
        return _tokenStorage().decimals;
    }

    /* ----- Transfer Functions ----- */

    /// @inheritdoc IERC20
    /// @dev The bound modules vet the spender before the allowance is spent: a module declaring
    ///      `CHECK_SPENDER` may refuse the caller even when the transfer itself would comply.
    ///      A direct {transfer} never reaches this path, so it carries no spender check and no extra gas.
    /// @param from address the tokens are taken from
    /// @param to address the tokens are sent to
    /// @param value amount of tokens moved
    /// @return true when the transfer succeeded
    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        require(
            IModularCompliance(address(_getCompliance())).canSpenderCall(_msgSender(), from, to, value),
            ErrorsLib.SpenderNotAllowed(_msgSender(), from, to, value)
        );

        return super.transferFrom(from, to, value);
    }

    /* ----- Utility Functions ----- */

    /// @inheritdoc AccessManagedOwnableBase
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC3643).interfaceId
            || interfaceId == type(IERC20Permit).interfaceId || super.supportsInterface(interfaceId);
    }

    /* ----- Layer-2 hook implementations ----- */

    /// @dev Required disambiguation between `ERC3643Token` and `ERC20Upgradeable`; the ERC-3643 rules
    ///  live in the former, so `super` resolves there first and nothing is added here.
    function _update(address from, address to, uint256 value) internal override(ERC3643Token, ERC20Upgradeable) {
        super._update(from, to, value);
    }

    function _checkTokenAdmin(bytes4 selector) internal override {
        _checkCanCallSelector(selector);
    }

    /// @dev T-REX rejects an empty name. Changing it rotates the EIP-712 domain separator,
    ///  invalidating outstanding ERC-2612 permit signatures.
    function _setName(string memory tokenName) internal override {
        require(bytes(tokenName).length > 0, ErrorsLib.EmptyString());
        super._setName(tokenName);
    }

    /// @dev T-REX rejects an empty symbol.
    function _setSymbol(string memory tokenSymbol) internal override {
        require(bytes(tokenSymbol).length > 0, ErrorsLib.EmptyString());
        super._setSymbol(tokenSymbol);
    }

    /// @dev Adds T-REX validation to the standard setter. A wrong registry halts the token, since
    ///  `isVerified` is called on every transfer, so the target must advertise the standard interface
    ///  and share this token's authority. `onlySharedAuthority` is a misconfiguration guard only:
    ///  `authority()` is spoofable.
    function _setIdentityRegistry(address identityRegistryAddress)
        internal
        override
        onlySharedAuthority(identityRegistryAddress)
    {
        require(
            ERC165Checker.supportsInterface(identityRegistryAddress, type(IERC3643IdentityRegistry).interfaceId),
            ErrorsLib.InvalidIdentityRegistry()
        );

        super._setIdentityRegistry(identityRegistryAddress);
    }

    /// @dev Adds T-REX validation and the bind/unbind handshake to the standard setter. A compliance
    ///  already bound to a different token would make every transferred/created/destroyed hook revert
    ///  (onlyBoundedToken), silently breaking transfers after the swap.
    function _setCompliance(address complianceAddress) internal override onlySharedAuthority(complianceAddress) {
        // Checked before getTokenBound() so a wrong contract gives a named error.
        require(
            ERC165Checker.supportsInterface(complianceAddress, type(IERC3643Compliance).interfaceId),
            ErrorsLib.InvalidCompliance()
        );

        address boundToken = IModularCompliance(complianceAddress).getTokenBound();
        require(boundToken == address(0), ErrorsLib.ComplianceAlreadyBoundToToken());

        IERC3643Compliance current = _getCompliance();
        if (address(current) != address(0)) {
            current.unbindToken(address(this));
        }

        // The event lands after the bind so that it only ever reports a binding that succeeded.
        _writeCompliance(complianceAddress);
        IERC3643Compliance(complianceAddress).bindToken(address(this));
        emit ComplianceAdded(complianceAddress);
    }

    /// @dev Adds the T-REX recovery preconditions to the standard recovery: a wallet may not be
    ///  recovered onto itself, there must be something to recover, and at least one of the two wallets
    ///  must already be known to the identity registry.
    function _recoveryAddress(address lostWallet, address newWallet, address investorOnchainId)
        internal
        override
        returns (bool)
    {
        require(lostWallet != newWallet, ErrorsLib.SameWalletRecovery());
        require(balanceOf(lostWallet) != 0, ErrorsLib.NoTokenToRecover());

        IERC3643IdentityRegistry registry = _getIdentityRegistry();
        require(registry.contains(lostWallet) || registry.contains(newWallet), ErrorsLib.RecoveryNotPossible());
        require(
            !registry.contains(newWallet) || registry.identity(newWallet) == IIdentity(investorOnchainId),
            ErrorsLib.RecoveryNotPossible()
        );

        return super._recoveryAddress(lostWallet, newWallet, investorOnchainId);
    }

    /// @dev Adds the T-REX `ForcedTransfer` event to the standard forced transfer. It is emitted before
    ///  the compliance hook so that no module log can land between `Transfer` and this event.
    function _forcedTransfer(address from, address to, uint256 amount) internal override returns (bool) {
        require(_getIdentityRegistry().isVerified(to), ErrorsLib.UnverifiedIdentity());
        _forceUpdate(from, to, amount);
        emit EventsLib.ForcedTransfer(_msgSender());
        _getCompliance().transferred(from, to, amount);
        return true;
    }

    /// @dev The new wallet is registered only when it resolves nowhere, so a wallet the global registry
    ///  already binds keeps following that binding rather than a local copy. Only local entries can be
    ///  deleted. Country is passed as 0 rather than read from the lost wallet, because T-REX stores none;
    ///  drop this override if country storage comes back, so the base reads the real value again.
    function _migrateIdentity(address lostWallet, address newWallet, address investorOnchainID) internal override {
        IERC3643IdentityRegistry registry = _getIdentityRegistry();

        if (!registry.contains(newWallet)) {
            registry.registerIdentity(newWallet, IIdentity(investorOnchainID), 0);
        }
        if (ITREXRegistry(address(registry)).isLocallyRegistered(lostWallet)) {
            registry.deleteIdentity(lostWallet);
        }
    }

    /// @inheritdoc ERC3643Token
    function _version() internal pure override returns (string memory) {
        return VERSION;
    }

    function _EIP712Name() internal view override returns (string memory) {
        return name();
    }

    function _tokenStorage() private pure returns (TokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TOKEN_STORAGE_LOCATION
        }
    }

}
