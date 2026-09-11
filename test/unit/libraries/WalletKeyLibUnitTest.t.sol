// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";

/// @dev External surface over the library so `vm.expectRevert` observes the revert.
contract WalletKeyLibCaller {

    function parse(bytes memory envelope) external pure returns (bytes2, bytes memory, bytes memory) {
        return WalletKeyLib.parse(envelope);
    }

    function canonicalKey(bytes memory envelope) external pure returns (bytes32) {
        return WalletKeyLib.canonicalKey(envelope);
    }

    function satelliteKey(bytes memory envelope) external view returns (bytes32) {
        return WalletKeyLib.satelliteKey(envelope);
    }

    function isReferenceChain(bytes memory envelope) external view returns (bool, address) {
        return WalletKeyLib.isReferenceChain(envelope);
    }

}

/// @title WalletKeyLib unit tests
/// @notice The padded-envelope cases from the ONCHAINID M-08 finding: an envelope with bytes beyond what parsed
///         must never produce a key, or one wallet would become several ledger entries. Same rule for a leading
///         zero in an EVM chain reference, which decodes to the same chain id.
contract WalletKeyLibUnitTest is Test {

    uint256 internal constant SATELLITE_CHAIN = 8453;

    WalletKeyLibCaller internal lib;

    address internal wallet = makeAddr("wallet");

    function setUp() public {
        lib = new WalletKeyLibCaller();
    }

    function _evm(uint256 chainId, address addr) internal pure returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(chainId, addr);
    }

    function _nonEvm() internal pure returns (bytes memory) {
        return InteroperableAddress.formatV1(0x0002, hex"0102", new bytes(32));
    }

    function _expectNonCanonical(bytes memory envelope) internal {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, envelope));
    }

    // ------------------------------------------------------------------
    // canonicalKey
    // ------------------------------------------------------------------

    function test_canonicalKey_IsTheHashOfTheCanonicalEnvelope() public view {
        bytes memory envelope = _evm(block.chainid, wallet);
        assertEq(lib.canonicalKey(envelope), keccak256(envelope));
    }

    function test_canonicalKey_SameWalletFormattedTwiceKeysEqual() public view {
        assertEq(lib.canonicalKey(_evm(block.chainid, wallet)), lib.canonicalKey(_evm(block.chainid, wallet)));
    }

    function test_canonicalKey_DifferentChainsKeyDifferently() public view {
        assertNotEq(lib.canonicalKey(_evm(1, wallet)), lib.canonicalKey(_evm(SATELLITE_CHAIN, wallet)));
    }

    function test_canonicalKey_NonEvmEnvelopeIsAccepted() public view {
        assertEq(lib.canonicalKey(_nonEvm()), keccak256(_nonEvm()));
    }

    function test_canonicalKey_RevertWhen_TrailingZeroByte() public {
        bytes memory padded = abi.encodePacked(_evm(block.chainid, wallet), hex"00");
        _expectNonCanonical(padded);
        lib.canonicalKey(padded);
    }

    function test_canonicalKey_RevertWhen_TrailingNonZeroByte() public {
        bytes memory padded = abi.encodePacked(_evm(block.chainid, wallet), hex"ff");
        _expectNonCanonical(padded);
        lib.canonicalKey(padded);
    }

    function test_canonicalKey_RevertWhen_TrailingWord() public {
        bytes memory padded = abi.encodePacked(_evm(block.chainid, wallet), bytes32(uint256(1)));
        _expectNonCanonical(padded);
        lib.canonicalKey(padded);
    }

    function test_canonicalKey_RevertWhen_TruncatedEnvelope() public {
        bytes memory envelope = _evm(block.chainid, wallet);
        bytes memory truncated = new bytes(envelope.length - 1);
        for (uint256 i = 0; i < truncated.length; i++) {
            truncated[i] = envelope[i];
        }
        _expectNonCanonical(truncated);
        lib.canonicalKey(truncated);
    }

    function test_canonicalKey_RevertWhen_WrongVersion() public {
        bytes memory envelope = _evm(block.chainid, wallet);
        envelope[1] = 0x02;
        _expectNonCanonical(envelope);
        lib.canonicalKey(envelope);
    }

    function test_canonicalKey_RevertWhen_EmptyEnvelope() public {
        _expectNonCanonical("");
        lib.canonicalKey("");
    }

    function test_canonicalKey_RevertWhen_HeaderOnly() public {
        bytes memory headerOnly = hex"000100000000";
        _expectNonCanonical(headerOnly);
        lib.canonicalKey(headerOnly);
    }

    /// @dev `0x0089` and `0x89` both read as chain 137; only the minimal form keys.
    function test_canonicalKey_RevertWhen_EvmChainReferenceHasALeadingZero() public {
        bytes memory padded = InteroperableAddress.formatV1(0x0000, hex"0089", abi.encodePacked(wallet));
        (bool success, uint256 chainId,) = InteroperableAddress.tryParseEvmV1(padded);
        assertTrue(success);
        assertEq(chainId, 137);

        _expectNonCanonical(padded);
        lib.canonicalKey(padded);
    }

    function test_canonicalKey_ChainZeroFormatsAsALoneZeroByte() public view {
        bytes memory envelope = _evm(0, wallet);
        (, bytes memory chainReference,) = lib.parse(envelope);
        assertEq(chainReference, hex"00");
        assertEq(lib.canonicalKey(envelope), keccak256(envelope));
    }

    function test_canonicalKey_NonEvmChainReferenceMayStartWithZero() public view {
        bytes memory envelope = InteroperableAddress.formatV1(0x0002, hex"0001", new bytes(32));
        assertEq(lib.canonicalKey(envelope), keccak256(envelope));
    }

    // ------------------------------------------------------------------
    // satelliteKey
    // ------------------------------------------------------------------

    function test_satelliteKey_IsTheCanonicalKeyOnAnotherChain() public view {
        bytes memory envelope = _evm(SATELLITE_CHAIN, wallet);
        assertEq(lib.satelliteKey(envelope), lib.canonicalKey(envelope));
    }

    function test_satelliteKey_AcceptsANonEvmWallet() public view {
        assertEq(lib.satelliteKey(_nonEvm()), keccak256(_nonEvm()));
    }

    function test_satelliteKey_RevertWhen_WalletIsOnThisChain() public {
        bytes memory envelope = _evm(block.chainid, wallet);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, envelope));
        lib.satelliteKey(envelope);
    }

    function test_satelliteKey_RevertWhen_ThisChainWithoutAnAddress() public {
        bytes memory envelope = InteroperableAddress.formatEvmV1(block.chainid);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, envelope));
        lib.satelliteKey(envelope);
    }

    function test_satelliteKey_RevertWhen_ThisChainZeroAddress() public {
        bytes memory envelope = _evm(block.chainid, address(0));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, envelope));
        lib.satelliteKey(envelope);
    }

    function test_satelliteKey_RevertWhen_PaddedEnvelope() public {
        bytes memory padded = abi.encodePacked(_evm(SATELLITE_CHAIN, wallet), hex"00");
        _expectNonCanonical(padded);
        lib.satelliteKey(padded);
    }

    // ------------------------------------------------------------------
    // parse
    // ------------------------------------------------------------------

    function test_parse_ReturnsTheComponents() public view {
        (bytes2 chainType, bytes memory chainReference, bytes memory addr) = lib.parse(_evm(SATELLITE_CHAIN, wallet));
        assertEq(chainType, bytes2(0x0000));
        assertEq(chainReference, hex"2105");
        assertEq(addr, abi.encodePacked(wallet));
    }

    function test_parse_RevertWhen_TrailingByte() public {
        bytes memory padded = abi.encodePacked(_evm(SATELLITE_CHAIN, wallet), hex"00");
        _expectNonCanonical(padded);
        lib.parse(padded);
    }

    // ------------------------------------------------------------------
    // isReferenceChain
    // ------------------------------------------------------------------

    function test_isReferenceChain_TrueOnThisChain() public view {
        (bool onReferenceChain, address unwrapped) = lib.isReferenceChain(_evm(block.chainid, wallet));
        assertTrue(onReferenceChain);
        assertEq(unwrapped, wallet);
    }

    function test_isReferenceChain_FalseOnAnotherChainId() public view {
        (bool onReferenceChain, address unwrapped) = lib.isReferenceChain(_evm(block.chainid + 1, wallet));
        assertFalse(onReferenceChain);
        assertEq(unwrapped, address(0));
    }

    function test_isReferenceChain_FalseOnNonEvmChainType() public view {
        (bool onReferenceChain, address unwrapped) = lib.isReferenceChain(_nonEvm());
        assertFalse(onReferenceChain);
        assertEq(unwrapped, address(0));
    }

    function test_isReferenceChain_FalseWithoutAnAddress() public view {
        (bool onReferenceChain,) = lib.isReferenceChain(InteroperableAddress.formatEvmV1(block.chainid));
        assertFalse(onReferenceChain);
    }

    function test_isReferenceChain_RevertWhen_PaddedEnvelope() public {
        bytes memory padded = abi.encodePacked(_evm(block.chainid, wallet), hex"00");
        _expectNonCanonical(padded);
        lib.isReferenceChain(padded);
    }

}
