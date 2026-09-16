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
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IERC3643 } from "../IERC3643.sol";
import { IERC3643Compliance } from "../IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "../IERC3643IdentityRegistry.sol";

/// @title ERC3643Token
/// @notice Standard-only base implementing the ERC-3643 token surface.
/// @dev Layer 2 of the ERC-3643 / T-REX split (see issue #65). Implements exactly the functions `IERC3643`
///  declares -- ERC-20, pause, address and partial freeze, forced transfer, recovery, mint and burn, the
///  batch variants, and the registry / compliance / ONCHAINID setters -- over state held in its own
///  ERC-7201 namespace.
///
///  Storage shape follows OpenZeppelin's proposed `ERC3643Storage`
///  (openzeppelin-contracts#5838): two separate frozen mappings rather than one packed struct, and no
///  name / symbol / decimals, which belong to the ERC-20 base. Issue #54 records the reasoning. The
///  namespace string is provisional; see `docs/erc3643-oz-swap.md` for the migration step.
///
///  Extension happens through the internal hooks, never by overriding the external functions. The hook
///  names deliberately match OpenZeppelin's (`_update`, `_forcedTransfer`, `_recoveryAddress`,
///  `_freezePartialTokens`, `_unfreezePartialTokens`, `_setAddressFrozen`, `_setIdentityRegistry`,
///  `_setCompliance`, `_setOnchainID`, `_emitUpdatedTokenInformation`) so that swapping this base for
///  theirs does not rename anything in the extension layer.
///
///  Divergences from openzeppelin-contracts#5838 as it stands, each a deliberate T-REX behavior that the
///  swap checklist must re-decide (see the swap document):
///
///  1. Mint and burn are permitted while paused; OZ's `whenNotPaused` on `_update` blocks them. T-REX
///     pauses transfers, not issuance and redemption.
///  2. Compliance is notified of mints through `created` and burns through `destroyed`; OZ calls only
///     `transferred`, and only on transfers.
///  3. A burn does not require `isVerified(address(0))`; OZ's `_update` would revert on every burn.
///  4. A mint reaches `canTransfer` with `from` at the zero address, so distribution rules stay enforced
///     at issuance. This is the convention modules read to tell a mint from a transfer.
///  5. Authorization is delegated to `_checkTokenAdmin`, not OZ's `Ownable` plus agent role.
abstract contract ERC3643Token is ERC20PermitUpgradeable, PausableUpgradeable, IERC3643 {

    /// @custom:storage-location erc7201:erc3643.storage.ERC3643Token
    struct ERC3643TokenStorage {
        mapping(address account => bool) frozen;
        mapping(address account => uint256) frozenTokens;
        IERC3643IdentityRegistry identityRegistry;
        IERC3643Compliance compliance;
        address onchainId;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.ERC3643Token")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ERC3643_TOKEN_STORAGE_LOCATION =
        0x1c6ea0581535d63a38daa138246885c0e308b5f6335af4548c056841c5c18f00;

    /// @dev Thrown when a wallet's identity is not verified by the identity registry.
    error UnverifiedIdentity();

    /// @dev Thrown when the compliance rules reject a transfer.
    error ComplianceNotFollowed();

    /// @dev Thrown when a transfer involves a frozen wallet.
    error FrozenWallet(address wallet);

    /// @dev Thrown when unfreezing more tokens than are frozen.
    error AmountAboveFrozenTokens(uint256 amount, uint256 frozenAmount);

    /* ----- Token information ----- */

    /// @inheritdoc IERC3643
    function setOnchainID(address _onchainID) external virtual {
        _checkTokenAdmin();
        _setOnchainID(_onchainID);
    }

    /// @inheritdoc IERC3643
    function setIdentityRegistry(address _identityRegistry) external virtual {
        _checkTokenAdmin();
        _setIdentityRegistry(_identityRegistry);
    }

    /// @inheritdoc IERC3643
    function setCompliance(address _compliance) external virtual {
        _checkTokenAdmin();
        _setCompliance(_compliance);
    }

    /// @inheritdoc IERC3643
    function onchainID() external view virtual returns (address) {
        return _erc3643TokenStorage().onchainId;
    }

    /// @inheritdoc IERC3643
    function identityRegistry() external view virtual returns (IERC3643IdentityRegistry) {
        return _getIdentityRegistry();
    }

    /// @inheritdoc IERC3643
    function compliance() external view virtual returns (IERC3643Compliance) {
        return _getCompliance();
    }

    /* ----- Pause ----- */

    /// @inheritdoc IERC3643
    function pause() external virtual {
        _checkTokenAdmin();
        _pause();
    }

    /// @inheritdoc IERC3643
    function unpause() external virtual {
        _checkTokenAdmin();
        _unpause();
    }

    /* ----- Mint and burn ----- */

    /// @inheritdoc IERC3643
    function mint(address _to, uint256 _amount) external virtual {
        _checkTokenAdmin();
        _mint(_to, _amount);
    }

    /// @inheritdoc IERC3643
    function burn(address _userAddress, uint256 _amount) external virtual {
        _checkTokenAdmin();
        _burn(_userAddress, _amount);
    }

    /// @inheritdoc IERC3643
    function batchMint(address[] calldata _toList, uint256[] calldata _amounts) external virtual {
        _checkTokenAdmin();
        for (uint256 i = 0; i < _toList.length; i++) {
            _mint(_toList[i], _amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function batchBurn(address[] calldata _userAddresses, uint256[] calldata _amounts) external virtual {
        _checkTokenAdmin();
        for (uint256 i = 0; i < _userAddresses.length; i++) {
            _burn(_userAddresses[i], _amounts[i]);
        }
    }

    /* ----- Freezing ----- */

    /// @inheritdoc IERC3643
    function setAddressFrozen(address _userAddress, bool _freeze) external virtual {
        _checkTokenAdmin();
        _setAddressFrozen(_userAddress, _freeze);
    }

    /// @inheritdoc IERC3643
    function freezePartialTokens(address _userAddress, uint256 _amount) external virtual {
        _checkTokenAdmin();
        _freezePartialTokens(_userAddress, _amount);
    }

    /// @inheritdoc IERC3643
    function unfreezePartialTokens(address _userAddress, uint256 _amount) external virtual {
        _checkTokenAdmin();
        _unfreezePartialTokens(_userAddress, _amount);
    }

    /// @inheritdoc IERC3643
    function batchSetAddressFrozen(address[] calldata _userAddresses, bool[] calldata _freeze) external virtual {
        _checkTokenAdmin();
        for (uint256 i = 0; i < _userAddresses.length; i++) {
            _setAddressFrozen(_userAddresses[i], _freeze[i]);
        }
    }

    /// @inheritdoc IERC3643
    function batchFreezePartialTokens(address[] calldata _userAddresses, uint256[] calldata _amounts) external virtual {
        _checkTokenAdmin();
        for (uint256 i = 0; i < _userAddresses.length; i++) {
            _freezePartialTokens(_userAddresses[i], _amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function batchUnfreezePartialTokens(address[] calldata _userAddresses, uint256[] calldata _amounts)
        external
        virtual
    {
        _checkTokenAdmin();
        for (uint256 i = 0; i < _userAddresses.length; i++) {
            _unfreezePartialTokens(_userAddresses[i], _amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function isFrozen(address _userAddress) external view virtual returns (bool) {
        return _isFrozen(_userAddress);
    }

    /// @inheritdoc IERC3643
    function getFrozenTokens(address _userAddress) external view virtual returns (uint256) {
        return _getFrozenTokens(_userAddress);
    }

    /* ----- Transfers ----- */

    /// @inheritdoc IERC3643
    function forcedTransfer(address _from, address _to, uint256 _amount) external virtual returns (bool) {
        _checkTokenAdmin();
        return _forcedTransfer(_from, _to, _amount);
    }

    /// @inheritdoc IERC3643
    function batchForcedTransfer(address[] calldata _fromList, address[] calldata _toList, uint256[] calldata _amounts)
        external
        virtual
    {
        _checkTokenAdmin();
        for (uint256 i = 0; i < _fromList.length; i++) {
            _forcedTransfer(_fromList[i], _toList[i], _amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function batchTransfer(address[] calldata _toList, uint256[] calldata _amounts) external virtual {
        for (uint256 i = 0; i < _toList.length; i++) {
            transfer(_toList[i], _amounts[i]);
        }
    }

    /// @inheritdoc IERC3643
    function recoveryAddress(address _lostWallet, address _newWallet, address _investorOnchainID)
        external
        virtual
        returns (bool)
    {
        _checkTokenAdmin();
        return _recoveryAddress(_lostWallet, _newWallet, _investorOnchainID);
    }

    /* ----- ERC-20 surface ----- */

    /// @inheritdoc IERC3643
    function paused() public view virtual override(PausableUpgradeable, IERC3643) returns (bool) {
        return super.paused();
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return super.decimals();
    }

    /* ----- Extension hooks ----- */

    /// @dev Authorization hook for every privileged function of this base. Reverts when the caller may
    ///  not administer the token. Left abstract on purpose: the standard specifies no access model, and
    ///  T-REX uses an AccessManager where OpenZeppelin's base uses `Ownable` plus an agent role.
    function _checkTokenAdmin() internal virtual;

    /// @dev Sets the token's ONCHAINID. The zero address means no ONCHAINID is bound.
    function _setOnchainID(address onchainId_) internal virtual {
        _erc3643TokenStorage().onchainId = onchainId_;
        _emitUpdatedTokenInformation();
    }

    /// @dev Points the token at a new identity registry. A wrong registry halts the token, since
    ///  `isVerified` runs on every transfer; derived contracts add their own validation here.
    function _setIdentityRegistry(address identityRegistry_) internal virtual {
        _erc3643TokenStorage().identityRegistry = IERC3643IdentityRegistry(identityRegistry_);
        emit IdentityRegistryAdded(identityRegistry_);
    }

    /// @dev Points the token at a new compliance contract.
    function _setCompliance(address compliance_) internal virtual {
        _erc3643TokenStorage().compliance = IERC3643Compliance(compliance_);
        emit ComplianceAdded(compliance_);
    }

    /// @dev Freezes part of a wallet's balance. The frozen amount may never exceed the balance.
    function _freezePartialTokens(address userAddress, uint256 amount) internal virtual {
        ERC3643TokenStorage storage s = _erc3643TokenStorage();
        uint256 balance = balanceOf(userAddress);
        require(
            balance >= s.frozenTokens[userAddress] + amount,
            IERC20Errors.ERC20InsufficientBalance(userAddress, balance, amount)
        );
        s.frozenTokens[userAddress] += amount;
        emit TokensFrozen(userAddress, amount);
    }

    /// @dev Releases part of a wallet's frozen balance.
    function _unfreezePartialTokens(address userAddress, uint256 amount) internal virtual {
        ERC3643TokenStorage storage s = _erc3643TokenStorage();
        uint256 frozenAmount = s.frozenTokens[userAddress];
        require(frozenAmount >= amount, AmountAboveFrozenTokens(amount, frozenAmount));
        s.frozenTokens[userAddress] = frozenAmount - amount;
        emit TokensUnfrozen(userAddress, amount);
    }

    /// @dev Sets a wallet's frozen flag. `owner_` is the actor recorded in the event.
    function _setAddressFrozen(address userAddress, bool freeze, address owner_) internal virtual {
        _erc3643TokenStorage().frozen[userAddress] = freeze;
        emit AddressFrozen(userAddress, freeze, owner_);
    }

    /// @dev Sets a wallet's frozen flag, recording `_msgSender()` as the actor.
    function _setAddressFrozen(address userAddress, bool freeze) internal virtual {
        _setAddressFrozen(userAddress, freeze, _msgSender());
    }

    /// @dev Moves tokens irrespective of freezes, unfreezing just enough to cover the amount, then tells
    ///  compliance the move happened. Recipient identity is still verified.
    function _forcedTransfer(address from, address to, uint256 amount) internal virtual returns (bool) {
        require(_getIdentityRegistry().isVerified(to), UnverifiedIdentity());
        _forceUpdate(from, to, amount);
        _getCompliance().transferred(from, to, amount);
        return true;
    }

    /// @dev Moves a lost wallet's balance, freezes and identity onto a new wallet.
    function _recoveryAddress(address lostWallet, address newWallet, address investorOnchainID)
        internal
        virtual
        returns (bool)
    {
        ERC3643TokenStorage storage s = _erc3643TokenStorage();
        uint256 investorTokens = balanceOf(lostWallet);
        uint256 frozenTokens = s.frozenTokens[lostWallet];

        _forceUpdate(lostWallet, newWallet, investorTokens);
        _migrateFrozenAmount(newWallet, frozenTokens);
        _migrateAddressFrozen(lostWallet, newWallet);
        _migrateIdentity(lostWallet, newWallet, investorOnchainID);

        // Called after the migrations so rules see the final state, and before the event so that no
        // downstream log can land between the recovery's own logs and `RecoverySuccess`.
        _getCompliance().transferred(lostWallet, newWallet, investorTokens);

        emit RecoverySuccess(lostWallet, newWallet, investorOnchainID);
        return true;
    }

    /// @dev Carries the lost wallet's frozen-token amount onto the new wallet. The amount is captured by
    ///  the caller before `_forceUpdate` runs, since `_forceUpdate` auto-unfreezes and zeroes the lost wallet.
    function _migrateFrozenAmount(address newWallet, uint256 frozenAmount) internal virtual {
        if (frozenAmount > 0) {
            _erc3643TokenStorage().frozenTokens[newWallet] += frozenAmount;
            emit TokensFrozen(newWallet, frozenAmount);
        }
    }

    /// @dev Carries the address-frozen flag from the lost wallet onto the new wallet (only when the new
    ///  wallet is not already frozen).
    function _migrateAddressFrozen(address lostWallet, address newWallet) internal virtual {
        ERC3643TokenStorage storage s = _erc3643TokenStorage();
        if (s.frozen[lostWallet]) {
            _setAddressFrozen(lostWallet, false, address(this));
            if (!s.frozen[newWallet]) {
                _setAddressFrozen(newWallet, true, address(this));
            }
        }
    }

    /// @dev Moves the on-chain identity from the lost wallet to the new wallet, registering the new
    ///  wallet only when it is not already known to the identity registry.
    function _migrateIdentity(address lostWallet, address newWallet, address investorOnchainID) internal virtual {
        IERC3643IdentityRegistry registry = _getIdentityRegistry();
        if (registry.contains(lostWallet)) {
            if (!registry.contains(newWallet)) {
                registry.registerIdentity(newWallet, IIdentity(investorOnchainID), registry.investorCountry(lostWallet));
            }
            registry.deleteIdentity(lostWallet);
        }
    }

    /// @dev The ERC-20 state transition, extended with the ERC-3643 rules.
    ///
    ///  Transfers are blocked while paused, from or to a frozen wallet, and beyond the free (unfrozen)
    ///  balance. Mints and burns are deliberately permitted while paused: T-REX pauses circulation, not
    ///  issuance and redemption. A burn auto-unfreezes just enough to cover the amount.
    ///
    ///  Identity and compliance are checked for mints and transfers but not burns, and compliance is then
    ///  told which of the three happened. A mint reaches `canTransfer` with `from` at the zero address so
    ///  that distribution rules stay enforced at issuance, which is the convention rules read to tell a
    ///  mint from a transfer.
    function _update(address from, address to, uint256 value) internal virtual override {
        ERC3643TokenStorage storage s = _erc3643TokenStorage();
        bool isMint = from == address(0);
        bool isBurn = to == address(0);

        if (!isMint && !isBurn) {
            _requireNotPaused();
            require(!s.frozen[from], FrozenWallet(from));
            require(!s.frozen[to], FrozenWallet(to));
            uint256 freeBalance = balanceOf(from) - s.frozenTokens[from];
            require(value <= freeBalance, IERC20Errors.ERC20InsufficientBalance(from, freeBalance, value));
        } else if (isBurn) {
            _autoUnfreezeFor(from, value);
        }

        if (!isBurn) {
            require(_getIdentityRegistry().isVerified(to), UnverifiedIdentity());
            require(_getCompliance().canTransfer(from, to, value), ComplianceNotFollowed());
        }

        super._update(from, to, value);

        if (isMint) _getCompliance().created(to, value);
        else if (isBurn) _getCompliance().destroyed(from, value);
        else _getCompliance().transferred(from, to, value);
    }

    /// @dev Moves tokens bypassing {_update}: no pause, freeze, identity or compliance check, and no
    ///  compliance notification. Callers are responsible for notifying compliance themselves, which is
    ///  why `_forcedTransfer` and `_recoveryAddress` each call `transferred` explicitly.
    function _forceUpdate(address from, address to, uint256 value) internal virtual {
        _autoUnfreezeFor(from, value);
        super._update(from, to, value);
    }

    /// @dev Releases just enough of `from`'s frozen balance to let `value` move.
    function _autoUnfreezeFor(address from, uint256 value) internal virtual {
        ERC3643TokenStorage storage s = _erc3643TokenStorage();
        uint256 balance = balanceOf(from);
        require(value <= balance, IERC20Errors.ERC20InsufficientBalance(from, balance, value));
        uint256 freeBalance = balance - s.frozenTokens[from];
        if (value > freeBalance) {
            uint256 toUnfreeze = value - freeBalance;
            s.frozenTokens[from] -= toUnfreeze;
            emit TokensUnfrozen(from, toUnfreeze);
        }
    }

    /// @dev Emits the token information event. Derived contracts supply the version string.
    function _emitUpdatedTokenInformation() internal virtual {
        emit UpdatedTokenInformation(name(), symbol(), decimals(), _version(), _erc3643TokenStorage().onchainId);
    }

    /// @dev The implementation version reported in `UpdatedTokenInformation`.
    function _version() internal view virtual returns (string memory);

    /// @dev Whether a wallet is frozen.
    function _isFrozen(address userAddress) internal view virtual returns (bool) {
        return _erc3643TokenStorage().frozen[userAddress];
    }

    /// @dev The frozen token amount of a wallet.
    function _getFrozenTokens(address userAddress) internal view virtual returns (uint256) {
        return _erc3643TokenStorage().frozenTokens[userAddress];
    }

    /// @dev The identity registry backing verification.
    function _getIdentityRegistry() internal view virtual returns (IERC3643IdentityRegistry) {
        return _erc3643TokenStorage().identityRegistry;
    }

    /// @dev The compliance contract backing the transfer rules.
    function _getCompliance() internal view virtual returns (IERC3643Compliance) {
        return _erc3643TokenStorage().compliance;
    }

    function _erc3643TokenStorage() internal pure returns (ERC3643TokenStorage storage s) {
        assembly ("memory-safe") {
            s.slot := ERC3643_TOKEN_STORAGE_LOCATION
        }
    }

}
