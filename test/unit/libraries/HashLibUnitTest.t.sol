// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";

import { HashLib } from "contracts/libraries/HashLib.sol";

contract HashLibUnitTest is Test {

    function test_hash_referenceVector() public pure {
        // Locked vector — must match the cc-light HashLib output for the same inputs.
        bytes32 expected = keccak256(
            abi.encode(
                uint64(11_155_111),
                address(0xAA00000000000000000000000000000000000001),
                address(0xBb00000000000000000000000000000000000002),
                uint256(123),
                uint256(7),
                uint64(1_700_000_300)
            )
        );
        bytes32 actual = HashLib.hash(
            11_155_111,
            address(0xAA00000000000000000000000000000000000001),
            address(0xBb00000000000000000000000000000000000002),
            123,
            7,
            1_700_000_300
        );
        assertEq(actual, expected);
    }

    function test_hash_isDeterministic() public pure {
        bytes32 a = HashLib.hash(1, address(0x1), address(0x2), 100, 0, 1_700_000_000);
        bytes32 b = HashLib.hash(1, address(0x1), address(0x2), 100, 0, 1_700_000_000);
        assertEq(a, b);
    }

}
