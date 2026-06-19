// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Token } from "contracts/token/Token.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @title TokenHarness
/// @notice Thin Certora harness over {Token}. It adds *view-only* accessors so CVL can reason about the
///         ERC-7201 namespaced state (frozen amounts, free balance, wired authority) without storage hooks.
///
///         The only override is {_checkCanCall}: production resolves the AccessManager via
///         `AuthorityUtils.canCallWithDelay`, which reaches the authority through a raw inline-assembly
///         `staticcall`. Certora cannot match a signature summary against that opaque low-level call, so the
///         allow/deny result is havoced to NONDET and every `restricted` method appears to bypass its gate.
///         This override performs the *same* semantics — `canCall(caller) == false  =>  revert
///         AccessManagedUnauthorized` under the suite's `executionDelay == 0` model — but via a typed
///         high-level `IAccessManager.canCall` call that the spec's `_.canCall` summary can intercept. No
///         token accounting logic is changed.
///
///         NOTE: this branch removed the ERC-2771 meta-tx surface, so there is no `trustedForwarder` accessor
///         here and `_msgSender() == msg.sender` unconditionally.
contract TokenHarness is Token {

    /// @return the AccessManager wired as this token's authority (AccessManagedUpgradeable.authority()).
    function authorityAddress() external view returns (address) {
        return authority();
    }

    /// @dev Faithful, summarisable re-statement of the OZ `restricted` gate (delay-free path). See contract
    ///      natspec for why the production `AuthorityUtils` path is not directly verifiable.
    function _checkCanCall(address caller, bytes calldata data) internal view override {
        (bool immediate,) = IAccessManager(authority()).canCall(caller, address(this), bytes4(data[0:4]));
        require(immediate, IAccessManaged.AccessManagedUnauthorized(caller));
    }

    /// @return frozen the partial-freeze amount recorded for `user`.
    function frozenAmount(address user) external view returns (uint256) {
        return this.getFrozenTokens(user);
    }

    /// @return the spendable balance: balanceOf(user) - frozenTokens(user). Reverts on underflow, which itself
    ///         is the property INV-3 (frozen never exceeds balance) guarantees can never happen.
    function freeBalanceOf(address user) external view returns (uint256) {
        return balanceOf(user) - this.getFrozenTokens(user);
    }

    /// @return the compliance contract address bound to the token.
    function complianceAddress() external view returns (address) {
        return address(this.compliance());
    }

    /// @return the identity registry address bound to the token.
    function identityRegistryAddress() external view returns (address) {
        return address(this.identityRegistry());
    }

}
