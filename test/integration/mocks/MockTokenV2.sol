// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Token } from "contracts/token/Token.sol";

/// @notice Sentinel implementation used by `BeaconProxySuite.t.sol` to verify that
///         `TREXImplementationAuthority.publishAndUpgrade` actually swaps the live `Token`
///         implementation under every shared-mode proxy. Adds a single `mockTokenV2Version()`
///         function that does not exist on the v1 `Token` implementation; calling
///         `MockTokenV2(proxy).mockTokenV2Version()` reverts on a v1-backed proxy with
///         "unrecognized function selector" and returns `2` on a v2-backed proxy.
contract MockTokenV2 is Token {

    function mockTokenV2Version() external pure returns (uint8) {
        return 2;
    }

}
