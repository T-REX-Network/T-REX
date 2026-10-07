// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

/// @title MovementKindLib
/// @dev The values `TransferContext.kind` takes: what produced a movement.
///
///  A plain `uint8` rather than an enum, on purpose. Solidity range-checks an enum when it decodes calldata, so
///  a module compiled against six kinds would revert on a seventh and block every movement of that kind until
///  it is upgraded. With a number, a module that meets a kind it was not written for sees an unfamiliar value
///  and decides what to do with it. {IModule} makes that a MUST: a module never reverts on a kind it does not
///  know. What it does instead is the module's choice, and each tracker has to make it on purpose: a counter
///  of investor activity leaves an unknown kind out, a tracker that must see every change of ownership
///  records it.
///
///  Zero is never a kind. A context reports zero only when whoever built it forgot to set the field, which
///  a test then sees instead of a mislabeled movement: a forced transfer read as a plain transfer is the bug
///  this field exists to prevent.
library MovementKindLib {

    /// A wallet-to-wallet transfer the sender or an approved spender executed.
    uint8 internal constant TRANSFER = 1;
    /// An issuance of new tokens. `fromIdentity` and `fromWallet` are zero.
    uint8 internal constant MINT = 2;
    /// A destruction of tokens. `toIdentity` and `toWallet` are zero.
    uint8 internal constant BURN = 3;
    /// A transfer an agent forced. No rule was asked; trackers are told.
    uint8 internal constant FORCED_TRANSFER = 4;
    /// A lost wallet's balance moved to a new wallet by an agent, usually one of the same investor.
    uint8 internal constant RECOVERY = 5;
    /// A movement a satellite executes under a validation: the issuance of that validation while
    /// `isIssuance` is set, its settlement otherwise.
    uint8 internal constant CROSS_CHAIN = 6;

}
