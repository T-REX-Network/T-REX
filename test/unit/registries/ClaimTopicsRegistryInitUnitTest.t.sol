// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { ClaimTopicsRegistryProxy } from "contracts/proxy/ClaimTopicsRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { ClaimTopicsRegistry } from "contracts/registry/implementation/ClaimTopicsRegistry.sol";

import { AccessManagerHelper } from "../../helpers/AccessManagerHelper.sol";

contract ClaimTopicsRegistryInitUnitTest is AccessManagerHelper {

    ClaimTopicsRegistry private ctrImplementation;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private owner = makeAddr("Owner");
    address private notOwner = makeAddr("NotOwner");

    function setUp() public {
        ctrImplementation = new ClaimTopicsRegistry();
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getCTRImplementation.selector),
            abi.encode(address(ctrImplementation))
        );
    }

    function test_init_SetsOwnerToAccessManager() public {
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

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupClaimTopicsRegistryRoles(accessManager, address(ctr));
        accessManager.grantRole(RolesLib.OWNER, owner, NO_DELAY);
        vm.stopPrank();

        vm.prank(owner);
        ctr.addClaimTopic(2);

        uint256[] memory stored = ctr.getClaimTopics();
        assertEq(stored.length, 2);
        assertEq(stored[1], 2);
    }

    function test_addClaimTopic_RevertWhen_NotOwner() public {
        ClaimTopicsRegistry ctr = _deployProxy(new uint256[](0));

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupClaimTopicsRegistryRoles(accessManager, address(ctr));
        vm.stopPrank();

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, notOwner));
        ctr.addClaimTopic(1);
    }

    function test_init_RevertWhen_AccessManagerIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new ClaimTopicsRegistryProxy(implementationAuthority, address(0), new uint256[](0));
    }

    function test_init_RevertWhen_MoreThan5InitialTopics() public {
        uint256[] memory topics = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            topics[i] = i + 1;
        }

        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new ClaimTopicsRegistryProxy(implementationAuthority, address(accessManager), topics);
    }

    function test_init_RevertWhen_DuplicateInitialTopics() public {
        uint256[] memory topics = new uint256[](2);
        topics[0] = 7;
        topics[1] = 7;

        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new ClaimTopicsRegistryProxy(implementationAuthority, address(accessManager), topics);
    }

    function test_init_RevertWhen_AlreadyInitialized() public {
        ClaimTopicsRegistry ctr = _deployProxy(new uint256[](0));

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        ctr.init(address(accessManager), new uint256[](0));
    }

    function _deployProxy(uint256[] memory _topics) private returns (ClaimTopicsRegistry) {
        return ClaimTopicsRegistry(
            address(new ClaimTopicsRegistryProxy(implementationAuthority, address(accessManager), _topics))
        );
    }

}
