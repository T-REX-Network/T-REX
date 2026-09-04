// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

contract TREXRegistryInitUnitTest is TREXRegistryBaseUnitTest {

    /// @notice Should prevent re-initializing an already-initialized proxy
    function test_init_RevertWhen_AlreadyInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.init(
            address(identityRegistryStorage),
            address(accessManager),
            address(idFactory),
            new uint256[](0),
            new address[](0),
            new uint256[][](0)
        );
    }

    /// @notice Should reject zero address for identity storage
    function test_init_RevertWhen_IdentityStorageZeroAddress() public {
        TREXRegistry impl = new TREXRegistry();
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                TREXRegistry.init,
                (
                    address(0),
                    address(accessManager),
                    address(idFactory),
                    new uint256[](0),
                    new address[](0),
                    new uint256[][](0)
                )
            )
        );
    }

    /// @notice Should reject zero address for access manager
    function test_init_RevertWhen_AccessManagerZeroAddress() public {
        TREXRegistry impl = new TREXRegistry();
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                TREXRegistry.init,
                (
                    address(identityRegistryStorage),
                    address(0),
                    address(idFactory),
                    new uint256[](0),
                    new address[](0),
                    new uint256[][](0)
                )
            )
        );
    }

    /// @notice Should emit the four "init" events and wire the sub-registries to address(this)
    function test_init_EmitsExpectedEventsAndWiresState() public {
        TREXRegistry impl = new TREXRegistry();

        vm.recordLogs();
        TREXRegistry newRegistry = TREXRegistry(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        TREXRegistry.init,
                        (
                            address(identityRegistryStorage),
                            address(accessManager),
                            address(idFactory),
                            new uint256[](0),
                            new address[](0),
                            new uint256[][](0)
                        )
                    )
                )
            )
        );

        assertEq(address(newRegistry.identityStorage()), address(identityRegistryStorage));
        assertEq(address(newRegistry.topicsRegistry()), address(newRegistry));
        assertEq(address(newRegistry.issuersRegistry()), address(newRegistry));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sigClaimTopicsRegistrySet = keccak256("ClaimTopicsRegistrySet(address)");
        bytes32 sigTrustedIssuersRegistrySet = keccak256("TrustedIssuersRegistrySet(address)");
        bytes32 sigIdentityStorageSet = keccak256("IdentityStorageSet(address)");
        bytes32 sigEligibilityChecksEnabled = keccak256("EligibilityChecksEnabled()");

        bool sawCTR;
        bool sawTIR;
        bool sawIRS;
        bool sawEligibility;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(newRegistry)) continue;
            bytes32 topic0 = entries[i].topics[0];
            if (topic0 == sigClaimTopicsRegistrySet) {
                sawCTR = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(newRegistry));
            } else if (topic0 == sigTrustedIssuersRegistrySet) {
                sawTIR = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(newRegistry));
            } else if (topic0 == sigIdentityStorageSet) {
                sawIRS = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(identityRegistryStorage));
            } else if (topic0 == sigEligibilityChecksEnabled) {
                sawEligibility = true;
            }
        }
        assertTrue(sawCTR, "ClaimTopicsRegistrySet missing");
        assertTrue(sawTIR, "TrustedIssuersRegistrySet missing");
        assertTrue(sawIRS, "IdentityStorageSet missing");
        assertTrue(sawEligibility, "EligibilityChecksEnabled missing");
    }

}
