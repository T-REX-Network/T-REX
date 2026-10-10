// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";

library Utils {

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function erc7201(string memory namespaceId) internal pure returns (bytes32) {
        // ERC-7201: keccak256(abi.encode(uint256(keccak256(namespaceId)) - 1)) & ~bytes32(uint256(0xff))
        return keccak256(abi.encode(uint256(keccak256(bytes(namespaceId))) - 1)) & ~bytes32(uint256(0xff));
    }

    /// @notice The address `makeAddr(name)` returns, with one byte of code. A trusted issuer must have code, and
    ///         tests that only record issuers never ask them anything, so any code will do.
    function addressWithCode(string memory name) internal returns (address account) {
        account = VM.addr(uint256(keccak256(abi.encodePacked(name))));
        VM.label(account, name);
        VM.etch(account, hex"00");
    }

}
