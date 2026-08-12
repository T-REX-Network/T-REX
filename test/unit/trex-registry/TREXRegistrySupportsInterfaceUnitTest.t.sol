// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IERC3643ClaimTopicsRegistry } from "contracts/ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643TrustedIssuersRegistry } from "contracts/ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

contract TREXRegistrySupportsInterfaceUnitTest is TREXRegistryBaseUnitTest {

    function test_supportsInterface_ReturnsFalse_ForUnsupported() public view {
        assertFalse(registry.supportsInterface(0x12345678));
    }

    function test_supportsInterface_ReturnsTrue_ForITREXRegistry() public view {
        assertTrue(registry.supportsInterface(type(ITREXRegistry).interfaceId));
    }

    function test_supportsInterface_ReturnsTrue_ForIERC3643IdentityRegistry() public view {
        assertTrue(registry.supportsInterface(type(IERC3643IdentityRegistry).interfaceId));
    }

    function test_supportsInterface_ReturnsTrue_ForIERC3643TrustedIssuersRegistry() public view {
        assertTrue(registry.supportsInterface(type(IERC3643TrustedIssuersRegistry).interfaceId));
    }

    function test_supportsInterface_ReturnsTrue_ForIERC3643ClaimTopicsRegistry() public view {
        assertTrue(registry.supportsInterface(type(IERC3643ClaimTopicsRegistry).interfaceId));
    }

    function test_supportsInterface_ReturnsTrue_ForIERC173() public view {
        assertTrue(registry.supportsInterface(type(IERC173).interfaceId));
    }

    function test_supportsInterface_ReturnsTrue_ForIERC165() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
    }

}
