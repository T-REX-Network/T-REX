// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { Utils } from "test/unit/helpers/Utils.sol";

contract TREXAccessManagerUnitTest is Test {

    TREXAccessManager internal manager;
    address internal outsider = makeAddr("outsider");
    address internal token = makeAddr("token");

    function setUp() public {
        manager = TREXAccessManager(
            address(
                new ERC1967Proxy(
                    address(new TREXAccessManager()),
                    abi.encodeCall(AccessManagerUpgradeable.initialize, (address(this)))
                )
            )
        );
    }

    function test_createNamespace_NumbersFromOneAndStoresTheName() public {
        vm.expectEmit(true, false, false, true, address(manager));
        emit EventsLib.NamespaceCreated(1, "Fund A");
        uint32 first = manager.createNamespace("Fund A");
        uint32 second = manager.createNamespace("Fund B");

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(manager.namespaceCount(), 2);
        assertEq(manager.namespaceName(1), "Fund A");
        assertEq(manager.namespaceName(2), "Fund B");
    }

    function test_assign_RecordsTheNamespaceAndCanReassign() public {
        uint32 first = manager.createNamespace("Fund A");
        uint32 second = manager.createNamespace("Fund B");

        vm.expectEmit(true, true, false, true, address(manager));
        emit EventsLib.NamespaceAssigned(first, token);
        manager.assign(first, token);
        assertEq(manager.namespaceOf(token), first);

        manager.assign(second, token);
        assertEq(manager.namespaceOf(token), second);
    }

    function test_assign_RevertWhen_NamespaceDoesNotExist() public {
        manager.createNamespace("Fund A");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NamespaceNotFound.selector, 2));
        manager.assign(2, token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NamespaceNotFound.selector, 0));
        manager.assign(0, token);
    }

    function test_assign_RevertWhen_TargetIsZero() public {
        uint32 first = manager.createNamespace("Fund A");

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        manager.assign(first, address(0));
    }

    function test_createNamespaceAndAssign_RevertWhen_CallerIsNotAdmin() public {
        uint32 first = manager.createNamespace("Fund A");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, outsider, uint64(0))
        );
        manager.createNamespace("Fund B");
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, outsider, uint64(0))
        );
        manager.assign(first, token);
    }

    function test_namespaceOf_IsZeroForUnassignedTargets() public view {
        assertEq(manager.namespaceOf(token), 0);
        assertEq(manager.namespaceName(0), "");
    }

    function test_storageLocation_MatchesTheERC7201Namespace() public pure {
        bytes32 expected = Utils.erc7201("erc3643.storage.TREXAccessManager");
        assertEq(expected, 0x9ee5333472569314e77d439560942818930bfd1bd85e664704fdf0ed68f91e00);
    }

    function test_storageLayout_CountSitsAtOffsetZero() public {
        manager.createNamespace("Fund A");
        manager.createNamespace("Fund B");
        bytes32 slot = Utils.erc7201("erc3643.storage.TREXAccessManager");
        assertEq(uint32(uint256(vm.load(address(manager), slot))), 2);
    }

}
