// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

import { Utils } from "../helpers/Utils.sol";

contract TokenStorageLocationUnitTest is TokenBaseUnitTest {

    function testTokenStorageLocationComputation() public pure {
        bytes32 expectedLocation = Utils.erc7201("erc3643.storage.Token");
        bytes32 actualLocation = 0xbeba28ad7ddedd460139c119663e50314606b6f256383098738bb1babd01fd00;

        assertEq(expectedLocation, actualLocation, "TOKEN_STORAGE_LOCATION does not match computed value");
    }

    function testTokenStorageLocationDecimals() public view {
        // decimals + onchainId are packed at slot offset 2 (after `name` and `symbol`)
        bytes32 storageSlot = bytes32(uint256(Utils.erc7201("erc3643.storage.Token")) + 2);

        bytes32 slotValue = vm.load(address(token), storageSlot);
        // decimals is in the rightmost byte (byte 0)
        uint8 storedDecimals = uint8(uint256(slotValue) & 0xff);
        assertEq(storedDecimals, token.decimals(), "Decimals read from storage should match token.decimals()");
    }

    function testTokenStorageLocationOnchainId() public view {
        // decimals + onchainId are packed at slot offset 2 (after `name` and `symbol`)
        bytes32 storageSlot = bytes32(uint256(Utils.erc7201("erc3643.storage.Token")) + 2);

        bytes32 slotValue = vm.load(address(token), storageSlot);
        // onchainId is in bytes 1-20 (right-aligned, so we shift right by 8 bits to skip the decimals byte)
        address storedOnchainId = address(uint160(uint256(slotValue) >> 8));
        assertEq(storedOnchainId, token.onchainID(), "OnchainId read from storage should match token.onchainID()");
    }

}
