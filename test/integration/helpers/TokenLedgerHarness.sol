// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { Token } from "contracts/token/Token.sol";
import { TokenLedgerLib } from "contracts/token/TokenLedgerLib.sol";

/// @title TokenLedgerHarness
/// @notice Exposes the token's internal ledger transitions so tests can drive them before any flow references
///         them. Every entry point authorizes against the mint role, so the existing agent drives them all.
///         Settlements go through `Token._settle`, the same path `settleValidation` takes in production, with
///         only the bound-compliance and pause checks skipped.
contract TokenLedgerHarness is Token {

    /// @dev The batch-authorization shape the ERC-3643 base reaches through `_checkTokenAdmin`, restated
    ///  here as a modifier so each entry point authorizes against the mint role rather than its own selector.
    modifier restrictedFor(bytes4 selector) {
        _checkCanCallSelector(selector);
        _;
    }

    /// @dev The ledger half of `delegateOut` alone: a bridged credit and a native burn, with none of the checks
    ///  `delegateOut` and `TokenDelegationLib` add (amount, pause, freeze, linked wallets, compliance, instruction).
    function ledgerDelegateOut(address holder, bytes calldata toWallet, uint256 amount)
        external
        restrictedFor(this.mint.selector)
    {
        require(holder != address(0), ErrorsLib.ZeroAddress());
        bytes32 toKey = TokenLedgerLib.creditFromNative(holder, toWallet, amount, freeBalanceOf(holder));
        ERC20Upgradeable._update(holder, address(0), amount);

        emit EventsLib.DelegatedOut(holder, toKey, 0, toWallet, amount);
    }

    /// @dev The ledger half of a recall alone: a bridged debit and a native mint, with none of the checks the burn
    ///  proof path adds.
    function ledgerRecall(bytes calldata fromWallet, address holder, uint256 amount)
        external
        restrictedFor(this.mint.selector)
    {
        bytes32 fromKey = TokenLedgerLib.debitToNative(fromWallet, holder, amount);
        ERC20Upgradeable._update(address(0), holder, amount);

        emit EventsLib.Recalled(fromKey, holder, fromWallet, amount);
    }

    function bridgedTransfer(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId)
        external
        restrictedFor(this.mint.selector)
    {
        _settle(from, to, amount, validationId);
    }

    function settleToNative(bytes calldata fromWallet, address to, uint256 amount, uint256 validationId)
        external
        restrictedFor(this.mint.selector)
    {
        // Self-call so the freshly built native envelope reaches `_settle` as calldata, like every other one.
        this.settleSelf(fromWallet, InteroperableAddress.formatEvmV1(block.chainid, to), amount, validationId);
    }

    /// @dev The second hop of {settleToNative}. Reachable from this contract only.
    function settleSelf(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId) external {
        require(msg.sender == address(this), "TokenLedgerHarness: self-call only");
        _settle(from, to, amount, validationId);
    }

}
