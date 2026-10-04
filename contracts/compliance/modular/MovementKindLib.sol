// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

/// @title MovementKindLib
/// @dev The values `TransferContext.kind` takes: what produced a movement.
///
///  A plain `uint8` rather than an enum, on purpose. Solidity range-checks an enum when it decodes calldata, so
///  a module compiled against six kinds would revert on a seventh and block every movement of that kind until
///  it is upgraded. With a number, a module that meets a kind it was not written for sees an unfamiliar value
///  and treats it as such; nothing stops the movement. A module never reverts on a kind it does not know.
library MovementKindLib {

    /// A wallet-to-wallet transfer the sender or an approved spender executed.
    uint8 internal constant TRANSFER = 0;
    /// An issuance of new tokens. `fromIdentity` and `fromWallet` are zero.
    uint8 internal constant MINT = 1;
    /// A destruction of tokens. `toIdentity` and `toWallet` are zero.
    uint8 internal constant BURN = 2;
    /// A transfer an agent forced. No rule was asked; trackers are told.
    uint8 internal constant FORCED_TRANSFER = 3;
    /// A lost wallet's balance moved to a new wallet of the same investor by an agent.
    uint8 internal constant RECOVERY = 4;
    /// A movement a satellite executes under a validation: the issuance of that validation while
    /// `isIssuance` is set, its settlement otherwise.
    uint8 internal constant CROSS_CHAIN = 5;

}
