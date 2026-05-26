// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { TREXFactory } from "contracts/factory/TREXFactory.sol";

/// @notice Test contract that inherits from TREXFactory to expose _deploy for testing
contract TestTREXFactory is TREXFactory {

    constructor(address implementationAuthority_, address idFactory_)
        TREXFactory(implementationAuthority_, idFactory_)
    { }

    /// @notice Exposes _deploy for testing
    /// Note: _deploy is private in TREXFactory, so we can't expose it directly
    /// This function is kept for compatibility but may need to be removed or refactored
    function testDeploy(string memory, bytes memory) external pure returns (address) {
        // Parameters are unused as function always reverts
        revert("_deploy is private and cannot be exposed");
    }

}

