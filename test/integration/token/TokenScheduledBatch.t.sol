// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @dev A token batch is authorized like its single-item function, but it needs a row of its own: an agent
///  granted with an execution delay must schedule the batch itself, and the manager only lets it schedule a
///  function whose row names a role it holds.
contract TokenScheduledBatchTest is TREXSuiteTest {

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.unpause();
        token.mint(alice, 100);
        vm.stopPrank();
    }

    function test_batchBurn_Success_WhenScheduledByDelayedBurner() public {
        address delayedBurner = makeAddr("delayedBurner");
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_BURNER), delayedBurner, 1 days);
        address[] memory holders = new address[](1);
        holders[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10;
        bytes memory batchBurnCall = abi.encodeCall(IERC3643.batchBurn, (holders, amounts));

        vm.prank(delayedBurner);
        suiteManager.schedule(address(token), batchBurnCall, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(delayedBurner);
        token.batchBurn(holders, amounts);

        assertEq(token.balanceOf(alice), 90);
    }

    function test_batchForcedTransfer_Success_WhenScheduledByDelayedAgent() public {
        address delayedAgent = makeAddr("delayedAgent");
        suiteManager.grantRole(_role(RolesLib.Role.AGENT_FORCED_TRANSFER), delayedAgent, 1 days);
        address[] memory senders = new address[](1);
        senders[0] = alice;
        address[] memory recipients = new address[](1);
        recipients[0] = bob;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 30;
        bytes memory batchForcedTransferCall =
            abi.encodeCall(IERC3643.batchForcedTransfer, (senders, recipients, amounts));

        vm.prank(delayedAgent);
        suiteManager.schedule(address(token), batchForcedTransferCall, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(delayedAgent);
        token.batchForcedTransfer(senders, recipients, amounts);

        assertEq(token.balanceOf(bob), 30);
    }

    /// @notice An agent without the role still cannot schedule the batch.
    function test_batchBurn_RevertWhen_SchedulerHoldsNoBurnerRole() public {
        address stranger = makeAddr("stranger");
        address[] memory holders = new address[](1);
        holders[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10;
        bytes memory batchBurnCall = abi.encodeCall(IERC3643.batchBurn, (holders, amounts));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                stranger,
                address(token),
                IERC3643.batchBurn.selector
            )
        );
        suiteManager.schedule(address(token), batchBurnCall, 0);
    }

}
