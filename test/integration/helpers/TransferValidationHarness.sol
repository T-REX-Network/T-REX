// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";

/// @title TransferValidationHarness
/// @notice A ModularCompliance exposing the validation layer's internal hooks, so tests can drive what the slot
///         lifecycle drives once it lands.
contract TransferValidationHarness is ModularCompliance { }
