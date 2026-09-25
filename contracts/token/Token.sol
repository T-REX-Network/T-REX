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

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643Compliance } from "../ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { ERC3643Token } from "../ERC-3643/base/ERC3643Token.sol";
import { IModularCompliance } from "../compliance/modular/IModularCompliance.sol";
import { ISettlementHandler } from "../interop/ISettlementHandler.sol";
import { ITREXMessaging } from "../interop/ITREXMessaging.sol";
import { TREXMessaging } from "../interop/TREXMessaging.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../registry/interface/ITREXRegistry.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../utils/AccessManagedOwnableUpgradeable.sol";
import { IToken } from "./IToken.sol";

/// @title Token
/// @dev The T-REX security token: {ERC3643Token} plus AccessManager authorization, validation on the
/// collaborator setters, the spender check on `transferFrom`, the extra recovery preconditions,
/// ERC-2612 permit, ERC-165, and the bridged ledger the ERC-7786 messaging endpoint settles onto.
contract Token is ERC3643Token, ERC20PermitUpgradeable, AccessManagedOwnableUpgradeable, TREXMessaging, IToken {

    string internal constant VERSION = "5.0.0";

    /// @custom:storage-location erc7201:erc3643.storage.TREXToken
    struct TokenStorage {
        uint8 decimals;
        /// @dev Positions delegated to satellites, keyed by the canonical ERC-7930 wallet key. Separate from the
        ///  native mapping, which stays OpenZeppelin's.
        mapping(bytes32 walletKey => uint256) bridgedBalance;
        /// @dev Sum of every bridged position, kept so `totalSupply` counts it in O(1).
        uint256 totalBridged;
        /// @dev Amounts a satellite burned for a cross-chain validation whose mint leg has not landed, keyed by
        ///  the validation. Debited from the sender's position, still counted in `totalBridged`, still owned by
        ///  the sender the validation names.
        mapping(uint256 validationId => uint256) inTransit;
        /// @dev Sum of every in-transit hold: the part of `totalBridged` no wallet currently holds.
        uint256 totalInTransit;
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
        address trustedGatewayRegistryAddress,
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

        // The network's registry, fixed for the token's lifetime: no role can move it afterwards.
        _setTrustedGatewayRegistry(trustedGatewayRegistryAddress);

        _pause();
    }

    /* ----- Main token properties ----- */

    /// @inheritdoc IERC20Metadata
    /// @dev {IToken} re-declares the ERC-3643 surface, so `IERC20Metadata` reaches this contract by a
    ///  second path and has to be named among the overridden bases.
    function decimals() public view override(ERC3643Token, ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return _tokenStorage().decimals;
    }

    /// @inheritdoc IERC3643
    /// @dev Required disambiguation between the {IToken} declaration and the base's implementation;
    ///  the pause state itself lives in `PausableUpgradeable` and nothing is added here.
    function paused() public view override(ERC3643Token, IERC3643) returns (bool) {
        return super.paused();
    }

    /* ----- Interop Configuration ----- */

    /// @inheritdoc ITREXMessaging
    function setRoute(bytes2 chainType, bytes calldata chainReference, address gateway) external restricted {
        _setRoute(chainType, chainReference, gateway);
    }

    /// @inheritdoc ITREXMessaging
    function setPeer(bytes32 chainKey, bytes calldata peer) external restricted {
        _setPeer(chainKey, peer);
    }

    /* ----- Interop Dispatch ----- */

    /// @dev Sends a compliance validation to this token's peer on `chainKey`, pinning the route it took.
    ///
    /// The reference side has two contracts with something to say, the compliance and the token, but
    /// the wire has one author: the token. Compliance therefore dispatches through here, and the peer
    /// only ever has to trust a single reference address. A cross-chain validation is dispatched once
    /// per involved chain, under the same `validationId`, and each leg pins its own route.
    ///
    /// Callable by the bound compliance alone. No role opens this door: a validation body and the id it
    /// travels under are the compliance's to author, and a human holding the selector could otherwise
    /// forge either, or pin a route under an id the compliance has not reached yet. Reverts when the
    /// chain was never opened, or when this validation already went out toward `chainKey` through
    /// another gateway.
    function dispatchComplianceValidation(bytes32 chainKey, uint256 validationId, bytes calldata body)
        external
        returns (bytes32)
    {
        require(_msgSender() == address(_getCompliance()), ErrorsLib.SenderNotCompliance(_msgSender()));

        return _sendComplianceValidation(chainKey, validationId, body);
    }

    /// @dev Sends a delegation-out mint instruction to this token's peer on `chainKey`.
    ///
    /// One-way by design: delegation-out is atomic and final here, so no reconciliation is expected and
    /// none is tracked. Reverts when the chain was never opened.
    function dispatchMintInstruction(bytes32 chainKey, bytes calldata body) external restricted returns (bytes32) {
        return _sendMessage(chainKey, MessageTypesLib.Message.MINT_INSTRUCTION, body);
    }

    /// @dev Sends a forced-recall instruction to this token's peer on `chainKey`.
    function dispatchRecallInstruction(bytes32 chainKey, bytes calldata body) external restricted returns (bytes32) {
        return _sendMessage(chainKey, MessageTypesLib.Message.RECALL_INSTRUCTION, body);
    }

    /// @inheritdoc IToken
    function settleValidation(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId)
        external
        whenNotPaused
    {
        require(_msgSender() == address(_getCompliance()), ErrorsLib.OnlyBoundCompliance());

        (bool toNative, address recipient) = WalletKeyLib.isReferenceChain(to);
        if (toNative) {
            _settleToNative(from, recipient, amount, validationId);
            return;
        }
        _bridgedTransfer(from, to, amount, validationId);
    }

    /// @inheritdoc IToken
    function holdInTransit(bytes calldata from, uint256 amount, uint256 validationId) external whenNotPaused {
        require(_msgSender() == address(_getCompliance()), ErrorsLib.OnlyBoundCompliance());
        _holdInTransit(from, amount, validationId);
    }

    /* ----- Ledger Views ----- */

    /// @inheritdoc IERC20
    /// @dev The whole issuance: the native ERC-20 supply plus every position on a satellite. A delegation-out, a
    ///  recall or either native-side settlement leg moves between the two terms and never changes the sum; only a
    ///  mint or a burn does.
    ///
    ///  The register reports the issuance, not the native float, and the events say so at the cost of one
    ///  trade-off. A native-to-bridged move emits `Transfer(holder, 0x0)` deliberately: that is what makes
    ///  `balanceOf` drop visibly and keeps every ERC-20 balance indexer correct. The price is that a supply
    ///  derived by summing `Transfer` events under-reports by `totalBridged`; `DelegatedOut`, `Recalled` and
    ///  `SettledToNative` are the reconciliation for anyone deriving it that way, and
    ///  `totalSupply() - totalBridged()` is the native float. An escrow address holding the delegated float
    ///  would keep Transfer-summing whole and was rejected: it would show the token holding its own supply.
    ///  `INV-7` sums the buckets to this figure and asserts that escrow is never there; `INV-8` holds
    ///  `totalBridged` to the positions, whichever transition moved it.
    function totalSupply() public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return super.totalSupply() + _tokenStorage().totalBridged;
    }

    /// @inheritdoc IToken
    function freeBalanceOf(address wallet) public view returns (uint256) {
        return balanceOf(wallet) - _getFrozenTokens(wallet);
    }

    /// @inheritdoc IToken
    function bridgedBalanceOf(bytes calldata wallet) external view returns (uint256) {
        return _tokenStorage().bridgedBalance[WalletKeyLib.canonicalKey(wallet)];
    }

    /// @inheritdoc IToken
    function totalBridged() external view returns (uint256) {
        return _tokenStorage().totalBridged;
    }

    /// @inheritdoc IToken
    function inTransitOf(uint256 validationId) external view returns (uint256) {
        return _tokenStorage().inTransit[validationId];
    }

    /// @inheritdoc IToken
    function totalInTransit() external view returns (uint256) {
        return _tokenStorage().totalInTransit;
    }

    /* ----- Transfer Functions ----- */

    /// @inheritdoc IERC20
    /// @dev The bound modules vet the spender before the allowance is spent: a `SPENDER` module may refuse
    ///      the caller even when the transfer itself would comply.
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

    /// @notice Moves tokens out of a wallet on behalf of the investor's own identity.
    /// @dev The identity itself must be the caller: it is an ERC-7579 account, so the call already carries
    ///      the account's own authentication. A key holder calling the token directly is just another caller.
    /// @dev No allowance is read or written, and the spender gate never runs: it vets third-party spenders,
    ///      and the owner's own identity is not one. `approve`, `transferFrom` and `permit` stay plain ERC-20.
    /// @dev Carries no revocation gate of its own. A wallet revoked in ONCHAINID still resolves here whenever
    ///      it holds a local registration, and it can still {transfer} out, so gating this path alone would be
    ///      bypassable rather than protective. Revoked wallets are a token-wide policy question, not this
    ///      function's.
    /// @param from wallet the tokens are taken from, linked to the calling identity
    /// @param to address the tokens are sent to
    /// @param amount number of tokens moved
    /// @return true when the transfer succeeded
    function identityTransfer(address from, address to, uint256 amount) external returns (bool) {
        // An unlinked wallet resolves to the zero identity. No caller can be the zero address, so the sender
        // check alone already rejects it; the explicit guard keeps the zero identity from ever authorizing
        // itself if `_msgSender()` is later overridden.
        IIdentity identity = _getIdentityRegistry().identity(from);
        require(
            address(identity) != address(0) && _msgSender() == address(identity),
            ErrorsLib.NotLinkedIdentity(from, _msgSender())
        );
        _transfer(from, to, amount);
        // Emitted after the move so the operator event follows `Transfer`, the ordering {_forcedTransfer} keeps.
        emit EventsLib.IdentityTransfer(address(identity), from, to, amount);

        return true;
    }

    /* ----- Ledger Transitions ----- */

    // Pause policy for everything below: the transitions move balances without {_update} and check no pause
    // themselves; the entry points that reach them do. Today those are `_handleSettlement`, `settleValidation`
    // and `holdInTransit`, each of which requires the token not to be paused. A delegation-out or recall flow
    // that lands later must do the same before calling `_delegateOut` or `_recall`, so that the pause halts
    // every movement between wallets, native or satellite, while mints and burns stay allowed.

    /// @dev Moves `amount` of `holder`'s free balance out to `toWallet`, a wallet on a satellite chain: a native
    ///  burn (`Transfer(holder, 0x0)`, so `balanceOf` drops) and a bridged credit; `totalSupply` never moves.
    ///  Relocation of one identity's own position, so ownership does not move: the calling flow checks pause,
    ///  freeze, eligibility, compliance and that `toWallet` belongs to `holder`'s identity, and the ledger checks
    ///  the buckets and the envelope only. It is the only way a native position reaches a satellite.
    function _delegateOut(address holder, bytes memory toWallet, uint256 amount) internal {
        bytes32 toKey = _moveNativeToBridged(holder, toWallet, amount);

        emit EventsLib.DelegatedOut(holder, toKey, toWallet, amount);
    }

    /// @dev Brings `amount` back from `fromWallet`, a wallet on a satellite chain, onto `holder`'s free balance:
    ///  a bridged debit and a native mint (`Transfer(0x0, holder)`). The mirror of {_delegateOut}, applied on a
    ///  consumed burn proof; the flow checks that `holder` belongs to the burned wallet's identity, so ownership
    ///  does not move here either. A settlement leg that crosses identities is {_settleToNative}.
    function _recall(bytes memory fromWallet, address holder, uint256 amount) internal {
        bytes32 fromKey = _moveBridgedToNative(fromWallet, holder, amount);

        emit EventsLib.Recalled(fromKey, holder, fromWallet, amount);
    }

    /// @dev Takes `amount` out of `fromWallet`'s bridged position and holds it against `validationId`: the burn
    ///  leg of a cross-chain validation landed, the mint leg has not. The amount stays bridged and stays the
    ///  sender's; only the wallet no longer holds it, so nothing can be issued or recalled against tokens the
    ///  satellite already burned. One hold per validation.
    function _holdInTransit(bytes memory fromWallet, uint256 amount, uint256 validationId) internal {
        bytes32 fromKey = WalletKeyLib.satelliteKey(fromWallet);

        TokenStorage storage s = _tokenStorage();
        require(s.inTransit[validationId] == 0, ErrorsLib.TransitAlreadyHeld(validationId));
        _debitBridged(s, fromWallet, fromKey, amount);
        s.inTransit[validationId] = amount;
        s.totalInTransit += amount;

        emit EventsLib.HeldInTransit(fromKey, validationId, fromWallet, amount);
    }

    /// @dev Applies a settled movement between two satellite wallets, same-chain or cross-chain, in one atomic
    ///  touch: `from` down, `to` up, nothing native. `validationId` is the validation the settlement consumed.
    ///  When its burn leg already moved the amount in transit, the hold is what `to` is credited from, and it
    ///  must be the settled amount exactly.
    function _bridgedTransfer(bytes memory from, bytes memory to, uint256 amount, uint256 validationId) internal {
        bytes32 fromKey = WalletKeyLib.satelliteKey(from);
        bytes32 toKey = WalletKeyLib.satelliteKey(to);

        TokenStorage storage s = _tokenStorage();
        uint256 held = s.inTransit[validationId];
        if (held != 0) {
            require(held == amount, ErrorsLib.TransitAmountMismatch(validationId, held, amount));
            delete s.inTransit[validationId];
            s.totalInTransit -= amount;
        } else {
            _debitBridged(s, from, fromKey, amount);
        }
        s.bridgedBalance[toKey] += amount;

        emit EventsLib.BridgedTransfer(fromKey, toKey, validationId, from, to, amount);
    }

    /// @dev Applies the settled leg of a validation whose sender is on a satellite and whose receiver is on the
    ///  reference chain: the satellite position down, `to`'s free balance up. Same bucket arithmetic as {_recall}
    ///  and a distinct event, because ownership moves between identities here. `validationId` is the validation
    ///  the settlement consumed. The calling flow owns the lifecycle; the ledger checks the buckets and the
    ///  envelope only. There is no mirror leaving a native wallet: the compliance issues no validation whose
    ///  sender is native, so the satellite executing one always holds the position it moves.
    function _settleToNative(bytes memory fromWallet, address to, uint256 amount, uint256 validationId) internal {
        bytes32 fromKey = _moveBridgedToNative(fromWallet, to, amount);

        emit EventsLib.SettledToNative(fromKey, to, validationId, fromWallet, amount);
    }

    /// @dev The bucket arithmetic every native-to-bridged transition shares: a native burn and a bridged credit,
    ///  `totalSupply` unmoved. Emits nothing; the caller names the movement.
    function _moveNativeToBridged(address holder, bytes memory toWallet, uint256 amount)
        private
        returns (bytes32 toKey)
    {
        require(holder != address(0), ErrorsLib.ZeroAddress());
        toKey = WalletKeyLib.satelliteKey(toWallet);
        uint256 freeBalance = freeBalanceOf(holder);
        require(amount <= freeBalance, IERC20Errors.ERC20InsufficientBalance(holder, freeBalance, amount));

        TokenStorage storage s = _tokenStorage();
        ERC20Upgradeable._update(holder, address(0), amount);
        s.bridgedBalance[toKey] += amount;
        s.totalBridged += amount;
    }

    /// @dev The bucket arithmetic every bridged-to-native transition shares: a bridged debit and a native mint.
    ///  Emits nothing; the caller names the movement.
    function _moveBridgedToNative(bytes memory fromWallet, address holder, uint256 amount)
        private
        returns (bytes32 fromKey)
    {
        require(holder != address(0), ErrorsLib.ZeroAddress());
        fromKey = WalletKeyLib.satelliteKey(fromWallet);

        TokenStorage storage s = _tokenStorage();
        _debitBridged(s, fromWallet, fromKey, amount);
        s.totalBridged -= amount;
        ERC20Upgradeable._update(address(0), holder, amount);
    }

    function _debitBridged(TokenStorage storage s, bytes memory wallet, bytes32 key, uint256 amount) private {
        uint256 balance = s.bridgedBalance[key];
        require(amount <= balance, ErrorsLib.InsufficientBridgedBalance(wallet, balance, amount));
        s.bridgedBalance[key] = balance - amount;
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
    ///
    ///  A token with supply keeps its registry. The compliance attributes every position through it, so a
    ///  registry that binds wallets differently would leave positions under identities no wallet resolves
    ///  to any more. Wallet bindings are changed in the registry the token has, never by swapping it.
    function _setIdentityRegistry(address identityRegistryAddress)
        internal
        override
        onlySharedAuthority(identityRegistryAddress)
    {
        require(address(_getIdentityRegistry()) == address(0) || totalSupply() == 0, ErrorsLib.TokenCirculating());
        require(
            ERC165Checker.supportsInterface(identityRegistryAddress, type(IERC3643IdentityRegistry).interfaceId),
            ErrorsLib.InvalidIdentityRegistry()
        );

        super._setIdentityRegistry(identityRegistryAddress);
    }

    /// @dev Adds T-REX validation and the bind/unbind handshake to the standard setter. A compliance
    ///  already bound to a different token would make every transferred/created/destroyed hook revert
    ///  (onlyBoundedToken), silently breaking transfers after the swap.
    ///
    ///  A token with supply keeps its compliance. The compliance keeps every identity's position from the
    ///  token's first mint and has no seeding step, so a new one would start every holder at zero and every
    ///  rule over the ledger would be wrong from the first transfer. A circulating token's compliance is
    ///  upgraded in place through its beacon, or changed through its modules.
    function _setCompliance(address complianceAddress) internal override onlySharedAuthority(complianceAddress) {
        require(address(_getCompliance()) == address(0) || totalSupply() == 0, ErrorsLib.TokenCirculating());

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
    /// @dev Carries its own `nonReentrant` and `whenNotPaused` because it reimplements the base body
    ///  instead of calling `super`, so the base modifiers never run on this path. {_recoveryAddress} does
    ///  call `super` and inherits both, which is why it is not marked here.
    function _forcedTransfer(address from, address to, uint256 amount)
        internal
        override
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        require(_getIdentityRegistry().isVerified(to), ErrorsLib.UnverifiedIdentity());
        _forceUpdate(from, to, amount);
        emit EventsLib.ForcedTransfer(_msgSender());
        _getCompliance().transferred(from, to, amount);
        return true;
    }

    /// @dev The new wallet is registered only when it resolves nowhere, so a wallet the global registry
    ///  already binds keeps following that binding rather than a local copy. Only local entries can be
    ///  deleted, so the lost wallet is reported for deletion only when it is locally registered. Country is
    ///  passed as 0 rather than read from the lost wallet, because T-REX stores none; drop this override if
    ///  country storage comes back, so the base reads the real value again.
    function _registerRecoveredWallet(address lostWallet, address newWallet, address investorOnchainID)
        internal
        override
        returns (bool)
    {
        IERC3643IdentityRegistry registry = _getIdentityRegistry();
        if (!registry.contains(newWallet)) {
            registry.registerIdentity(newWallet, IIdentity(investorOnchainID), 0);
        }
        return ITREXRegistry(address(registry)).isLocallyRegistered(lostWallet);
    }

    /// @inheritdoc TREXMessaging
    /// @dev The destination is structural: the bound compliance owns the slot lifecycle, so an attributed
    ///      settlement goes there and nowhere else. It is forwarded as decoded; classifying it against
    ///      the stored validation is the compliance's business, not the token's.
    ///
    ///      While the token is paused nothing is applied: the delivery reverts and stays deliverable, so an
    ///      incident under investigation settles nothing. When the compliance reports a replayed or a never-issued
    ///      settlement, the token halts itself through its pause: the interop layer is misbehaving and every
    ///      notification is suspect until an agent has investigated, resolved and called `unpause`.
    function _handleSettlement(bytes32 chainKey, MessageTypesLib.SettlementNotification memory notification)
        internal
        override
        whenNotPaused
    {
        bool halt = ISettlementHandler(address(_getCompliance())).handleSettlement(chainKey, notification);
        if (halt) _pause();
    }

    /// @inheritdoc TREXMessaging
    /// @dev The recall path: credits the holder's native wallet against a satellite's burn proof.
    ///
    /// The path must check that the destination wallet is linked to the same identity as the burned one,
    /// because a recall moves location and never ownership, then consume the proof through {_recall}.
    /// The identity link and the call into the ledger arrive with the movement types; until then the
    /// proof is attributed, checked for a destination, and announced with its fields intact, without
    /// touching the ledger.
    function _handleBurnProof(bytes32 chainKey, MessageTypesLib.BurnProof memory proof) internal virtual override {
        require(proof.nativeWallet != address(0), ErrorsLib.ZeroAddress());

        emit EventsLib.BurnProofReceived(chainKey, proof.burnedWallet, proof.nativeWallet, proof.amount);
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
