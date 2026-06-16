// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { ClaimTopicsRegistryProxy } from "contracts/proxy/ClaimTopicsRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { TREXImplementationAuthority } from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import {
    ClaimTopicsRegistry,
    IERC3643ClaimTopicsRegistry
} from "contracts/registry/implementation/ClaimTopicsRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";
import { MockContract } from "../mocks/MockContract.sol";

contract ClaimTopicsRegistryTest is TREXSuiteTest {

    ClaimTopicsRegistry public claimTopicsRegistry;

    /// @notice Sets up ClaimTopicsRegistry via proxy
    function setUp() public override {
        super.setUp();

        claimTopicsRegistry = ClaimTopicsRegistry(address(token.identityRegistry().topicsRegistry()));
    }

    // ============ init() Tests ============

    /// @notice Should revert when contract was already initialized
    function test_init_RevertWhen_AlreadyInitialized() public {
        vm.prank(deployer);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        claimTopicsRegistry.init(deployer, new uint256[](0));
    }

    // ============ addClaimTopic() Tests ============

    /// @notice Should revert when sender is not owner
    function test_addClaimTopic_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        claimTopicsRegistry.addClaimTopic(1);
    }

    /// @notice Should revert when topic array contains more than 14 elements
    /// @dev Contract allows up to 15 topics (length < 15). To test the limit, we add 15 topics first.
    function test_addClaimTopic_RevertWhen_MoreThan14Topics() public {
        // Add 14 topics first (0-13)
        for (uint256 i = 0; i < 14; i++) {
            vm.prank(deployer);
            claimTopicsRegistry.addClaimTopic(i);
        }

        // Add the 15th topic (index 14), this should succeed (length 14 < 15)
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopic(14);

        // Now try to add 16th topic, should revert (length 15 is not < 15)
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        claimTopicsRegistry.addClaimTopic(15);
    }

    /// @notice Should revert when adding a topic that is already added
    function test_addClaimTopic_RevertWhen_TopicAlreadyExists() public {
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopic(1);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ClaimTopicAlreadyExists.selector);
        claimTopicsRegistry.addClaimTopic(1);
    }

    // ============ removeClaimTopic() Tests ============

    /// @notice Should revert when sender is not owner
    function test_removeClaimTopic_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        claimTopicsRegistry.removeClaimTopic(1);
    }

    /// @notice Should remove claim topic successfully
    function test_removeClaimTopic_Success() public {
        // Add topics first
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopic(1);
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopic(2);
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopic(3);

        // Remove topic 2
        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.ClaimTopicRemoved(2);
        claimTopicsRegistry.removeClaimTopic(2);
    }

    // ============ supportsInterface() Tests ============

    /// @notice Should return false for unsupported interfaces
    function test_supportsInterface_ReturnsFalse_ForUnsupported() public view {
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(claimTopicsRegistry.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the IERC3643ClaimTopicsRegistry interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC3643ClaimTopicsRegistry() public view {
        assertTrue(claimTopicsRegistry.supportsInterface(type(IERC3643ClaimTopicsRegistry).interfaceId));
    }

    /// @notice IERC173 is part of the public interface via the AccessManagerOwnable ERC-173 ownership shim
    function test_supportsInterface_ReturnsTrue_ForIERC173() public view {
        assertTrue(claimTopicsRegistry.supportsInterface(type(IERC173).interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public view {
        assertTrue(claimTopicsRegistry.supportsInterface(type(IERC165).interfaceId));
    }

    // ============ Constructor Tests ============

    /// @notice Should revert when implementation authority is zero address
    function test_constructor_RevertWhen_ImplementationAuthorityZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new ClaimTopicsRegistryProxy(address(0), deployer, new uint256[](0));
    }

    /// @notice Should revert when initialization fails (invalid implementation)
    function test_constructor_RevertWhen_InitializationFails() public {
        // Deploy a mock contract that doesn't have init() function
        MockContract mockImpl = new MockContract();

        // Deploy an IA and manually set an invalid CTR implementation
        TREXImplementationAuthority incompleteIA =
            new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));

        // Create a version with invalid CTR implementation (mock contract without init())
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 0 });

        ITREXImplementationAuthority.TREXContracts memory contracts = ITREXImplementationAuthority.TREXContracts({
            tokenImplementation: address(mockImpl), // Invalid - doesn't have proper init
            ctrImplementation: address(mockImpl), // Invalid - doesn't have init() function
            irImplementation: address(mockImpl), // Invalid
            irsImplementation: address(mockImpl), // Invalid
            tirImplementation: address(mockImpl), // Invalid
            mcImplementation: address(mockImpl) // Invalid
        });

        // Add version to IA (need to be owner)
        _authorizeIAGovernance(address(incompleteIA));
        vm.prank(deployer);
        incompleteIA.addAndUseTREXVersion(version, contracts);

        // Now try to deploy proxy - delegatecall to mockImpl.init() will fail
        // because MockContract doesn't have init() function, so the proxy constructor bubbles the empty revert
        vm.expectRevert();
        new ClaimTopicsRegistryProxy(address(incompleteIA), deployer, new uint256[](0));
    }

}
