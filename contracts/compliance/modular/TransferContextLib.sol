// SPDX-License-Identifier: GPL-3.0
//
// T-REX Smart Contracts
// The ERC-3643 token suite of the T-REX ecosystem.
//
// Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")
//
// This file is part of the T-REX smart contract suite.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.30;

import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { MovementKindLib } from "./MovementKindLib.sol";
import { IModule } from "./modules/IModule.sol";

/// @title TransferContextLib
/// @dev The three shapes a movement takes before a module sees it. One constructor per kind, each filled
///  completely where it is built: a rule is asked the same struct whatever produced the movement.
library TransferContextLib {

    /// @dev A native movement: a transfer, a mint (zero `from`) or a burn (zero `to`), for `amount` exactly.
    ///  `kind` is what the token reported, which the zero sides alone cannot tell: a forced transfer and a
    ///  recovery move between two non-zero wallets exactly like a transfer does.
    function native(
        address compliance,
        uint8 kind,
        address fromIdentity,
        address toIdentity,
        address from,
        address to,
        uint256 amount,
        bytes memory spender
    ) internal pure returns (IModule.TransferContext memory ctx) {
        ctx.compliance = compliance;
        ctx.kind = kind;
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
        ctx.kind = MovementKindLib.CROSS_CHAIN;
        ctx.isIssuance = true;
        ctx.spender = spender;
    }

    /// @dev A validation that settled: the amount a satellite actually executed, between two satellite wallets
    ///  or landing on a native one, executed by the spender the validation names.
    function settlement(
        address compliance,
        address fromIdentity,
        address toIdentity,
        bytes32 fromWallet,
        bytes32 toWallet,
        uint256 amount,
        bytes memory spender
    ) internal pure returns (IModule.TransferContext memory ctx) {
        ctx.compliance = compliance;
        ctx.fromIdentity = fromIdentity;
        ctx.toIdentity = toIdentity;
        ctx.fromWallet = fromWallet;
        ctx.toWallet = toWallet;
        ctx.amountMin = amount;
        ctx.amountMax = amount;
        ctx.kind = MovementKindLib.CROSS_CHAIN;
        ctx.spender = spender;
    }

}
