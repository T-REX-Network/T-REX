// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";

/// @title IdentityRegistryHarness
/// @notice Certora harness over {IdentityRegistry}. Exposes the `checksDisabled` flag (held in ERC-7201
///         namespaced storage) so the eligibility-bypass rules can reason about it directly. No logic is
///         overridden.
contract IdentityRegistryHarness is IdentityRegistry {

    /// @return true when eligibility checks are globally disabled (isVerified short-circuits to true).
    function checksDisabled() external view returns (bool) {
        // Mirror of the private Storage.checksDisabled slot.
        bytes32 loc = 0x0ef1f877833723f95a1d6f26d44eb8729b1f7ecbea0628fd412c7dacaacfe800;
        bool disabled;
        // checksDisabled is the 4th field (slot offset 3) of the Storage struct.
        assembly {
            disabled := sload(add(loc, 3))
        }
        return disabled;
    }

}
