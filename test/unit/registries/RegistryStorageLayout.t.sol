// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

/// @dev Shows why TREXRegistry needed a new namespace when its struct changed.
///
///  The old struct began with an address and packed `checksDisabled` beside it at byte 20. The new
///  struct starts with `checksDisabled` at byte 0. Reusing the namespace would leave the low byte of the
///  old storage address deciding whether eligibility checks run, and that byte is non-zero for almost
///  every address, which reads as "checks disabled" and verifies everyone.
contract RegistryStorageLayoutTest is Test {

    /// @dev Slot 0 as the old struct wrote it: address in bytes 0-19, `checksDisabled` false at byte 20.
    function _oldSlotZero(address identityStorage) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(identityStorage)));
    }

    /// @dev Slot 0 as the new struct reads it: `checksDisabled` is byte 0.
    function _newChecksDisabled(bytes32 slotZero) internal pure returns (bool) {
        return uint8(uint256(slotZero) & 0xff) != 0;
    }

    function test_reusingTheNamespaceWouldFlipChecksDisabled() public pure {
        bytes32 slotZero = _oldSlotZero(0x1111111111111111111111111111111111111111);

        assertTrue(_newChecksDisabled(slotZero), "checks enabled before would read as disabled after");
    }

    /// @dev True for any address whose lowest byte is set, which is 255 of every 256.
    function testFuzz_flipHappensForAlmostEveryAddress(address identityStorage) public pure {
        vm.assume(uint160(identityStorage) & 0xff != 0);

        assertTrue(_newChecksDisabled(_oldSlotZero(identityStorage)));
    }

}
