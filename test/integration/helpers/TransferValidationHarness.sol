// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";

/// @title TransferValidationHarness
/// @notice A ModularCompliance exposing the validation layer's internal hooks, so tests can drive what the slot
///         lifecycle will drive once it lands.
contract TransferValidationHarness is ModularCompliance {

    function exposed_onLateReconciliation(uint256 validationId, bytes32 chainKey) external {
        _onLateReconciliation(validationId, chainKey);
    }

}
