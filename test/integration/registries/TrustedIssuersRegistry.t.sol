// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ClaimIssuer } from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TrustedIssuersRegistryProxy } from "contracts/proxy/TrustedIssuersRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { TREXImplementationAuthority } from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import {
    IERC3643TrustedIssuersRegistry,
    TrustedIssuersRegistry
} from "contracts/registry/implementation/TrustedIssuersRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { MockContract } from "../mocks/MockContract.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract TrustedIssuersRegistryTest is TREXSuiteTest {

    // Contracts
    TrustedIssuersRegistry public trustedIssuersRegistry;

    // Claim topics
    uint256 public constant CLAIM_TOPIC_2 = 42;
    uint256 public constant CLAIM_TOPIC_3 = 66;
    uint256 public constant CLAIM_TOPIC_4 = 100;

    /// @notice Sets up TrustedIssuersRegistry via proxy
    function setUp() public override {
        super.setUp();

        trustedIssuersRegistry = TrustedIssuersRegistry(address(token.identityRegistry().issuersRegistry()));

        // Add the ClaimIssuer as a trusted issuer with a claim topic
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(claimIssuer), claimTopics);
    }

    // ============ addTrustedIssuer() Tests ============

    /// @notice Should revert when sender is not the owner
    function test_addTrustedIssuer_RevertWhen_NotOwner() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        ClaimIssuer anotherClaimIssuer = new ClaimIssuer(another);
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trustedIssuersRegistry.addTrustedIssuer(address(anotherClaimIssuer), claimTopics);
    }

    /// @notice Should revert when issuer to add is zero address
    function test_addTrustedIssuer_RevertWhen_ZeroAddress() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trustedIssuersRegistry.addTrustedIssuer(address(0), claimTopics);
    }

    /// @notice Should revert when issuer is already registered
    function test_addTrustedIssuer_RevertWhen_AlreadyRegistered() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TrustedIssuerAlreadyExists.selector);
        trustedIssuersRegistry.addTrustedIssuer(address(claimIssuer), claimTopics);
    }

    /// @notice Should revert when claim topics array is empty
    function test_addTrustedIssuer_RevertWhen_ClaimTopicsEmpty() public {
        ClaimIssuer newClaimIssuer = new ClaimIssuer(bob);
        uint256[] memory emptyClaimTopics = new uint256[](0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TrustedClaimTopicsCannotBeEmpty.selector);
        trustedIssuersRegistry.addTrustedIssuer(address(newClaimIssuer), emptyClaimTopics);
    }

    /// @notice Should revert when claim topics array exceeds 15 topics
    function test_addTrustedIssuer_RevertWhen_MoreThan15ClaimTopics() public {
        ClaimIssuer newClaimIssuer = new ClaimIssuer(bob);
        uint256[] memory claimTopics = new uint256[](16); // 16 topics > 15
        for (uint256 i = 0; i < 16; i++) {
            claimTopics[i] = i;
        }

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        trustedIssuersRegistry.addTrustedIssuer(address(newClaimIssuer), claimTopics);
    }

    /// @notice Should revert when there are already 49 trusted issuers
    function test_addTrustedIssuer_RevertWhen_MoreThan49Issuers() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        // Add 49 more issuers (we already have 1 from setUp, so 49 more to reach 50 total)
        // Contract allows up to 50 issuers (length < 50 means 0-49, allowing 50 total)
        // After adding 49 more, we'll have 50 total, then trying to add 51st should fail
        for (uint256 i = 0; i < 49; i++) {
            address issuerAddress = address(uint160(uint256(keccak256(abi.encodePacked("issuer", i)))));
            ClaimIssuer newClaimIssuer = new ClaimIssuer(issuerAddress);
            vm.prank(deployer);
            trustedIssuersRegistry.addTrustedIssuer(address(newClaimIssuer), claimTopics);
        }

        // Try to add 51st issuer (50 already exist, so this should fail)
        ClaimIssuer fiftyFirstClaimIssuer = new ClaimIssuer(another);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxTrustedIssuersReached.selector, 50));
        trustedIssuersRegistry.addTrustedIssuer(address(fiftyFirstClaimIssuer), claimTopics);
    }

    // ============ removeTrustedIssuer() Tests ============

    /// @notice Should revert when sender is not the owner
    function test_removeTrustedIssuer_RevertWhen_NotOwner() public {
        ClaimIssuer anotherClaimIssuerForRemove = new ClaimIssuer(another);

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trustedIssuersRegistry.removeTrustedIssuer(address(anotherClaimIssuerForRemove));
    }

    /// @notice Should revert when issuer to remove is zero address
    function test_removeTrustedIssuer_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trustedIssuersRegistry.removeTrustedIssuer(address(0));
    }

    /// @notice Should revert when issuer is not registered
    function test_removeTrustedIssuer_RevertWhen_NotRegistered() public {
        ClaimIssuer newClaimIssuer = new ClaimIssuer(deployer);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.NotATrustedIssuer.selector);
        trustedIssuersRegistry.removeTrustedIssuer(address(newClaimIssuer));
    }

    /// @notice Should remove the issuer from trusted list
    function test_removeTrustedIssuer_Success() public {
        // Add more issuers first
        ClaimIssuer bobClaimIssuer = new ClaimIssuer(bob);
        ClaimIssuer anotherClaimIssuer = new ClaimIssuer(another);
        ClaimIssuer charlieClaimIssuer = new ClaimIssuer(charlie);

        uint256[] memory topicsBob = new uint256[](3);
        topicsBob[0] = CLAIM_TOPIC_3;
        topicsBob[1] = CLAIM_TOPIC_4;
        topicsBob[2] = CLAIM_TOPIC_1;

        uint256[] memory topicsAnother = new uint256[](2);
        topicsAnother[0] = CLAIM_TOPIC_1;
        topicsAnother[1] = CLAIM_TOPIC_2;

        uint256[] memory topicsCharlie = new uint256[](3);
        topicsCharlie[0] = CLAIM_TOPIC_2;
        topicsCharlie[1] = CLAIM_TOPIC_3;
        topicsCharlie[2] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(bobClaimIssuer), topicsBob);
        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(anotherClaimIssuer), topicsAnother);
        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(charlieClaimIssuer), topicsCharlie);

        // Verify another is trusted
        assertTrue(trustedIssuersRegistry.isTrustedIssuer(address(anotherClaimIssuer)));

        // Remove another
        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.TrustedIssuerRemoved(address(anotherClaimIssuer));
        trustedIssuersRegistry.removeTrustedIssuer(address(anotherClaimIssuer));

        // Verify another is no longer trusted
        assertFalse(trustedIssuersRegistry.isTrustedIssuer(address(anotherClaimIssuer)));

        // Verify remaining issuers
        address[] memory trustedIssuers = trustedIssuersRegistry.getTrustedIssuers();

        // remember that in setup we already added claimIssuer to trusted issuer
        assertEq(trustedIssuers.length, 3);
        assertEq(address(trustedIssuers[0]), address(claimIssuer));
        assertEq(address(trustedIssuers[1]), address(bobClaimIssuer));
        assertEq(address(trustedIssuers[2]), address(charlieClaimIssuer));
    }

    // ============ updateIssuerClaimTopics() Tests ============

    /// @notice Should revert when sender is not the owner
    function test_updateIssuerClaimTopics_RevertWhen_NotOwner() public {
        ClaimIssuer anotherClaimIssuerForUpdate = new ClaimIssuer(another);
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        trustedIssuersRegistry.updateIssuerClaimTopics(address(anotherClaimIssuerForUpdate), claimTopics);
    }

    /// @notice Should revert when issuer to update is zero address
    function test_updateIssuerClaimTopics_RevertWhen_ZeroAddress() public {
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trustedIssuersRegistry.updateIssuerClaimTopics(address(0), claimTopics);
    }

    /// @notice Should revert when issuer is not registered
    function test_updateIssuerClaimTopics_RevertWhen_NotRegistered() public {
        ClaimIssuer newClaimIssuer = new ClaimIssuer(deployer);
        uint256[] memory claimTopics = new uint256[](1);
        claimTopics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.NotATrustedIssuer.selector);
        trustedIssuersRegistry.updateIssuerClaimTopics(address(newClaimIssuer), claimTopics);
    }

    /// @notice Should revert when claim topics array have more than 15 elements
    function test_updateIssuerClaimTopics_RevertWhen_MoreThan15ClaimTopics() public {
        uint256[] memory claimTopics = new uint256[](16); // 16 topics > 15
        for (uint256 i = 0; i < 16; i++) {
            claimTopics[i] = i;
        }

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxClaimTopicsReached.selector, 15));
        trustedIssuersRegistry.updateIssuerClaimTopics(address(claimIssuer), claimTopics);
    }

    /// @notice Should revert when claim topics array is empty
    function test_updateIssuerClaimTopics_RevertWhen_ClaimTopicsEmpty() public {
        uint256[] memory emptyClaimTopics = new uint256[](0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ClaimTopicsCannotBeEmpty.selector);
        trustedIssuersRegistry.updateIssuerClaimTopics(address(claimIssuer), emptyClaimTopics);
    }

    /// @notice Should update the topics of the trusted issuers
    function test_updateIssuerClaimTopics_Success() public {
        // Get initial claim topics
        uint256[] memory initialTopics = trustedIssuersRegistry.getTrustedIssuerClaimTopics(address(claimIssuer));
        // remember in the setup function we added CLAIM_TOPIC_1 to the claimIssuer
        assertGt(initialTopics.length, 0);

        uint256[] memory newTopics = new uint256[](2);
        newTopics[0] = CLAIM_TOPIC_3;
        newTopics[1] = CLAIM_TOPIC_4;

        // Update claim topics
        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.ClaimTopicsUpdated(address(claimIssuer), newTopics);
        trustedIssuersRegistry.updateIssuerClaimTopics(address(claimIssuer), newTopics);

        // Verify new topics are set
        assertTrue(trustedIssuersRegistry.hasClaimTopic(address(claimIssuer), CLAIM_TOPIC_3));
        assertTrue(trustedIssuersRegistry.hasClaimTopic(address(claimIssuer), CLAIM_TOPIC_4));
        // CLAIM_TOPIC_1 that was set in the setup method is no more there
        assertFalse(trustedIssuersRegistry.hasClaimTopic(address(claimIssuer), initialTopics[0]));

        // Verify getter returns new topics
        uint256[] memory retrievedTopics = trustedIssuersRegistry.getTrustedIssuerClaimTopics(address(claimIssuer));
        assertEq(retrievedTopics.length, 2);
        assertEq(retrievedTopics[0], CLAIM_TOPIC_3);
        assertEq(retrievedTopics[1], CLAIM_TOPIC_4);
    }

    /// @notice Covers inner loop increment when issuer is not first in claimTopic array
    function test_updateIssuerClaimTopics_CoversInnerLoopIncrement() public {
        // Add two more issuers with the same initial claim topic to ensure the
        // issuer being updated is not at index 0 in the claimTopic array
        ClaimIssuer firstIssuer = new ClaimIssuer(bob);
        ClaimIssuer secondIssuer = new ClaimIssuer(another);

        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(firstIssuer), topics);
        vm.prank(deployer);
        trustedIssuersRegistry.addTrustedIssuer(address(secondIssuer), topics);

        // Update claim topics for the secondIssuer so the inner loop iterates past index 0
        uint256[] memory newTopics = new uint256[](1);
        newTopics[0] = CLAIM_TOPIC_2;

        vm.prank(deployer);
        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.ClaimTopicsUpdated(address(secondIssuer), newTopics);
        trustedIssuersRegistry.updateIssuerClaimTopics(address(secondIssuer), newTopics);

        // Verify mapping updated: no longer associated with CLAIM_TOPIC_1 and now mapped to CLAIM_TOPIC_2
        assertFalse(trustedIssuersRegistry.hasClaimTopic(address(secondIssuer), CLAIM_TOPIC_1));
        assertTrue(trustedIssuersRegistry.hasClaimTopic(address(secondIssuer), CLAIM_TOPIC_2));
    }

    // ============ getTrustedIssuerClaimTopics() Tests ============

    /// @notice Should revert when issuer is not registered
    function test_getTrustedIssuerClaimTopics_RevertWhen_NotRegistered() public {
        ClaimIssuer newClaimIssuer = new ClaimIssuer(deployer);
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TrustedIssuerDoesNotExist.selector);
        trustedIssuersRegistry.getTrustedIssuerClaimTopics(address(newClaimIssuer));
    }

    // ============ supportsInterface() Tests ============

    /// @notice Should return false for unsupported interfaces
    function test_supportsInterface_ReturnsFalse_ForUnsupported() public view {
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(trustedIssuersRegistry.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the IERC3643TrustedIssuersRegistry interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC3643TrustedIssuersRegistry() public view {
        assertTrue(trustedIssuersRegistry.supportsInterface(type(IERC3643TrustedIssuersRegistry).interfaceId));
    }

    /// @notice Should correctly identify the IERC173 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC173() public view {
        assertTrue(trustedIssuersRegistry.supportsInterface(type(IERC173).interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public view {
        assertTrue(trustedIssuersRegistry.supportsInterface(type(IERC165).interfaceId));
    }

    // ============ Constructor Tests ============

    /// @notice Should revert when implementation authority is zero address
    function test_constructor_RevertWhen_ImplementationAuthorityZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TrustedIssuersRegistryProxy(address(0), deployer, new address[](0), new uint256[][](0));
    }

    /// @notice Should revert when initialization fails (invalid implementation)
    function test_constructor_RevertWhen_InitializationFails() public {
        // Deploy a mock contract that doesn't have init() function
        MockContract mockImpl = new MockContract();

        // Deploy an IA and manually set an invalid TIR implementation
        TREXImplementationAuthority incompleteIA =
            new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));

        // Create a version with invalid TIR implementation (mock contract without init())
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 0 });

        ITREXImplementationAuthority.TREXContracts memory contracts = ITREXImplementationAuthority.TREXContracts({
            tokenImplementation: address(mockImpl), // Invalid - doesn't have proper init
            ctrImplementation: address(mockImpl), // Invalid
            irImplementation: address(mockImpl), // Invalid
            irsImplementation: address(mockImpl), // Invalid
            tirImplementation: address(mockImpl), // Invalid - doesn't have init() function
            mcImplementation: address(mockImpl) // Invalid
        });

        // Add version to IA (need to be owner)
        _authorizeIAGovernance(address(incompleteIA));
        vm.prank(deployer);
        incompleteIA.addAndUseTREXVersion(version, contracts);

        // Now try to deploy proxy - delegatecall to mockImpl.init() will fail
        // because MockContract doesn't have init() function, so the proxy constructor bubbles the empty revert
        vm.expectRevert();
        new TrustedIssuersRegistryProxy(address(incompleteIA), deployer, new address[](0), new uint256[][](0));
    }

}
