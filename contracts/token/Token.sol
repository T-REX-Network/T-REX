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
import {
    ERC20PermitUpgradeable,
    ERC20Upgradeable,
    IERC20Permit
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ERC3643EventsLib } from "../ERC-3643/ERC3643EventsLib.sol";
import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643Compliance } from "../ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../utils/AccessManagedOwnableUpgradeable.sol";

contract Token is ERC20PermitUpgradeable, PausableUpgradeable, AccessManagedOwnableUpgradeable, IERC3643 {

    string internal constant VERSION = "5.0.0";

    struct FrozenStatus {
        bool addressFrozen;
        uint256 amount;
    }

    /// @custom:storage-location erc7201:token.storage.main
    struct TokenStorage {
        string name;
        string symbol;
        uint8 decimals;
        address onchainId;
        IERC3643Compliance compliance;
        IERC3643IdentityRegistry identityRegistry;
        mapping(address user => FrozenStatus) frozenStatus;
    }

    // keccak256(abi.encode(uint256(keccak256("token.storage.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOKEN_STORAGE_LOCATION =
        0x3eb201768b0b55c18fa93955aeb38c6bf0f381d8227d53e1b0e5b066883d4e00;

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

        TokenStorage storage s = _tokenStorage();
        s.name = tokenName;
        s.symbol = tokenSymbol;
        s.decimals = tokenDecimals;
        s.onchainId = onchainIdAddress;

        s.identityRegistry = IERC3643IdentityRegistry(identityRegistryAddress);
        s.compliance = IERC3643Compliance(complianceAddress);
        _emitUpdatedTokenInformation();

        _pause();
    }

    /* ----- Main token properties ----- */

    /// @inheritdoc IERC3643
    /// @dev The EIP-712 domain separator is derived from `name()` (see `_EIP712Name`), so changing the name
    ///      rotates the domain separator and invalidates any outstanding (unused) ERC-2612 permit signatures.
    function setName(string calldata tokenName) external restricted {
        require(bytes(tokenName).length > 0, ErrorsLib.EmptyString());
        _tokenStorage().name = tokenName;
        _emitUpdatedTokenInformation();
    }

    /// @inheritdoc IERC3643
    function setSymbol(string calldata tokenSymbol) external restricted {
        require(bytes(tokenSymbol).length > 0, ErrorsLib.EmptyString());
        _tokenStorage().symbol = tokenSymbol;
        _emitUpdatedTokenInformation();
    }

    /// @inheritdoc IERC3643
    /// @dev if _onchainID is set at zero address it means no ONCHAINID is bound to this token
    function setOnchainID(address onchainIdAddress) external restricted {
        _tokenStorage().onchainId = onchainIdAddress;
        _emitUpdatedTokenInformation();
    }

    /// @inheritdoc IERC3643
    function setIdentityRegistry(address identityRegistryAddress)
        public
        restricted
        onlySharedAuthority(identityRegistryAddress)
    {
        _tokenStorage().identityRegistry = IERC3643IdentityRegistry(identityRegistryAddress);
        emit ERC3643EventsLib.IdentityRegistryAdded(identityRegistryAddress);
    }

    /// @inheritdoc IERC3643
    function setCompliance(address complianceAddress) public restricted onlySharedAuthority(complianceAddress) {
        // A compliance already bound to a different token would make every transferred/created/destroyed
        // hook revert (onlyBoundedToken), silently breaking transfers after the swap.
        address boundToken = IERC3643Compliance(complianceAddress).getTokenBound();
        require(boundToken == address(0), ErrorsLib.ComplianceAlreadyBoundToToken());

        TokenStorage storage s = _tokenStorage();
        if (address(s.compliance) != address(0)) {
            s.compliance.unbindToken(address(this));
        }
        s.compliance = IERC3643Compliance(complianceAddress);
        s.compliance.bindToken(address(this));
        emit ERC3643EventsLib.ComplianceAdded(complianceAddress);
    }

    /// @inheritdoc IERC20Metadata
    function name() public view override(ERC20Upgradeable, IERC20Metadata) returns (string memory) {
        return _tokenStorage().name;
    }

    /// @inheritdoc IERC20Metadata
    function symbol() public view override(ERC20Upgradeable, IERC20Metadata) returns (string memory) {
        return _tokenStorage().symbol;
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return _tokenStorage().decimals;
    }

    /// @inheritdoc IERC3643
    function onchainID() external view returns (address) {
        return _tokenStorage().onchainId;
    }

    /// @inheritdoc IERC3643
    function identityRegistry() external view returns (IERC3643IdentityRegistry) {
        return _tokenStorage().identityRegistry;
    }

    /// @inheritdoc IERC3643
    function compliance() external view returns (IERC3643Compliance) {
        return _tokenStorage().compliance;
    }

    /// @inheritdoc IERC3643
    function version() public pure returns (string memory) {
        return VERSION;
    }

    function _EIP712Name() internal view override returns (string memory) {
        return name();
    }

    /* ----- Pause Functions ----- */

    /// @inheritdoc IERC3643
    function pause() external restricted {
        _pause();
    }

    /// @inheritdoc IERC3643
    function unpause() external restricted {
        _unpause();
    }

    /// @inheritdoc IERC3643
    function paused() public view override(PausableUpgradeable, IERC3643) returns (bool) {
        return super.paused();
    }

    /* ----- Minting & Burning Functions ----- */

    /// @inheritdoc IERC3643
    function mint(address to, uint256 amount) external restricted {
        _mint(to, amount);
    }

    /// @inheritdoc IERC3643
    function burn(address from, uint256 amount) external restricted {
        _burn(from, amount);
    }

    /// @inheritdoc IERC3643
    function batchMint(address[] calldata tos, uint256[] calldata amounts) external restrictedFor(this.mint.selector) {
        for (uint256 i = 0; i < tos.length; i++) {
            _mint(tos[i], amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function batchBurn(address[] calldata froms, uint256[] calldata amounts)
        external
        restrictedFor(this.burn.selector)
    {
        for (uint256 i = 0; i < froms.length; i++) {
            _burn(froms[i], amounts[i]);
        }
    }

    /* ----- Freezing Functions ----- */

    /// @inheritdoc IERC3643
    function freezePartialTokens(address user, uint256 amount) public restricted {
        _freezePartialTokens(user, amount);
    }

    /// @inheritdoc IERC3643
    function unfreezePartialTokens(address user, uint256 amount) public restricted {
        _unfreezePartialTokens(user, amount);
    }

    /// @inheritdoc IERC3643
    function setAddressFrozen(address user, bool freeze) public restricted {
        _setAddressFrozen(user, freeze);
    }

    /// @inheritdoc IERC3643
    function batchFreezePartialTokens(address[] calldata users, uint256[] calldata amounts)
        external
        restrictedFor(this.freezePartialTokens.selector)
    {
        for (uint256 i = 0; i < users.length; i++) {
            _freezePartialTokens(users[i], amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function batchUnfreezePartialTokens(address[] calldata users, uint256[] calldata amounts)
        external
        restrictedFor(this.unfreezePartialTokens.selector)
    {
        for (uint256 i = 0; i < users.length; i++) {
            _unfreezePartialTokens(users[i], amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function batchSetAddressFrozen(address[] calldata users, bool[] calldata freezes)
        external
        restrictedFor(this.setAddressFrozen.selector)
    {
        for (uint256 i = 0; i < users.length; i++) {
            _setAddressFrozen(users[i], freezes[i]);
        }
    }

    /// @inheritdoc IERC3643
    function isFrozen(address user) external view returns (bool) {
        return _tokenStorage().frozenStatus[user].addressFrozen;
    }

    /// @inheritdoc IERC3643
    function getFrozenTokens(address user) external view returns (uint256) {
        return _tokenStorage().frozenStatus[user].amount;
    }

    function _freezePartialTokens(address user, uint256 amount) internal {
        TokenStorage storage s = _tokenStorage();
        uint256 balance = balanceOf(user);
        require(
            balance >= s.frozenStatus[user].amount + amount,
            IERC20Errors.ERC20InsufficientBalance(user, balance, amount)
        );
        s.frozenStatus[user].amount += amount;
        emit ERC3643EventsLib.TokensFrozen(user, amount);
    }

    function _unfreezePartialTokens(address user, uint256 amount) internal {
        TokenStorage storage s = _tokenStorage();

        require(
            s.frozenStatus[user].amount >= amount,
            ErrorsLib.AmountAboveFrozenTokens(amount, s.frozenStatus[user].amount)
        );
        s.frozenStatus[user].amount -= amount;
        emit ERC3643EventsLib.TokensUnfrozen(user, amount);
    }

    function _setAddressFrozen(address user, bool freeze) internal {
        _tokenStorage().frozenStatus[user].addressFrozen = freeze;

        emit ERC3643EventsLib.AddressFrozen(user, freeze, _msgSender());
    }

    /* ----- Recovery Functions ----- */

    /// @inheritdoc IERC3643
    function recoveryAddress(address lostWallet, address newWallet, address investorOnchainId)
        external
        restricted
        returns (bool)
    {
        TokenStorage storage s = _tokenStorage();

        uint256 investorTokens = balanceOf(lostWallet);
        require(investorTokens != 0, ErrorsLib.NoTokenToRecover());
        require(
            s.identityRegistry.contains(lostWallet) || s.identityRegistry.contains(newWallet),
            ErrorsLib.RecoveryNotPossible()
        );

        uint256 frozenTokens = s.frozenStatus[lostWallet].amount;
        _forceUpdate(lostWallet, newWallet, investorTokens);

        _migrateFrozenAmount(newWallet, frozenTokens);
        _migrateAddressFrozen(lostWallet, newWallet);
        _migrateIdentity(lostWallet, newWallet, investorOnchainId);

        emit ERC3643EventsLib.RecoverySuccess(lostWallet, newWallet, investorOnchainId);

        return true;
    }

    /// @dev Carries the lost wallet's frozen-token amount onto the new wallet. The amount is captured by the
    ///      caller before `_forceUpdate` runs, since `_forceUpdate` auto-unfreezes and zeroes the lost wallet.
    function _migrateFrozenAmount(address newWallet, uint256 frozenAmount) private {
        if (frozenAmount > 0) {
            _tokenStorage().frozenStatus[newWallet].amount += frozenAmount;
            emit ERC3643EventsLib.TokensFrozen(newWallet, frozenAmount);
        }
    }

    /// @dev Carries the address-frozen flag from the lost wallet onto the new wallet (only when the new wallet
    ///      is not already frozen).
    function _migrateAddressFrozen(address lostWallet, address newWallet) private {
        TokenStorage storage s = _tokenStorage();
        if (s.frozenStatus[lostWallet].addressFrozen) {
            s.frozenStatus[lostWallet].addressFrozen = false;
            emit ERC3643EventsLib.AddressFrozen(lostWallet, false, address(this));

            if (!s.frozenStatus[newWallet].addressFrozen) {
                s.frozenStatus[newWallet].addressFrozen = true;
                emit ERC3643EventsLib.AddressFrozen(newWallet, true, address(this));
            }
        }
    }

    /// @dev Moves the on-chain identity from the lost wallet to the new wallet (registering the new wallet only
    ///      when it is not already known to the identity registry).
    function _migrateIdentity(address lostWallet, address newWallet, address investorOnchainId) private {
        TokenStorage storage s = _tokenStorage();

        require(
            !s.identityRegistry.contains(newWallet)
                || s.identityRegistry.identity(newWallet) == IIdentity(investorOnchainId),
            ErrorsLib.RecoveryNotPossible()
        );

        if (s.identityRegistry.contains(lostWallet)) {
            if (!s.identityRegistry.contains(newWallet)) {
                s.identityRegistry
                    .registerIdentity(
                        newWallet, IIdentity(investorOnchainId), s.identityRegistry.investorCountry(lostWallet)
                    );
            }
            s.identityRegistry.deleteIdentity(lostWallet);
        }
    }

    /* ----- Transfer Functions ----- */

    /// @inheritdoc IERC3643
    function forcedTransfer(address from, address to, uint256 amount) public restricted returns (bool) {
        return _forcedTransfer(from, to, amount);
    }

    /// @inheritdoc IERC3643
    function batchTransfer(address[] calldata tos, uint256[] calldata amounts) external {
        for (uint256 i = 0; i < tos.length; i++) {
            transfer(tos[i], amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function batchForcedTransfer(address[] calldata froms, address[] calldata tos, uint256[] calldata amounts)
        external
        restrictedFor(this.forcedTransfer.selector)
    {
        for (uint256 i = 0; i < froms.length; i++) {
            _forcedTransfer(froms[i], tos[i], amounts[i]);
        }
    }

    function _forcedTransfer(address from, address to, uint256 amount) internal returns (bool) {
        TokenStorage storage s = _tokenStorage();
        require(s.identityRegistry.isVerified(to), ErrorsLib.UnverifiedIdentity());
        _forceUpdate(from, to, amount);
        s.compliance.transferred(from, to, amount);
        return true;
    }

    /* ----- Utility Functions ----- */

    /// @inheritdoc AccessManagedOwnableBase
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC3643).interfaceId
            || interfaceId == type(IERC20Permit).interfaceId || super.supportsInterface(interfaceId);
    }

    function _tokenStorage() private pure returns (TokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TOKEN_STORAGE_LOCATION
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        TokenStorage storage s = _tokenStorage();
        bool isMint = from == address(0);
        bool isBurn = to == address(0);

        if (!isMint && !isBurn) {
            _requireNotPaused();
            require(!s.frozenStatus[from].addressFrozen, ErrorsLib.FrozenWallet(from));
            require(!s.frozenStatus[to].addressFrozen, ErrorsLib.FrozenWallet(to));
            uint256 freeBalance = balanceOf(from) - s.frozenStatus[from].amount;
            require(value <= freeBalance, IERC20Errors.ERC20InsufficientBalance(from, freeBalance, value));
        } else if (isBurn) {
            _autoUnfreezeFor(from, value);
        }

        if (!isBurn) {
            require(s.identityRegistry.isVerified(to), ErrorsLib.UnverifiedIdentity());
            require(s.compliance.canTransfer(from, to, value), ErrorsLib.ComplianceNotFollowed());
        }

        super._update(from, to, value);

        if (isMint) s.compliance.created(to, value);
        else if (isBurn) s.compliance.destroyed(from, value);
        else s.compliance.transferred(from, to, value);
    }

    function _forceUpdate(address from, address to, uint256 value) private {
        _autoUnfreezeFor(from, value);
        super._update(from, to, value);
    }

    function _autoUnfreezeFor(address from, uint256 value) private {
        TokenStorage storage s = _tokenStorage();
        uint256 balance = balanceOf(from);
        require(value <= balance, IERC20Errors.ERC20InsufficientBalance(from, balance, value));
        uint256 freeBalance = balance - s.frozenStatus[from].amount;
        if (value > freeBalance) {
            uint256 toUnfreeze = value - freeBalance;
            s.frozenStatus[from].amount -= toUnfreeze;
            emit ERC3643EventsLib.TokensUnfrozen(from, toUnfreeze);
        }
    }

    function _emitUpdatedTokenInformation() internal {
        emit ERC3643EventsLib.UpdatedTokenInformation(name(), symbol(), decimals(), VERSION, _tokenStorage().onchainId);
    }

    function _checkCanCall(address caller, bytes4 selector) internal virtual {
        (bool immediate,) = AuthorityUtils.canCallWithDelay(authority(), caller, address(this), selector);
        require(immediate, IAccessManaged.AccessManagedUnauthorized(caller));
    }

}
