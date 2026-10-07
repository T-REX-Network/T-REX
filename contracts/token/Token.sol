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

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643Compliance } from "../ERC-3643/IERC3643Compliance.sol";
import { ERC3643Token } from "../ERC-3643/base/ERC3643Token.sol";
import { IModularCompliance } from "../compliance/modular/IModularCompliance.sol";
import { MovementKindLib } from "../compliance/modular/MovementKindLib.sol";
import { ITREXMessaging } from "../interop/ITREXMessaging.sol";
import { TREXMessaging } from "../interop/TREXMessaging.sol";
import { TREXMessagingLib } from "../interop/TREXMessagingLib.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../utils/AccessManagedOwnableUpgradeable.sol";
import { IToken } from "./IToken.sol";
import { TokenGuardsLib } from "./TokenGuardsLib.sol";
import { TokenLedgerLib } from "./TokenLedgerLib.sol";
import { TokenRecoveryLib } from "./TokenRecoveryLib.sol";

/// @title Token
/// @dev The T-REX security token: {ERC3643Token} plus AccessManager authorization, validation on the
/// collaborator setters, the spender check on `transferFrom`, the extra recovery preconditions,
/// ERC-2612 permit, ERC-165, and the bridged ledger the ERC-7786 messaging endpoint settles onto.
contract Token is ERC3643Token, ERC20PermitUpgradeable, AccessManagedOwnableUpgradeable, TREXMessaging, IToken {

    string internal constant VERSION = "5.0.0";

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

        TokenLedgerLib.layout().decimals = tokenDecimals;
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
        return TokenLedgerLib.layout().decimals;
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
        _settle(from, to, amount, validationId);
    }

    /// @inheritdoc IToken
    function holdInTransit(bytes calldata from, uint256 amount, uint256 validationId, uint256 reserved)
        external
        whenNotPaused
    {
        require(_msgSender() == address(_getCompliance()), ErrorsLib.OnlyBoundCompliance());
        TokenLedgerLib.holdInTransit(from, amount, validationId, reserved);
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
        return super.totalSupply() + TokenLedgerLib.layout().totalBridged;
    }

    /// @inheritdoc IToken
    function freeBalanceOf(address wallet) public view returns (uint256) {
        return balanceOf(wallet) - _getFrozenTokens(wallet);
    }

    /// @inheritdoc IToken
    function bridgedBalanceOf(bytes calldata wallet) external view returns (uint256) {
        return TokenLedgerLib.bridgedBalanceOf(wallet);
    }

    /// @inheritdoc IToken
    function returnHeldInTransit(bytes calldata to, uint256 validationId) external whenNotPaused {
        require(_msgSender() == address(_getCompliance()), ErrorsLib.OnlyBoundCompliance());
        TokenLedgerLib.returnHeldInTransit(to, validationId);
    }

    /// @inheritdoc IToken
    function reservedOf(bytes calldata wallet) external view returns (uint256) {
        return TokenLedgerLib.reservedOf(wallet);
    }

    /// @inheritdoc IToken
    function availableOf(bytes calldata wallet) public view returns (uint256) {
        return TokenLedgerLib.availableOf(wallet);
    }

    /// @inheritdoc IToken
    /// @dev No pause guard: a reservation moves no tokens, it only records what a validation may later draw.
    ///  Issuance itself is allowed while the token is paused, and the reservation has to follow it, or a paused
    ///  token would issue validations with nothing held against the wallet they draw from.
    function reserveForValidation(bytes calldata wallet, uint256 amount) external {
        require(_msgSender() == address(_getCompliance()), ErrorsLib.OnlyBoundCompliance());
        TokenLedgerLib.reserve(wallet, amount);
    }

    /// @inheritdoc IToken
    /// @dev No pause guard, for the reason `reserveForValidation` gives: a discard while the token is paused
    ///  must still give the wallet its room back.
    function releaseFromValidation(bytes calldata wallet, uint256 amount) external {
        require(_msgSender() == address(_getCompliance()), ErrorsLib.OnlyBoundCompliance());
        TokenLedgerLib.release(wallet, amount);
    }

    /// @inheritdoc IToken
    function totalBridged() external view returns (uint256) {
        return TokenLedgerLib.layout().totalBridged;
    }

    /// @inheritdoc IToken
    function inTransitOf(uint256 validationId) external view returns (uint256) {
        return TokenLedgerLib.layout().inTransit[validationId];
    }

    /// @inheritdoc IToken
    function totalInTransit() external view returns (uint256) {
        return TokenLedgerLib.layout().totalInTransit;
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
        require(holder != address(0), ErrorsLib.ZeroAddress());
        bytes32 toKey = TokenLedgerLib.creditFromNative(holder, toWallet, amount, freeBalanceOf(holder));
        ERC20Upgradeable._update(holder, address(0), amount);

        emit EventsLib.DelegatedOut(holder, toKey, toWallet, amount);
    }

    /// @dev Brings `amount` back from `fromWallet`, a wallet on a satellite chain, onto `holder`'s free balance:
    ///  a bridged debit and a native mint (`Transfer(0x0, holder)`). The mirror of {_delegateOut}, applied on a
    ///  consumed burn proof; the flow checks that `holder` belongs to the burned wallet's identity, so ownership
    ///  does not move here either. A settlement leg that crosses identities is {_settle}.
    function _recall(bytes memory fromWallet, address holder, uint256 amount) internal {
        bytes32 fromKey = TokenLedgerLib.debitToNative(fromWallet, holder, amount);
        ERC20Upgradeable._update(address(0), holder, amount);

        emit EventsLib.Recalled(fromKey, holder, fromWallet, amount);
    }

    /// @dev Applies the settled leg of a validation: `from`'s satellite position down, and either `to`'s free
    ///  balance up when `to` is on the reference chain (a native mint, `Transfer(0x0, to)`, and a distinct event
    ///  because ownership moves between identities), or `to`'s satellite position up otherwise (a bridged
    ///  transfer, nothing native). `validationId` is the validation the settlement consumed. The calling flow
    ///  owns the lifecycle; the ledger checks the buckets and the envelopes only. There is no mirror leaving a
    ///  native wallet: the compliance issues no validation whose sender is native, so the satellite executing
    ///  one always holds the position it moves. The one path every settlement takes, {settleValidation} adding
    ///  only the caller and pause checks.
    function _settle(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId) internal {
        (bool toNative, address recipient, bytes32 fromKey) = TokenLedgerLib.settle(from, to, amount, validationId);
        if (!toNative) return;

        ERC20Upgradeable._update(address(0), recipient, amount);

        emit EventsLib.SettledToNative(fromKey, recipient, validationId, from, amount);
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
        TokenGuardsLib.checkIdentityRegistry(address(_getIdentityRegistry()), identityRegistryAddress, totalSupply());

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
        TokenGuardsLib.prepareCompliance(address(_getCompliance()), complianceAddress, totalSupply());

        // The event lands after the bind so that it only ever reports a binding that succeeded.
        _writeCompliance(complianceAddress);
        IERC3643Compliance(complianceAddress).bindToken(address(this));
        emit ComplianceAdded(complianceAddress);
    }

    /// @dev The standard recovery with the T-REX preconditions in front, a wallet may not be recovered onto
    ///  itself, there must be something to recover, and at least one of the two wallets must already be known
    ///  to the identity registry, and the move reported to the modular compliance as an agent's movement, so
    ///  the trackers can leave it out of what they count against the investor. The steps are the base's, see
    ///  {ERC3643Token-_recoveryAddress}; only the compliance call differs.
    /// @dev Carries its own `nonReentrant` and `whenNotPaused` because it reimplements the base body instead
    ///  of calling `super`, like {_forcedTransfer}.
    function _recoveryAddress(address lostWallet, address newWallet, address investorOnchainId)
        internal
        override
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        uint256 investorTokens = balanceOf(lostWallet);
        TokenRecoveryLib.checkRecovery(_getIdentityRegistry(), lostWallet, newWallet, investorOnchainId, investorTokens);

        uint256 frozenTokens = _erc3643TokenStorage().frozenTokens[lostWallet];

        // The new wallet is registered before the move and the lost wallet is deleted after the compliance
        // call, so that during `agentTransferred` both wallets still resolve to the identities that hold and
        // receive the tokens. A module keyed by identity can then debit and credit through the registry.
        bool migrateIdentity = _registerRecoveredWallet(lostWallet, newWallet, investorOnchainId);

        _forceUpdate(lostWallet, newWallet, investorTokens);
        _migrateFrozenAmount(newWallet, frozenTokens);
        _migrateAddressFrozen(lostWallet, newWallet);

        IModularCompliance(address(_getCompliance()))
            .agentTransferred(lostWallet, newWallet, investorTokens, MovementKindLib.RECOVERY);

        if (migrateIdentity) _getIdentityRegistry().deleteIdentity(lostWallet);

        emit RecoverySuccess(lostWallet, newWallet, investorOnchainId);
        return true;
    }

    /// @dev Adds the T-REX `ForcedTransfer` event to the standard forced transfer. It is emitted before
    ///  the compliance hook so that no module log can land between `Transfer` and this event.
    /// @dev Carries its own `nonReentrant` and `whenNotPaused` because it reimplements the base body
    ///  instead of calling `super`, so the base modifiers never run on this path. {_recoveryAddress} does
    ///  the same.
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
        // Reported as an agent's movement, so a module counting what the investor does can leave it out.
        IModularCompliance(address(_getCompliance()))
            .agentTransferred(from, to, amount, MovementKindLib.FORCED_TRANSFER);
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
        return TokenRecoveryLib.registerRecoveredWallet(
            _getIdentityRegistry(), lostWallet, newWallet, investorOnchainID
        );
    }

    /// @inheritdoc TREXMessaging
    /// @dev The destination is structural: the bound compliance owns the slot lifecycle, so an attributed
    ///      settlement goes there and nowhere else. It is forwarded as decoded, by the linked messaging
    ///      library and with the token as the caller; classifying it against the stored validation is the
    ///      compliance's business, not the token's.
    ///
    ///      While the token is paused nothing is applied: the delivery reverts and stays deliverable, so an
    ///      incident under investigation settles nothing. When the compliance reports a replayed or a never-issued
    ///      settlement, the token halts itself through its pause: the interop layer is misbehaving and every
    ///      notification is suspect until an agent has investigated, resolved and called `unpause`.
    function _handleSettlement(bytes32 chainKey, bytes memory body) internal override whenNotPaused nonReentrant {
        bool halt = TREXMessagingLib.forwardSettlement(address(_getCompliance()), chainKey, body);
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
    function _handleBurnProof(bytes32 chainKey, bytes memory body) internal virtual override {
        TREXMessagingLib.announceBurnProof(chainKey, body);
    }

    /// @inheritdoc ERC3643Token
    function _version() internal pure override returns (string memory) {
        return VERSION;
    }

    function _EIP712Name() internal view override returns (string memory) {
        return name();
    }

}
