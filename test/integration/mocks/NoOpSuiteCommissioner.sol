// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ISuiteCommissioner } from "contracts/factory/ISuiteCommissioner.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";

/// @dev A commissioner that maps nothing, so a test can tell the factory delegated to it.
contract NoOpSuiteCommissioner is ISuiteCommissioner {

    uint256 public calls;
    TREXAccessManager public lastManager;
    address public lastToken;

    function commission(TREXAccessManager accessManager, address token) external {
        calls++;
        lastManager = accessManager;
        lastToken = token;
    }

}
