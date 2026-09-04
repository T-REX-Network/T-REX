// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";

/// @notice Verifies the ERC-7201 storage slot constant matches the documented namespace.
contract TREXRegistryStorageLocationUnitTest is Test {

    function test_StorageLocation_MatchesERC7201Namespace() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXRegistry")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 hardcoded = 0x5fe6836edad2306552d236f378d4a0a2ef1c78da81818168b2b776323acb4300;
        assertEq(expected, hardcoded, "TREXRegistry storage slot drift");
    }

}
