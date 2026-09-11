// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Token } from "contracts/token/Token.sol";

/// @title TokenLedgerHarness
/// @notice Exposes the token's internal ledger transitions so tests can drive them before any flow references
///         them. Every entry point authorizes against the mint role, so the existing agent drives all three.
contract TokenLedgerHarness is Token {

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

}
