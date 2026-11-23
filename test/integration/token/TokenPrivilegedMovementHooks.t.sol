// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { RecordingModule, TrackerOnlyModule } from "test/integration/mocks/CapabilityModules.sol";

/// @dev Exercises the derived token's notification overrides through the real compliance and tracker.
contract TokenPrivilegedMovementHooksTest is TREXSuiteTest {

    uint256 private constant ALICE_BALANCE = 1000;
    uint256 private constant BOB_BALANCE = 200;
    uint256 private constant MOVEMENT_AMOUNT = 150;

    TrackerOnlyModule private tracker;

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(alice, ALICE_BALANCE);
        token.mint(bob, BOB_BALANCE);
        token.unpause();
        vm.stopPrank();

        tracker = TrackerOnlyModule(
            address(new ModuleProxy(address(new TrackerOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        vm.prank(deployer);
        IModularCompliance(address(token.compliance())).addModule(address(tracker));
    }

    function test_forcedTransfer_notifiesAgentMovementOnceWithForcedKind() public {
        _expectAgentMovement(bob, address(bobIdentity), MOVEMENT_AMOUNT, MovementKindLib.FORCED_TRANSFER);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, MOVEMENT_AMOUNT);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.ForcedTransfer(agent);

        vm.prank(agent);
        assertTrue(token.forcedTransfer(alice, bob, MOVEMENT_AMOUNT), "forced transfer succeeded");

        assertEq(token.balanceOf(alice), ALICE_BALANCE - MOVEMENT_AMOUNT, "sender balance debited");
        assertEq(token.balanceOf(bob), BOB_BALANCE + MOVEMENT_AMOUNT, "recipient balance credited");
        _assertAccounting(ALICE_BALANCE - MOVEMENT_AMOUNT, BOB_BALANCE + MOVEMENT_AMOUNT);
    }

    function test_recoveryAddress_notifiesAgentMovementOnceWithRecoveryKind() public {
        _expectAgentMovement(another, address(aliceIdentity), ALICE_BALANCE, MovementKindLib.RECOVERY);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, another, ALICE_BALANCE);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC3643.RecoverySuccess(alice, another, address(aliceIdentity));

        vm.prank(agent);
        assertTrue(token.recoveryAddress(alice, another, address(aliceIdentity)), "recovery succeeded");

        assertEq(token.balanceOf(alice), 0, "lost wallet emptied");
        assertEq(token.balanceOf(another), ALICE_BALANCE, "replacement wallet credited");
        assertEq(token.balanceOf(bob), BOB_BALANCE, "other holder unaffected");
        _assertAccounting(ALICE_BALANCE, BOB_BALANCE);
    }

    function test_transfer_notifiesStandardMovementOnceWithTransferKind() public {
        address complianceAddress = address(token.compliance());
        vm.expectCall(
            complianceAddress, abi.encodeCall(IERC3643Compliance.transferred, (alice, bob, MOVEMENT_AMOUNT)), 1
        );
        vm.expectCall(
            complianceAddress, abi.encodeCall(IERC3643Compliance.canTransfer, (alice, bob, MOVEMENT_AMOUNT)), 1
        );
        vm.expectCall(complianceAddress, abi.encodeWithSelector(IModularCompliance.agentTransferred.selector), 0);
        vm.expectCall(
            address(tracker),
            abi.encodeCall(
                IModule.afterTransfer,
                (_movementContext(bob, address(bobIdentity), MOVEMENT_AMOUNT, MovementKindLib.TRANSFER))
            ),
            1
        );

        vm.prank(alice);
        assertTrue(token.transfer(bob, MOVEMENT_AMOUNT), "holder transfer succeeded");

        _assertAccounting(ALICE_BALANCE - MOVEMENT_AMOUNT, BOB_BALANCE + MOVEMENT_AMOUNT);
    }

    function _expectAgentMovement(address _to, address _toIdentity, uint256 _amount, uint8 _kind) private {
        address complianceAddress = address(token.compliance());
        vm.expectCall(
            complianceAddress, abi.encodeCall(IModularCompliance.agentTransferred, (alice, _to, _amount, _kind)), 1
        );
        vm.expectCall(complianceAddress, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), 0);
        vm.expectCall(complianceAddress, abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector), 0);
        vm.expectCall(
            address(tracker),
            abi.encodeCall(IModule.afterTransfer, (_movementContext(_to, _toIdentity, _amount, _kind))),
            1
        );
    }

    function _movementContext(address _to, address _toIdentity, uint256 _amount, uint8 _kind)
        private
        view
        returns (IModule.TransferContext memory)
    {
        return IModule.TransferContext({
            compliance: address(token.compliance()),
            fromIdentity: address(aliceIdentity),
            toIdentity: _toIdentity,
            fromWallet: bytes32(uint256(uint160(alice))),
            toWallet: bytes32(uint256(uint160(_to))),
            amountMin: _amount,
            amountMax: _amount,
            kind: _kind,
            isIssuance: false,
            spender: "",
            data: ""
        });
    }

    function _assertAccounting(uint256 _alicePosition, uint256 _bobPosition) private view {
        IComplianceLedger ledger = IComplianceLedger(address(token.compliance()));
        assertEq(ledger.positionOf(address(aliceIdentity)), _alicePosition, "sender identity position correct");
        assertEq(ledger.positionOf(address(bobIdentity)), _bobPosition, "recipient identity position correct");
        assertEq(ledger.positionOf(address(charlieIdentity)), 0, "unused identity position unchanged");
        uint256 totalPositions = ledger.positionOf(address(aliceIdentity)) + ledger.positionOf(address(bobIdentity))
            + ledger.positionOf(address(charlieIdentity));
        assertEq(totalPositions, token.totalSupply(), "actual positions sum to supply");
        assertEq(token.totalSupply(), ALICE_BALANCE + BOB_BALANCE, "supply conserved");
        assertEq(token.totalBridged(), 0, "no bridged supply introduced");
        assertEq(tracker.totalHookCalls(), 1, "tracker notified exactly once");
        assertEq(tracker.transferActionCalls(), 1, "tracker received a two-wallet movement");
    }

}
