// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { WalletKeyLibCaller } from "../unit/libraries/WalletKeyLibUnitTest.t.sol";

/// @title WalletKeyLib property fuzzing
/// @notice A canonical envelope always keys to its own hash; the same envelope with anything appended never keys;
///         a wallet keys as a satellite exactly when it is not on this chain.
contract WalletKeyLibFuzzTest is Test {

    WalletKeyLibCaller internal lib;

    function setUp() public {
        lib = new WalletKeyLibCaller();
    }

    function testFuzz_canonicalEnvelopeKeysToItsHash(address wallet, uint64 chainId) public view {
        bytes memory envelope = InteroperableAddress.formatEvmV1(chainId, wallet);
        assertEq(lib.canonicalKey(envelope), keccak256(envelope));
    }

    function testFuzz_paddedEnvelopeNeverKeys(address wallet, uint64 chainId, bytes memory suffix) public {
        vm.assume(suffix.length > 0);
        bytes memory padded = abi.encodePacked(InteroperableAddress.formatEvmV1(chainId, wallet), suffix);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        lib.canonicalKey(padded);
    }

    /// @dev Prepending a zero byte to the chain reference keeps the decoded chain id and must never key.
    function testFuzz_zeroLedChainReferenceNeverKeys(address wallet, uint64 chainId) public {
        vm.assume(chainId > 0);
        (, bytes memory minimal, bytes memory addr) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId, wallet));
        bytes memory padded = InteroperableAddress.formatV1(0x0000, abi.encodePacked(hex"00", minimal), addr);

        (bool success, uint256 decoded,) = InteroperableAddress.tryParseEvmV1(padded);
        assertTrue(success);
        assertEq(decoded, chainId);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        lib.canonicalKey(padded);
    }

    function testFuzz_referenceChainDetection(address wallet, uint64 chainId) public {
        vm.assume(wallet != address(0) && chainId > 0);
        vm.chainId(chainId);
        (bool onReferenceChain, address unwrapped) =
            lib.isReferenceChain(InteroperableAddress.formatEvmV1(chainId, wallet));
        assertTrue(onReferenceChain);
        assertEq(unwrapped, wallet);

        (bool other,) = lib.isReferenceChain(InteroperableAddress.formatEvmV1(uint256(chainId) + 1, wallet));
        assertFalse(other);
    }

    function testFuzz_satelliteKeyRefusesThisChainOnly(address wallet, uint64 chainId, uint64 otherChainId) public {
        vm.assume(chainId > 0 && otherChainId > 0 && chainId != otherChainId);
        vm.chainId(chainId);

        bytes memory home = InteroperableAddress.formatEvmV1(chainId, wallet);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, home));
        lib.satelliteKey(home);

        bytes memory away = InteroperableAddress.formatEvmV1(otherChainId, wallet);
        assertEq(lib.satelliteKey(away), keccak256(away));
    }

}
