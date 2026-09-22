// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

import { Utils } from "../helpers/Utils.sol";

/// @dev Pins the two ERC-7201 namespaces the Token spans after the ERC-3643 / T-REX split (issue #65):
///  the standard state lives in the ERC3643Token base's namespace, while the T-REX namespace holds
///  `decimals` and the bridged ledger. Issue #54 records why the layout changed from the single
///  `token.storage.main` struct: name and symbol are now owned by the ERC-20 base, and the frozen state
///  follows OpenZeppelin's two-mapping shape rather than one packed struct.
contract TokenStorageLocationUnitTest is TokenBaseUnitTest {

    function testERC3643TokenStorageLocationComputation() public pure {
        bytes32 expectedLocation = Utils.erc7201("erc3643.storage.ERC3643Token");
        bytes32 actualLocation = 0x1c6ea0581535d63a38daa138246885c0e308b5f6335af4548c056841c5c18f00;

        assertEq(expectedLocation, actualLocation, "ERC3643_TOKEN_STORAGE_LOCATION does not match computed value");
    }

    function testTREXTokenStorageLocationComputation() public pure {
        bytes32 expectedLocation = Utils.erc7201("erc3643.storage.TREXToken");
        bytes32 actualLocation = 0x05378669fd58b6f9251e6d5461e60e18b8b3fdf11d70481ba6f9fc72a4bfc600;

        assertEq(expectedLocation, actualLocation, "TOKEN_STORAGE_LOCATION does not match computed value");
    }

    function testTREXTokenStorageDecimals() public view {
        // `decimals` heads the T-REX namespace, so it sits at offset 0.
        bytes32 storageSlot = Utils.erc7201("erc3643.storage.TREXToken");

        bytes32 slotValue = vm.load(address(token), storageSlot);
        uint8 storedDecimals = uint8(uint256(slotValue) & 0xff);
        assertEq(storedDecimals, token.decimals(), "Decimals read from storage should match token.decimals()");
    }

    function testERC3643TokenStorageOnchainId() public view {
        // ERC3643TokenStorage: frozen (0), frozenTokens (1), identityRegistry (2), compliance (3),
        // onchainId (4). The two mappings occupy a slot each; the three addresses do not pack together
        // because each is written independently.
        bytes32 storageSlot = bytes32(uint256(Utils.erc7201("erc3643.storage.ERC3643Token")) + 4);

        bytes32 slotValue = vm.load(address(token), storageSlot);
        address storedOnchainId = address(uint160(uint256(slotValue)));
        assertEq(storedOnchainId, token.onchainID(), "OnchainId read from storage should match token.onchainID()");
    }

    function testERC3643TokenStorageIdentityRegistryAndCompliance() public view {
        bytes32 base = Utils.erc7201("erc3643.storage.ERC3643Token");

        address storedRegistry = address(uint160(uint256(vm.load(address(token), bytes32(uint256(base) + 2)))));
        assertEq(storedRegistry, address(token.identityRegistry()), "Identity registry slot mismatch");

        address storedCompliance = address(uint160(uint256(vm.load(address(token), bytes32(uint256(base) + 3)))));
        assertEq(storedCompliance, address(token.compliance()), "Compliance slot mismatch");
    }

    /// @dev The ledger fields follow `decimals` in the T-REX namespace: bridgedBalance at 1, totalBridged
    ///      at 2. The native balance mapping lives in OpenZeppelin's own namespace and is not touched.
    function testTREXTokenStorageBridgedBalance() public {
        bytes memory wallet = InteroperableAddress.formatEvmV1(8453, user1);
        bytes32 bridgedSlot = bytes32(uint256(Utils.erc7201("erc3643.storage.TREXToken")) + 1);
        bytes32 entry = keccak256(abi.encode(keccak256(wallet), bridgedSlot));

        vm.store(address(token), entry, bytes32(uint256(77)));
        assertEq(token.bridgedBalanceOf(wallet), 77, "bridgedBalance is not at offset 1");
    }

    function testTREXTokenStorageTotalBridged() public {
        bytes32 totalBridgedSlot = bytes32(uint256(Utils.erc7201("erc3643.storage.TREXToken")) + 2);
        assertEq(uint256(vm.load(address(token), totalBridgedSlot)), 0);

        vm.store(address(token), totalBridgedSlot, bytes32(uint256(55)));
        assertEq(token.totalBridged(), 55, "totalBridged is not at offset 2");
        assertEq(token.totalSupply(), 55, "totalSupply does not count the bridged total");
    }

}
