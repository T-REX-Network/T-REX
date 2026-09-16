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
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
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
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../utils/AccessManagedOwnableUpgradeable.sol";

/// @title Token
/// @notice The T-REX security token: the standard ERC-3643 token plus the T-REX extensions.
/// @dev Layer 3 of the ERC-3643 / T-REX split (see issue #65). The standard surface -- ERC-20, pause,
///  freezes, forced transfer, recovery, mint and burn, the batch variants and the setters -- and all
///  standard state live in {ERC3643Token}. This contract adds only what T-REX needs on top:
///
///  - AccessManager-based authorization, including per-selector role checks on the batch functions so
///    that a batch carries the same role requirement as the single-call variant it repeats;
///  - validation on the two collaborator setters (interface support, shared authority, and the check
///    that a compliance is not already bound elsewhere);
///  - the spender check on `transferFrom` (#4), delegated to the compliance modules;
///  - the recovery preconditions T-REX enforces beyond the standard's;
///  - ERC-2612 permit and the ERC-165 surface.
///
///  Nothing here writes the base namespace directly; every write goes through a base internal function.
///  Name and symbol are stored by the ERC-20 base rather than duplicated, per issue #54.
contract Token is ERC3643Token, AccessManagedOwnableUpgradeable {

    string internal constant VERSION = "5.0.0";

    /// @custom:storage-location erc7201:erc3643.storage.TREXToken
    struct TokenStorage {
        uint8 decimals;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXToken")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOKEN_STORAGE_LOCATION =
        0x05378669fd58b6f9251e6d5461e60e18b8b3fdf11d70481ba6f9fc72a4bfc600;

    /// @dev Applies the role check of `selector` rather than of the calling function. Used by the batch
    ///  functions so that `batchMint` requires the same role as `mint`.
    modifier restrictedFor(bytes4 selector) {
        _checkCanCall(_msgSender(), selector);
        _;
    }

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

    /// @inheritdoc IERC3643
    /// @dev The EIP-712 domain separator is derived from `name()` (see `_EIP712Name`), so changing the name
    ///      rotates the domain separator and invalidates any outstanding (unused) ERC-2612 permit signatures.
    function setName(string calldata tokenName) external override restricted {
        require(bytes(tokenName).length > 0, ErrorsLib.EmptyString());
        _setName(tokenName);
        _emitUpdatedTokenInformation();
    }

    /// @inheritdoc IERC3643
    function setSymbol(string calldata tokenSymbol) external override restricted {
        require(bytes(tokenSymbol).length > 0, ErrorsLib.EmptyString());
        _setSymbol(tokenSymbol);
        _emitUpdatedTokenInformation();
    }

    /// @inheritdoc IERC3643
    function version() external pure override returns (string memory) {
        return VERSION;
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view override returns (uint8) {
        return _tokenStorage().decimals;
    }

    /* ----- Batch functions ----- */

    /// @inheritdoc IERC3643
    /// @dev Carries the role requirement of `mint`, not a role of its own.
    function batchMint(address[] calldata tos, uint256[] calldata amounts)
        external
        override
        restrictedFor(this.mint.selector)
    {
        for (uint256 i = 0; i < tos.length; i++) {
            _mint(tos[i], amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    /// @dev Carries the role requirement of `burn`.
    function batchBurn(address[] calldata froms, uint256[] calldata amounts)
        external
        override
        restrictedFor(this.burn.selector)
    {
        for (uint256 i = 0; i < froms.length; i++) {
            _burn(froms[i], amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    /// @dev Carries the role requirement of `freezePartialTokens`.
    function batchFreezePartialTokens(address[] calldata users, uint256[] calldata amounts)
        external
        override
        restrictedFor(this.freezePartialTokens.selector)
    {
        for (uint256 i = 0; i < users.length; i++) {
            _freezePartialTokens(users[i], amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    /// @dev Carries the role requirement of `unfreezePartialTokens`.
    function batchUnfreezePartialTokens(address[] calldata users, uint256[] calldata amounts)
        external
        override
        restrictedFor(this.unfreezePartialTokens.selector)
    {
        for (uint256 i = 0; i < users.length; i++) {
            _unfreezePartialTokens(users[i], amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    /// @dev Carries the role requirement of `setAddressFrozen`.
    function batchSetAddressFrozen(address[] calldata users, bool[] calldata freezes)
        external
        override
        restrictedFor(this.setAddressFrozen.selector)
    {
        for (uint256 i = 0; i < users.length; i++) {
            _setAddressFrozen(users[i], freezes[i]);
        }
    }

    /// @inheritdoc IERC3643
    /// @dev Carries the role requirement of `forcedTransfer`.
    function batchForcedTransfer(address[] calldata froms, address[] calldata tos, uint256[] calldata amounts)
        external
        override
        restrictedFor(this.forcedTransfer.selector)
    {
        for (uint256 i = 0; i < froms.length; i++) {
            _forcedTransfer(froms[i], tos[i], amounts[i]);
        }
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

    /// @dev T-REX authorization for every privileged function of the standard base: the role the
    ///  configured AccessManager attaches to the selector being called.
    function _checkTokenAdmin() internal override {
        _checkCanCall(_msgSender(), msg.data);
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

    /// @inheritdoc ERC3643Token
    function _version() internal pure override returns (string memory) {
        return VERSION;
    }

    function _EIP712Name() internal view override returns (string memory) {
        return name();
    }

    function _checkCanCall(address caller, bytes4 selector) internal virtual {
        (bool immediate,) = AuthorityUtils.canCallWithDelay(authority(), caller, address(this), selector);
        require(immediate, IAccessManaged.AccessManagedUnauthorized(caller));
    }

    function _tokenStorage() private pure returns (TokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TOKEN_STORAGE_LOCATION
        }
    }

}
