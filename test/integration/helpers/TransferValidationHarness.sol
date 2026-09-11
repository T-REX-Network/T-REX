// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";

/// @title TransferValidationHarness
/// @notice A ModularCompliance exposing the validation layer's internal hooks, so tests can drive what the slot
///         lifecycle drives once it lands.
contract TransferValidationHarness is ModularCompliance {

    function exposed_onLateReconciliation(uint256 validationId, bytes32 chainKey) external {
        _onLateReconciliation(validationId, chainKey);
    }

    function exposed_commitSlots(uint256 validationId, uint256 executedAmount) external {
        _commitSlots(validationId, executedAmount);
    }

    function exposed_releaseSlots(uint256 validationId) external {
        _releaseSlots(validationId);
    }

    /// @dev Writes a stored status directly, for states the real paths do not produce yet.
    function exposed_setStatus(uint256 validationId, ITransferValidation.ValidationStatus status) external {
        _validationStorage().states[validationId].status = status;
    }

}
