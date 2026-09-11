// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TransferValidationHarness } from "test/integration/helpers/TransferValidationHarness.sol";
import { SlotsModule } from "test/integration/mocks/SlotsModule.sol";

/// @dev The keeper against a real suite: the derived status over time, the discard releasing a counter module,
///      the re-issuance it enables, and every refusal. The compliance is the harness so a `BurnConfirmed` state
///      can be proved undiscardable before the two-leg settlement produces it for real.
contract ValidationDiscardTest is InteropSuiteTest {

    uint256 internal constant CAP = 100;
    uint256 internal constant BALANCE = 1000;

    bytes internal aliceSat;
    bytes internal bobSat;
    SlotsModule internal slots;
    uint256 internal issuedAt;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        slots = SlotsModule(
            address(new ModuleProxy(address(new SlotsModule()), abi.encodeCall(SlotsModule.initialize, ())))
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(slots));
        boundCompliance.callModuleFunction(abi.encodeCall(SlotsModule.setCap, (CAP)), address(slots));
        vm.stopPrank();

        issuedAt = block.timestamp;
        id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, CAP);
    }

    function _deployImplementations() internal override {
        super._deployImplementations();
        modularComplianceImplementation = ModularCompliance(address(new TransferValidationHarness()));
    }

    // ==== .statusOf Tests ====

    /// @notice Pending until the release deadline passes, Expired after it, stored Pending throughout.
    function test_statusOf_Success_WhenTheClockMovesPastTheDeadlines() public {
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));

        vm.warp(issuedAt + VALIDITY_WINDOW + 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));

        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));
        assertEq(uint8(boundCompliance.stateOf(id).status), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    // ==== .discardExpiredValidations Tests ====

    /// @notice The keeper releases the counter, marks the id, announces it, and the cap is available again.
    function test_discardExpiredValidations_Success_WhenExpiredAndReissued() public {
        assertEq(slots.heldOf(address(boundCompliance), bobSat), CAP);
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.expectCall(address(slots), abi.encodeCall(IModule.releaseSlot, (id)), 1);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ValidationDiscarded(id);
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(slots.heldOf(address(boundCompliance), bobSat), 0);

        uint256 next = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, CAP);
        assertEq(boundCompliance.validationOf(next).amountMax, CAP);
        assertEq(slots.heldOf(address(boundCompliance), bobSat), CAP);
    }

    /// @notice An agent, a manager or a stranger cannot discard.
    function test_discardExpiredValidations_RevertWhen_CallerLacksTheKeeperRole() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        boundCompliance.discardExpiredValidations(_ids(id));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, deployer));
        boundCompliance.discardExpiredValidations(_ids(id));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));
    }

    /// @notice A validation still inside its reconciliation window is refused.
    function test_discardExpiredValidations_RevertWhen_NotYetReleasable() public {
        uint64 releaseAt = uint64(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW);
        vm.warp(releaseAt);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotReleasable.selector, id, releaseAt));
        boundCompliance.discardExpiredValidations(_ids(id));
    }

    /// @notice One refused id reverts the whole batch and releases nothing.
    function test_discardExpiredValidations_RevertWhen_OneIdOfTheBatchIsPending() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        bytes memory bobOther = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOtherOnPolygon"));
        uint256 pending = _requestValidation(address(aliceIdentity), aliceSat, bobOther, 10, CAP);
        uint64 pendingReleaseAt = uint64(block.timestamp + VALIDITY_WINDOW + POLYGON_WINDOW);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = pending;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotReleasable.selector, pending, pendingReleaseAt));
        boundCompliance.discardExpiredValidations(ids);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Expired));
        assertEq(slots.releaseCalls(), 0);
        assertEq(slots.heldOf(address(boundCompliance), bobSat), CAP);
    }

    /// @notice An already discarded id and an unknown id are refused by name.
    function test_discardExpiredValidations_RevertWhen_AlreadyDiscardedOrUnknown() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(_ids(id));

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotDiscardable.selector, id, uint8(ITransferValidation.ValidationStatus.Discarded)
            )
        );
        boundCompliance.discardExpiredValidations(_ids(id));

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownValidation.selector, 999));
        boundCompliance.discardExpiredValidations(_ids(999));
    }

    /// @notice A consumed leg pins the validation: no clock makes it discardable.
    function test_discardExpiredValidations_RevertWhen_BurnConfirmed() public {
        TransferValidationHarness(address(boundCompliance))
            .exposed_setStatus(id, ITransferValidation.ValidationStatus.BurnConfirmed);
        vm.warp(issuedAt + 100 * VALIDITY_WINDOW);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.BurnConfirmed));
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotDiscardable.selector,
                id,
                uint8(ITransferValidation.ValidationStatus.BurnConfirmed)
            )
        );
        boundCompliance.discardExpiredValidations(_ids(id));
        assertEq(slots.heldOf(address(boundCompliance), bobSat), CAP);
    }

    function _ids(uint256 one) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = one;
    }

}
