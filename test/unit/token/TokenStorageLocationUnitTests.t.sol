// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

import { Utils } from "../helpers/Utils.sol";

contract TokenStorageLocationUnitTest is TokenBaseUnitTest {

    function testTokenStorageLocationComputation() public pure {
        bytes32 expectedLocation = Utils.erc7201("token.storage.main");
        bytes32 actualLocation = 0x3eb201768b0b55c18fa93955aeb38c6bf0f381d8227d53e1b0e5b066883d4e00;

        assertEq(expectedLocation, actualLocation, "TOKEN_STORAGE_LOCATION does not match computed value");
    }

    function testTokenStorageLocationDecimals() public view {
        // decimals + onchainId are packed at slot offset 2 (after `name` and `symbol`)
        bytes32 storageSlot = bytes32(uint256(Utils.erc7201("token.storage.main")) + 2);

        bytes32 slotValue = vm.load(address(token), storageSlot);
        // decimals is in the rightmost byte (byte 0)
        uint8 storedDecimals = uint8(uint256(slotValue) & 0xff);
        assertEq(storedDecimals, token.decimals(), "Decimals read from storage should match token.decimals()");
    }

    function testTokenStorageLocationOnchainId() public view {
        // decimals + onchainId are packed at slot offset 2 (after `name` and `symbol`)
        bytes32 storageSlot = bytes32(uint256(Utils.erc7201("token.storage.main")) + 2);

        bytes32 slotValue = vm.load(address(token), storageSlot);
        // onchainId is in bytes 1-20 (right-aligned, so we shift right by 8 bits to skip the decimals byte)
        address storedOnchainId = address(uint160(uint256(slotValue) >> 8));
        assertEq(storedOnchainId, token.onchainID(), "OnchainId read from storage should match token.onchainID()");
    }

    /// @dev The ledger fields are appended after `frozenStatus` (offset 5): bridgedBalance at 6, totalBridged
    ///      at 7. The native balance mapping lives in OpenZeppelin's own namespace and is not touched.
    function testTokenStorageLocationBridgedBalance() public {
        bytes memory wallet = InteroperableAddress.formatEvmV1(8453, user1);
        bytes32 bridgedSlot = bytes32(uint256(Utils.erc7201("token.storage.main")) + 6);
        bytes32 entry = keccak256(abi.encode(keccak256(wallet), bridgedSlot));

        vm.store(address(token), entry, bytes32(uint256(77)));
        assertEq(token.bridgedBalanceOf(wallet), 77, "bridgedBalance is not at offset 6");
    }

    function testTokenStorageLocationTotalBridged() public {
        bytes32 totalBridgedSlot = bytes32(uint256(Utils.erc7201("token.storage.main")) + 7);
        assertEq(uint256(vm.load(address(token), totalBridgedSlot)), 0);

        vm.store(address(token), totalBridgedSlot, bytes32(uint256(55)));
        assertEq(token.totalBridged(), 55, "totalBridged is not at offset 7");
        assertEq(token.totalSupply(), 55, "totalSupply does not count the bridged total");
    }

}
