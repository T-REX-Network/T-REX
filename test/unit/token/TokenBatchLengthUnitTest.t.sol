// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

/// @dev The Token overrides the batch functions to attach per-selector roles, so it needs its own
///  length checks. Without them a first array shorter than the rest silently skips the extra entries
///  and the call still succeeds.
contract TokenBatchLengthUnitTest is TokenBaseUnitTest {

    function test_batchMint_RevertWhen_FirstArrayShorter() public {
        address[] memory tos = new address[](1);
        tos[0] = user1;
        uint256[] memory amounts = new uint256[](2);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ArrayLengthMismatch.selector);
        token.batchMint(tos, amounts);
    }

    function test_batchBurn_RevertWhen_FirstArrayShorter() public {
        address[] memory froms = new address[](1);
        froms[0] = user1;
        uint256[] memory amounts = new uint256[](2);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ArrayLengthMismatch.selector);
        token.batchBurn(froms, amounts);
    }

    function test_batchSetAddressFrozen_RevertWhen_FirstArrayShorter() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        bool[] memory freezes = new bool[](2);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ArrayLengthMismatch.selector);
        token.batchSetAddressFrozen(users, freezes);
    }

    function test_batchFreezePartialTokens_RevertWhen_FirstArrayShorter() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory amounts = new uint256[](2);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ArrayLengthMismatch.selector);
        token.batchFreezePartialTokens(users, amounts);
    }

    function test_batchUnfreezePartialTokens_RevertWhen_FirstArrayShorter() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory amounts = new uint256[](2);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ArrayLengthMismatch.selector);
        token.batchUnfreezePartialTokens(users, amounts);
    }

    function test_batchForcedTransfer_RevertWhen_LengthsDiffer() public {
        address[] memory froms = new address[](1);
        froms[0] = user1;
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ArrayLengthMismatch.selector);
        token.batchForcedTransfer(froms, tos, amounts);
    }

}
