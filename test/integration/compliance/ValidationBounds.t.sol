// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { BoundsModule, WideningBoundsModule } from "test/integration/mocks/BoundsModule.sol";
import { CheckTransferOnlyModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";

/// @dev The bounds engine against real modules: the running range, intersection, order independence, the clamp
///      last, and the same-identity short-circuit. Every issuance here goes out through a real mock gateway.
contract ValidationBoundsTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 100;

    bytes internal aliceSat;
    bytes internal bobSat;
    BoundsModule internal first;
    BoundsModule internal second;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        first = BoundsModule(_deployBounds(address(new BoundsModule())));
        second = BoundsModule(_deployBounds(address(new BoundsModule())));
    }

    /// @notice One module narrows the balance-capped request on both ends.
    function test_requestTransferValidation_Success_WhenOneModuleNarrows() public {
        _bindWith(first, 20, 80);

        (uint256 min, uint256 max) = _issue(10, 200);

        assertEq(min, 20);
        assertEq(max, 80);
    }

    /// @notice The second module receives what the first one left, and the result is the intersection.
    function test_requestTransferValidation_Success_WhenTwoModulesIntersect() public {
        _bindWith(first, 20, 90);
        _bindWith(second, 30, 80);

        vm.expectCall(
            address(first),
            abi.encodeCall(IModule.validationBounds, (aliceSat, bobSat, 10, BALANCE, address(boundCompliance))),
            1
        );
        vm.expectCall(
            address(second),
            abi.encodeCall(IModule.validationBounds, (aliceSat, bobSat, 20, 90, address(boundCompliance))),
            1
        );
        (uint256 min, uint256 max) = _issue(10, 200);

        assertEq(min, 30);
        assertEq(max, 80);
    }

    /// @notice Binding the modules the other way round gives the same range.
    function test_requestTransferValidation_Success_WhenTheBindOrderChanges() public {
        _bindWith(first, 20, 90);
        _bindWith(second, 30, 80);
        (uint256 min, uint256 max) = _issue(10, 200);

        vm.startPrank(deployer);
        boundCompliance.removeModule(address(first));
        boundCompliance.removeModule(address(second));
        vm.stopPrank();
        _bindWith(second, 30, 80);
        _bindWith(first, 20, 90);
        (uint256 reversedMin, uint256 reversedMax) = _issue(10, 200);

        assertEq(min, reversedMin);
        assertEq(max, reversedMax);
    }

    /// @notice A module that refuses outright reverts the issuance, and nothing is recorded.
    function test_requestTransferValidation_RevertWhen_AModuleRefuses() public {
        _bindWith(first, 0, 0);
        vm.prank(deployer);
        boundCompliance.callModuleFunction(abi.encodeCall(BoundsModule.setRevert, (true)), address(first));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(BoundsModule.BoundsModuleRefused.selector);
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 200, "");

        assertEq(boundCompliance.nextValidationId(), 0);
    }

    /// @notice A module narrowing to nothing empties the range, which is refused.
    function test_requestTransferValidation_RevertWhen_TheModulesEmptyTheRange() public {
        _bindWith(first, 50, 0);
        _bindWith(second, 0, 40);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 50, 40));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 200, "");
    }

    /// @notice A module that answers wider than its input is intersected back.
    function test_requestTransferValidation_Success_WhenAModuleAnswersWider() public {
        _bindWith(first, 20, 80);
        address widening = _deployBounds(address(new WideningBoundsModule()));
        vm.prank(deployer);
        boundCompliance.addModule(widening);

        (uint256 min, uint256 max) = _issue(10, 200);

        assertEq(min, 20);
        assertEq(max, 80);
    }

    /// @notice A module that did not declare the bounds hook is not consulted, whatever it implements.
    function test_requestTransferValidation_Success_WhenAModuleDidNotDeclareBounds() public {
        _bindWith(first, 20, 80);
        CheckTransferOnlyModule checker = CheckTransferOnlyModule(
            address(
                new ModuleProxy(address(new CheckTransferOnlyModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        checker.setAllow(false);
        vm.prank(deployer);
        boundCompliance.addModule(address(checker));

        vm.expectCall(address(checker), abi.encodeWithSelector(IModule.validationBounds.selector), 0);
        (uint256 min, uint256 max) = _issue(10, 200);

        assertEq(min, 20);
        assertEq(max, 80);
    }

    /// @notice The clamp applies after every module, and only ever lowers the maximum.
    function test_requestTransferValidation_Success_WhenTheClampAppliesLast() public {
        _bindWith(first, 20, 80);

        vm.prank(deployer);
        boundCompliance.setValidationClamp(50);
        (, uint256 clampedMax) = _issue(10, 200);

        vm.prank(deployer);
        boundCompliance.setValidationClamp(90);
        (, uint256 looseMax) = _issue(10, 200);

        assertEq(clampedMax, 50);
        assertEq(looseMax, 80);
    }

    /// @notice Two wallets of one identity: no module is consulted and only the balance narrows.
    function test_requestTransferValidation_Success_WhenBothWalletsBelongToOneIdentity() public {
        _bindWith(first, 1000, 0);
        bytes memory aliceOther = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));

        vm.expectCall(address(first), abi.encodeWithSelector(IModule.validationBounds.selector), 0);
        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, aliceOther, 10, 200, "");

        ITransferValidation.ValidationRecord memory record = boundCompliance.validationOf(id);
        assertEq(record.amountMin, 10);
        assertEq(record.amountMax, BALANCE);
    }

    function _issue(uint256 requestedMin, uint256 requestedMax) private returns (uint256 min, uint256 max) {
        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, requestedMin, requestedMax);
        ITransferValidation.ValidationRecord memory record = boundCompliance.validationOf(id);
        return (record.amountMin, record.amountMax);
    }

    function _bindWith(BoundsModule module, uint256 floor, uint256 ceiling) private {
        vm.startPrank(deployer);
        boundCompliance.addModule(address(module));
        boundCompliance.callModuleFunction(abi.encodeCall(BoundsModule.setFloor, (floor)), address(module));
        boundCompliance.callModuleFunction(abi.encodeCall(BoundsModule.setCeiling, (ceiling)), address(module));
        vm.stopPrank();
    }

    function _deployBounds(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(BoundsModule.initialize, ())));
    }

}
