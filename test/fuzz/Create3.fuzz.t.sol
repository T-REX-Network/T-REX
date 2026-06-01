// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";

import { Create3 } from "contracts/vendor/openzeppelin/Create3.sol";

/// @dev Thin wrapper exposing the internal Create3 library so it can be fuzzed directly.
contract Create3Wrapper {

    function computeAddress(bytes32 salt) external view returns (address) {
        return Create3.computeAddress(salt);
    }

    function computeAddress(bytes32 salt, address deployer) external pure returns (address) {
        return Create3.computeAddress(salt, deployer);
    }

    /// Mirrors TREXFactory.saltBytes so we can assert the per-contractType discriminator never collides.
    function saltBytes(address factory, string memory salt, string memory contractType) external pure returns (bytes32) {
        return bytes32(
            abi.encodePacked(factory, bytes1(0x00), bytes11(keccak256(abi.encodePacked(salt, contractType))))
        );
    }
}

/// @title CREATE3 determinism fuzzing
/// @notice The factory relies on CREATE3 addresses being a pure function of (deployer, salt) and independent of
///         bytecode. These properties underpin the "predict the Token address before deploying it" wiring.
contract Create3FuzzTest is Test {

    Create3Wrapper internal w;

    function setUp() public {
        w = new Create3Wrapper();
    }

    /// Same (salt, deployer) => same address, every time.
    function testFuzz_deterministic(bytes32 salt, address deployer) public view {
        assertEq(w.computeAddress(salt, deployer), w.computeAddress(salt, deployer));
    }

    /// Different salts (same deployer) => different addresses.
    function testFuzz_distinctSalts(bytes32 saltA, bytes32 saltB, address deployer) public view {
        vm.assume(saltA != saltB);
        assertTrue(w.computeAddress(saltA, deployer) != w.computeAddress(saltB, deployer));
    }

    /// Different deployers (same salt) => different addresses.
    function testFuzz_distinctDeployers(bytes32 salt, address depA, address depB) public view {
        vm.assume(depA != depB);
        assertTrue(w.computeAddress(salt, depA) != w.computeAddress(salt, depB));
    }

    /// The factory's saltBytes discriminates by contractType: the six suite slots never collide for one salt.
    function testFuzz_contractTypeDiscriminator(address factory, string calldata salt) public view {
        string[6] memory types = ["Token", "MC", "IR", "IRS", "CTR", "TIR"];
        bytes32[6] memory slots;
        for (uint256 i = 0; i < 6; i++) {
            slots[i] = w.saltBytes(factory, salt, types[i]);
        }
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = i + 1; j < 6; j++) {
                assertTrue(slots[i] != slots[j], "contractType slot collision");
            }
        }
    }
}
