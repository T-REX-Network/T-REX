// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Token } from "contracts/token/Token.sol";

/// @title TokenLedgerHarness
/// @notice Exposes the token's internal ledger transitions so tests can drive them before any flow references
///         them. Every entry point authorizes against the mint role, so the existing agent drives them all.
contract TokenLedgerHarness is Token {

    /// @dev The batch-authorization shape the ERC-3643 base reaches through `_checkTokenAdmin`, restated
    ///  here as a modifier so each entry point authorizes against the mint role rather than its own selector.
    modifier restrictedFor(bytes4 selector) {
        _checkCanCallSelector(selector);
        _;
    }

    function delegateOut(address holder, bytes calldata toWallet, uint256 amount)
        external
        restrictedFor(this.mint.selector)
    {
        _delegateOut(holder, toWallet, amount);
    }

    function recall(bytes calldata fromWallet, address holder, uint256 amount)
        external
        restrictedFor(this.mint.selector)
    {
        _recall(fromWallet, holder, amount);
    }

    function bridgedTransfer(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId)
        external
        restrictedFor(this.mint.selector)
    {
        _bridgedTransfer(from, to, amount, validationId);
    }

    function settleToNative(bytes calldata fromWallet, address to, uint256 amount, uint256 validationId)
        external
        restrictedFor(this.mint.selector)
    {
        _settleToNative(fromWallet, to, amount, validationId);
    }

}
