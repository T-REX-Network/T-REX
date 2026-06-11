// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { ClaimTopicsRegistryProxy } from "contracts/proxy/ClaimTopicsRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { ClaimTopicsRegistry } from "contracts/registry/implementation/ClaimTopicsRegistry.sol";

contract ClaimTopicsRegistryInitUnitTest is Test {

    ClaimTopicsRegistry private ctrImplementation;
    AccessManager private accessManager;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private notOwner = makeAddr("NotOwner");

    function setUp() public {
        ctrImplementation = new ClaimTopicsRegistry();
        accessManager = new AccessManager(address(this));
        accessManager.grantRole(RolesLib.OWNER, address(this), 0);
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getCTRImplementation.selector),
            abi.encode(address(ctrImplementation))
        );
    }

    function test_init_SetsOwnerFromArgument_NotDeployer() public {
        ClaimTopicsRegistry ctr = _deployProxy(new uint256[](0));

        assertEq(ctr.owner(), address(accessManager));
        assertNotEq(ctr.owner(), address(this));
    }

    function test_init_AppliesInitialTopics() public {
        uint256[] memory topics = new uint256[](3);
        topics[0] = 11;
        topics[1] = 22;
        topics[2] = 33;

        ClaimTopicsRegistry ctr = _deployProxy(topics);

        uint256[] memory stored = ctr.getClaimTopics();
        assertEq(stored.length, 3);
        assertEq(stored[0], 11);
        assertEq(stored[1], 22);
        assertEq(stored[2], 33);
    }

    function test_init_OwnerCanStillAddClaimTopicAfterInit() public {
        uint256[] memory topics = new uint256[](1);
        topics[0] = 1;

        ClaimTopicsRegistry ctr = _deployProxy(topics);

        ctr.addClaimTopic(2);

        uint256[] memory stored = ctr.getClaimTopics();
        assertEq(stored.length, 2);
        assertEq(stored[1], 2);
    }

    function test_addClaimTopic_RevertWhen_NotOwner() public {
        ClaimTopicsRegistry ctr = _deployProxy(new uint256[](0));

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, notOwner));
        ctr.addClaimTopic(1);
    }

    function test_init_RevertWhen_OwnerIsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ClaimTopicsRegistryProxy(implementationAuthority, address(0), new uint256[](0));
    }

    function test_init_RevertWhen_DuplicateInitialTopics() public {
        uint256[] memory topics = new uint256[](2);
        topics[0] = 7;
        topics[1] = 7;

        vm.expectRevert(ErrorsLib.ClaimTopicAlreadyExists.selector);
        new ClaimTopicsRegistryProxy(implementationAuthority, address(accessManager), topics);
    }

    function _deployProxy(uint256[] memory _topics) private returns (ClaimTopicsRegistry) {
        ClaimTopicsRegistry ctr = ClaimTopicsRegistry(
            address(new ClaimTopicsRegistryProxy(implementationAuthority, address(accessManager), _topics))
        );
        AccessManagerSetupLib.setupClaimTopicsRegistryRoles(accessManager, address(ctr));
        return ctr;
    }

}
