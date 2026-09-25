// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { IModule } from "./modules/IModule.sol";

/// @title TransferContextLib
/// @dev The three shapes a movement takes before a module sees it. One constructor per kind, each filled
///  completely where it is built: a rule is asked the same struct whatever produced the movement, and no
///  caller patches a field afterwards.
library TransferContextLib {

    /// @dev A native movement: a transfer, a mint (zero `from`) or a burn (zero `to`), for `amount` exactly.
    function native(
        address compliance,
        address fromIdentity,
        address toIdentity,
        address from,
        address to,
        uint256 amount,
        bytes memory spender
    ) internal pure returns (IModule.TransferContext memory ctx) {
        ctx.compliance = compliance;
        ctx.fromIdentity = fromIdentity;
        ctx.toIdentity = toIdentity;
        if (from != address(0)) ctx.fromWallet = WalletKeyLib.walletId(from);
        if (to != address(0)) ctx.toWallet = WalletKeyLib.walletId(to);
        ctx.amountMin = amount;
        ctx.amountMax = amount;
        ctx.spender = spender;
    }

    /// @dev A cross-chain validation being issued: a range the satellite will execute some amount inside.
    function issuance(
        address compliance,
        address fromIdentity,
        address toIdentity,
        bytes32 fromWallet,
        bytes32 toWallet,
        uint256 amountMin,
        uint256 amountMax,
        bytes memory spender
    ) internal pure returns (IModule.TransferContext memory ctx) {
        ctx.compliance = compliance;
        ctx.fromIdentity = fromIdentity;
        ctx.toIdentity = toIdentity;
        ctx.fromWallet = fromWallet;
        ctx.toWallet = toWallet;
        ctx.amountMin = amountMin;
        ctx.amountMax = amountMax;
        ctx.isIssuance = true;
        ctx.spender = spender;
    }

    /// @dev A validation that settled: the amount a satellite actually executed, between two satellite wallets
    ///  or landing on a native one.
    function settlement(
        address compliance,
        address fromIdentity,
        address toIdentity,
        bytes32 fromWallet,
        bytes32 toWallet,
        uint256 amount
    ) internal pure returns (IModule.TransferContext memory ctx) {
        ctx.compliance = compliance;
        ctx.fromIdentity = fromIdentity;
        ctx.toIdentity = toIdentity;
        ctx.fromWallet = fromWallet;
        ctx.toWallet = toWallet;
        ctx.amountMin = amount;
        ctx.amountMax = amount;
    }

}
