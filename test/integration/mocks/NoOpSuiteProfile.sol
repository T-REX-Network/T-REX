// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ISuiteProfile } from "contracts/factory/ISuiteProfile.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";

/// @dev A profile that maps nothing, so a test can tell the factory delegated to it.
contract NoOpSuiteProfile is ISuiteProfile {

    uint256 public calls;
    TREXAccessManager public lastManager;
    address public lastToken;

    function applyTo(TREXAccessManager accessManager, address token) external {
        calls++;
        lastManager = accessManager;
        lastToken = token;
    }

}
