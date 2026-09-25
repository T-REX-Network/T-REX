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

    function test_createDomain_NumbersFromOneAndStoresTheName() public {
        vm.expectEmit(true, false, false, true, address(manager));
        emit EventsLib.DomainCreated(1, "Fund A");
        uint32 first = manager.createDomain("Fund A");
        uint32 second = manager.createDomain("Fund B");

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(manager.domainCount(), 2);
        assertEq(manager.domainName(1), "Fund A");
        assertEq(manager.domainName(2), "Fund B");
    }

    function test_assign_RecordsTheDomainAndCanReassign() public {
        uint32 first = manager.createDomain("Fund A");
        uint32 second = manager.createDomain("Fund B");

        vm.expectEmit(true, true, false, true, address(manager));
        emit EventsLib.DomainAssigned(first, token);
        manager.assign(first, token);
        assertEq(manager.domainOf(token), first);

        manager.assign(second, token);
        assertEq(manager.domainOf(token), second);
    }

    function test_assign_RevertWhen_DomainDoesNotExist() public {
        manager.createDomain("Fund A");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DomainNotFound.selector, 2));
        manager.assign(2, token);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DomainNotFound.selector, 0));
        manager.assign(0, token);
    }

    function test_assign_RevertWhen_TargetIsZero() public {
        uint32 first = manager.createDomain("Fund A");

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        manager.assign(first, address(0));
    }

    function test_createDomainAndAssign_RevertWhen_CallerIsNotAdmin() public {
        uint32 first = manager.createDomain("Fund A");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, outsider, uint64(0))
        );
        manager.createDomain("Fund B");
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, outsider, uint64(0))
        );
        manager.assign(first, token);
    }

    function test_createDomainAndAssign_RevertWhen_ADelayedAdminCallsDirectly() public {
        address delayedAdmin = makeAddr("delayedAdmin");
        manager.grantRole(manager.ADMIN_ROLE(), delayedAdmin, 1 hours);
        uint32 first = manager.createDomain("Fund A");
        bytes memory create = abi.encodeCall(TREXAccessManager.createDomain, ("Fund B"));
        bytes memory assignCall = abi.encodeCall(TREXAccessManager.assign, (first, token));
        bytes32 createId = manager.hashOperation(delayedAdmin, address(manager), create);
        bytes32 assignId = manager.hashOperation(delayedAdmin, address(manager), assignCall);

        vm.prank(delayedAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, createId));
        manager.createDomain("Fund B");
        vm.prank(delayedAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, assignId));
        manager.assign(first, token);
    }

    function test_createDomainAndAssign_Success_WhenADelayedAdminSchedulesAndExecutes() public {
        address delayedAdmin = makeAddr("delayedAdmin");
        manager.grantRole(manager.ADMIN_ROLE(), delayedAdmin, 1 hours);
        bytes memory create = abi.encodeCall(TREXAccessManager.createDomain, ("Fund A"));

        vm.prank(delayedAdmin);
        manager.schedule(address(manager), create, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(delayedAdmin);
        manager.execute(address(manager), create);

        assertEq(manager.domainCount(), 1);
        assertEq(manager.domainName(1), "Fund A");
        bytes memory assignCall = abi.encodeCall(TREXAccessManager.assign, (1, token));
        vm.prank(delayedAdmin);
        manager.schedule(address(manager), assignCall, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(delayedAdmin);
        manager.execute(address(manager), assignCall);
        assertEq(manager.domainOf(token), 1);
    }

    function test_createDomainAndAssign_AreAdminOnlyByDefaultAndVisible() public view {
        assertEq(manager.getTargetFunctionRole(address(manager), TREXAccessManager.createDomain.selector), 0);
        assertEq(manager.getTargetFunctionRole(address(manager), TREXAccessManager.assign.selector), 0);
    }

    function test_domainOf_IsZeroForUnassignedTargets() public view {
        assertEq(manager.domainOf(token), 0);
        assertEq(manager.domainName(0), "");
    }

    function test_storageLocation_MatchesTheERC7201Location() public pure {
        bytes32 expected = Utils.erc7201("erc3643.storage.TREXAccessManager");
        assertEq(expected, 0x9ee5333472569314e77d439560942818930bfd1bd85e664704fdf0ed68f91e00);
    }

    function test_storageLayout_CountSitsAtOffsetZero() public {
        manager.createDomain("Fund A");
        manager.createDomain("Fund B");
        bytes32 slot = Utils.erc7201("erc3643.storage.TREXAccessManager");
        assertEq(uint32(uint256(vm.load(address(manager), slot))), 2);
    }

}
