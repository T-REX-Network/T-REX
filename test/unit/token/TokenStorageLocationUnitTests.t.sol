// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

import { Utils } from "../helpers/Utils.sol";

contract TokenStorageLocationUnitTest is TokenBaseUnitTest {

    function testTokenStorageLocationComputation() public pure {
        bytes32 expectedLocation = Utils.erc7201("token.storage.main");
        bytes32 actualLocation = 0x3eb201768b0b55c18fa93955aeb38c6bf0f381d8227d53e1b0e5b066883d4e00;

        assertEq(expectedLocation, actualLocation, "TOKEN_STORAGE_LOCATION does not match computed value");
    }

    function testTokenStorageLocationDecimals() public view {
        bytes32 storageSlot = Utils.erc7201("token.storage.main");

        bytes32 slotValue = vm.load(address(token), storageSlot);
        // decimals is in the rightmost byte (byte 0)
        uint8 storedDecimals = uint8(uint256(slotValue) & 0xff);
        assertEq(storedDecimals, token.decimals(), "Decimals read from storage should match token.decimals()");
    }

    function testTokenStorageLocationOnchainId() public view {
        bytes32 storageSlot = Utils.erc7201("token.storage.main");

        bytes32 slotValue = vm.load(address(token), storageSlot);
        // onchainId is in bytes 1-20 (right-aligned, so we shift right by 8 bits to skip the decimals byte)
        address storedOnchainId = address(uint160(uint256(slotValue) >> 8));
        assertEq(storedOnchainId, token.onchainID(), "OnchainId read from storage should match token.onchainID()");
    }

    function testTokenStorageLocationERC20StorageLocationComputation() public pure {
        bytes32 expectedLocation = Utils.erc7201("openzeppelin.storage.ERC20");
        bytes32 actualLocation = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

        assertEq(expectedLocation, actualLocation, "ERC20_STORAGE_LOCATION does not match computed value");
    }

    function testTokenStorageLocationERC20StorageLocation() public view {
        bytes32 erc20StorageLocation = Utils.erc7201("openzeppelin.storage.ERC20");

        // According to ERC20Storage struct:
        // - mapping(address => uint256) _balances; (doesn't occupy a slot, uses keccak256)
        // - mapping(address => mapping(address => uint256)) _allowances; (doesn't occupy a slot, uses keccak256)
        // - Slot 0: _totalSupply (uint256) - first non-mapping field
        // - Slot 1: _name (string)
        // - Slot 2: _symbol (string)

        string memory expectedName = token.name();
        string memory expectedSymbol = token.symbol();
        uint256 expectedTotalSupply = token.totalSupply();

        // Read _totalSupply from slot 0
        bytes32 totalSupplySlot = bytes32(uint256(erc20StorageLocation));
        uint256 storedTotalSupply = uint256(vm.load(address(token), totalSupplySlot));
        assertEq(
            storedTotalSupply, expectedTotalSupply, "TotalSupply read from storage should match token.totalSupply()"
        );

        // Read _name from slot 1
        bytes32 nameSlot = bytes32(uint256(erc20StorageLocation) + 1);
        bytes32 nameSlotValue = vm.load(address(token), nameSlot);
        uint8 nameLength = uint8(uint256(nameSlotValue) & 0xff);
        if (nameLength > 0 && nameLength <= 31) {
            string memory storedName = readShortStringFromStorage(nameSlot);
            assertEq(storedName, expectedName, "Name read from storage should match token.name()");
        } else {
            assertTrue(bytes(expectedName).length > 0, "Token name should be accessible via public function");
        }

        // Read _symbol from slot 2
        bytes32 symbolSlot = bytes32(uint256(erc20StorageLocation) + 2);
        bytes32 symbolSlotValue = vm.load(address(token), symbolSlot);
        uint8 symbolLength = uint8(uint256(symbolSlotValue) & 0xff);
        if (symbolLength > 0 && symbolLength <= 31) {
            string memory storedSymbol = readShortStringFromStorage(symbolSlot);
            assertEq(storedSymbol, expectedSymbol, "Symbol read from storage should match token.symbol()");
        } else {
            assertTrue(bytes(expectedSymbol).length > 0, "Token symbol should be accessible via public function");
        }
    }

    function testTokenStorageLocationEIP712StorageLocationComputation() public pure {
        bytes32 expectedLocation = Utils.erc7201("openzeppelin.storage.EIP712");
        bytes32 actualLocation = 0xa16a46d94261c7517cc8ff89f61c0ce93598e3c849801011dee649a6a557d100;

        assertEq(expectedLocation, actualLocation, "EIP712_STORAGE_LOCATION does not match computed value");
    }

    function testStorageLocationsAreNonOverlapping() public pure {
        bytes32 tokenStorage = Utils.erc7201("token.storage.main");
        bytes32 erc20Storage = Utils.erc7201("openzeppelin.storage.ERC20");
        bytes32 eip712Storage = Utils.erc7201("openzeppelin.storage.EIP712");

        assertTrue(tokenStorage != erc20Storage, "Token and ERC20 storage should not overlap");
        assertTrue(tokenStorage != eip712Storage, "Token and EIP712 storage should not overlap");
        assertTrue(erc20Storage != eip712Storage, "ERC20 and EIP712 storage should not overlap");
    }

    // ----- Helpers -----

    function readShortStringFromStorage(bytes32 slot) internal view returns (string memory) {
        bytes32 slotValue = vm.load(address(token), slot);
        uint8 length = uint8(uint256(slotValue) & 0xff);
        require(length <= 31, "String too long for short format");

        // Extract the string data from the left-aligned bytes
        // Byte 0 (most significant) is the first character, byte 31 (least significant) is the length
        bytes memory data = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            // Extract byte i from the left: shift right by (31-i) bytes, then mask to get the byte
            data[i] = bytes1(uint8(uint256(slotValue) >> (8 * (31 - i))));
        }
        return string(data);
    }

}
