// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";

/// @notice Test-only `TREXAccessManager`, like {TestTREXFactory} for the factory. It sets up the role layout
///         of suite contracts given as four separate addresses. Unit tests deploy one real suite contract and
///         point it at placeholder siblings, so they cannot use `setupSuite(domainId, token)`, which reads the
///         siblings from the token.
contract TestTREXAccessManager is TREXAccessManager {

    /// @notice Sets up `token`, `registry`, `identityStorage` and `compliance` in `domainId` exactly as
    ///         `setupSuite` would, without reading any of them. Admin-only, like `setupSuite`.
    function setupSuiteContracts(
        uint32 domainId,
        address token,
        address registry,
        address identityStorage,
        address compliance
    ) external onlyAuthorized {
        _setupSuite(domainId, token, registry, identityStorage, compliance);
    }

}
