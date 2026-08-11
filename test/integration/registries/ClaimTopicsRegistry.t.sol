// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { ClaimTopicsRegistryProxy } from "contracts/proxy/ClaimTopicsRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { TREXImplementationAuthority } from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import {
    ClaimTopicsRegistry,
    IClaimTopicsRegistry,
    IERC3643ClaimTopicsRegistry
} from "contracts/registry/implementation/ClaimTopicsRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";
import { MockContract } from "../mocks/MockContract.sol";

contract ClaimTopicsRegistryTest is TREXSuiteTest {

    // Identity types as defined by the ONCHAINID v3 `IdentityTypes` library
    uint256 public constant CORPORATE = 3;
    uint256 public constant SMART_CONTRACT = 6;

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

    // ============ addClaimTopicForIdentityType() Tests ============

    /// @notice Should revert when sender is not owner
    function test_addClaimTopicForIdentityType_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        claimTopicsRegistry.addClaimTopicForIdentityType(CORPORATE, 1);
    }

    /// @notice Should revert for identity type 0, which always resolves to the default claim topics
    function test_addClaimTopicForIdentityType_RevertWhen_IdentityTypeZero() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidIdentityType.selector);
        claimTopicsRegistry.addClaimTopicForIdentityType(0, 1);
    }

    /// @notice Should revert when adding a topic that is already added for the same identity type
    function test_addClaimTopicForIdentityType_RevertWhen_TopicAlreadyExists() public {
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopicForIdentityType(CORPORATE, 1);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ClaimTopicAlreadyExists.selector);
        claimTopicsRegistry.addClaimTopicForIdentityType(CORPORATE, 1);
    }

    /// @notice Should revert when an identity type already holds 15 topics
    function test_addClaimTopicForIdentityType_RevertWhen_MoreThan15Topics() public {
        for (uint256 i = 0; i < 15; i++) {
            vm.prank(deployer);
            claimTopicsRegistry.addClaimTopicForIdentityType(CORPORATE, i);
        }

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        claimTopicsRegistry.addClaimTopicForIdentityType(CORPORATE, 15);
    }

    /// @notice Should add topics per identity type and emit the corresponding event
    function test_addClaimTopicForIdentityType_Success() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, false, false);
        emit EventsLib.ClaimTopicAddedForIdentityType(CORPORATE, 42);
        claimTopicsRegistry.addClaimTopicForIdentityType(CORPORATE, 42);

        uint256[] memory topics = claimTopicsRegistry.getClaimTopicsForIdentityType(CORPORATE);
        assertEq(topics.length, 1);
        assertEq(topics[0], 42);
    }

    /// @notice Per-type topic sets are independent of each other and of the default set
    function test_addClaimTopicForIdentityType_SetsAreIndependent() public {
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopic(1);
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopicForIdentityType(CORPORATE, 2);
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopicForIdentityType(SMART_CONTRACT, 3);

        uint256[] memory defaultTopics = claimTopicsRegistry.getClaimTopics();
        assertEq(defaultTopics.length, 1);
        assertEq(defaultTopics[0], 1);

        uint256[] memory corporateTopics = claimTopicsRegistry.getClaimTopicsForIdentityType(CORPORATE);
        assertEq(corporateTopics.length, 1);
        assertEq(corporateTopics[0], 2);

        uint256[] memory smartContractTopics = claimTopicsRegistry.getClaimTopicsForIdentityType(SMART_CONTRACT);
        assertEq(smartContractTopics.length, 1);
        assertEq(smartContractTopics[0], 3);
    }

    // ============ removeClaimTopicForIdentityType() Tests ============

    /// @notice Should revert when sender is not owner
    function test_removeClaimTopicForIdentityType_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        claimTopicsRegistry.removeClaimTopicForIdentityType(CORPORATE, 1);
    }

    /// @notice Should revert for identity type 0
    function test_removeClaimTopicForIdentityType_RevertWhen_IdentityTypeZero() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidIdentityType.selector);
        claimTopicsRegistry.removeClaimTopicForIdentityType(0, 1);
    }

    /// @notice Should remove a per-type claim topic and emit the corresponding event
    function test_removeClaimTopicForIdentityType_Success() public {
        vm.prank(deployer);
        claimTopicsRegistry.addClaimTopicForIdentityType(CORPORATE, 42);

        vm.prank(deployer);
        vm.expectEmit(true, true, false, false);
        emit EventsLib.ClaimTopicRemovedForIdentityType(CORPORATE, 42);
        claimTopicsRegistry.removeClaimTopicForIdentityType(CORPORATE, 42);

        assertEq(claimTopicsRegistry.getClaimTopicsForIdentityType(CORPORATE).length, 0);
    }

    /// @notice Removing a topic that was never added does not emit an event
    function test_removeClaimTopicForIdentityType_NoEvent_WhenTopicNotRegistered() public {
        vm.recordLogs();
        vm.prank(deployer);
        claimTopicsRegistry.removeClaimTopicForIdentityType(CORPORATE, 42);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ============ getClaimTopicsForIdentityType() Tests ============

    /// @notice Should return an empty array when no override is configured for the identity type
    function test_getClaimTopicsForIdentityType_ReturnsEmpty_WhenNoOverride() public view {
        assertEq(claimTopicsRegistry.getClaimTopicsForIdentityType(CORPORATE).length, 0);
        assertEq(claimTopicsRegistry.getClaimTopicsForIdentityType(0).length, 0);
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

    /// @notice Should correctly identify the IClaimTopicsRegistry extension interface ID
    function test_supportsInterface_ReturnsTrue_ForIClaimTopicsRegistry() public view {
        assertTrue(claimTopicsRegistry.supportsInterface(type(IClaimTopicsRegistry).interfaceId));
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
