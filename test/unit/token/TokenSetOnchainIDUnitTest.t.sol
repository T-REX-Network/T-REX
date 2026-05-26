// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenSetOnchainIDUnitTest is TokenBaseUnitTest {

    address newOnchainId = makeAddr("NewOnchainId");

    function testTokenSetOnchainIDRevertsWhenNotOwner(address caller) public {
        vm.assume(caller != address(this));

        vm.expectPartialRevert(OwnableUpgradeable.OwnableUnauthorizedAccount.selector);
        vm.prank(caller);
        token.setOnchainID(newOnchainId);
    }

    function testTokenSetOnchainIDNominal() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.UpdatedTokenInformation(
            token.name(), token.symbol(), token.decimals(), token.version(), newOnchainId
        );
        token.setOnchainID(newOnchainId);

        assertEq(token.onchainID(), newOnchainId);
    }

    function testTokenSetOnchainIDToZeroAddress() public {
        address zeroAddress = address(0);

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.UpdatedTokenInformation(
            token.name(), token.symbol(), token.decimals(), token.version(), zeroAddress
        );
        token.setOnchainID(zeroAddress);

        assertEq(token.onchainID(), zeroAddress);
    }

}
