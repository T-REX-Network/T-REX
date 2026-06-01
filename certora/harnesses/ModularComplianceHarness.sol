// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";

/// @title ModularComplianceHarness
/// @notice Certora harness over {ModularCompliance}. Exposes the bound-module count (held in an
///         EnumerableSet inside ERC-7201 namespaced storage) so the "module set is bounded at 25" invariant
///         can be stated without reaching into private storage. No logic is overridden.
contract ModularComplianceHarness is ModularCompliance {

    /// @return the number of modules currently bound to this compliance.
    function moduleCount() external view returns (uint256) {
        return this.getModules().length;
    }
}
