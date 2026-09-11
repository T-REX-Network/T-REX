// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";
import { TransferValidationHarness } from "test/integration/helpers/TransferValidationHarness.sol";
import { BoundsModule } from "test/integration/mocks/BoundsModule.sol";
import { ModularComplianceBaseUnitTest } from "test/unit/compliance/helpers/ModularComplianceBaseUnitTest.t.sol";
import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

/// @dev The three properties of the bounds engine, over random requests, balances, module rules and clamps: the
///      issued range sits inside the request, never above the balance, and does not depend on the bind order.
contract ValidationBoundsFuzzTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;

    bytes internal from = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
    bytes internal to = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");

    TransferValidationHarness internal reversed;
    BoundsModule internal a;
    BoundsModule internal b;

    function setUp() public override {
        super.setUp();
        reversed = TransferValidationHarness(
            BeaconProxyDeployer.newProxy(
                mcBeacon,
                abi.encodeCall(
                    ModularCompliance.init, (token, address(accessManager), new address[](0), new bytes[](0))
                )
            )
        );
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, address(reversed));

        a = BoundsModule(
            address(new ModuleProxy(address(new BoundsModule()), abi.encodeCall(BoundsModule.initialize, ())))
        );
        b = BoundsModule(
            address(new ModuleProxy(address(new BoundsModule()), abi.encodeCall(BoundsModule.initialize, ())))
        );
        mc.addModule(address(a));
        mc.addModule(address(b));
        reversed.addModule(address(b));
        reversed.addModule(address(a));

        bytes32 polygon = _evmChainKey(POLYGON);
        mc.setDefaultValidityWindow(1 hours);
        mc.setReconciliationWindow(polygon, 30 minutes);
        reversed.setDefaultValidityWindow(1 hours);
        reversed.setReconciliationWindow(polygon, 30 minutes);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        vm.mockCall(token, abi.encodeWithSelector(Token.dispatchComplianceValidation.selector), abi.encode(bytes32(0)));
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", from), abi.encode(aliceIdentity));
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", to), abi.encode(bobIdentity));
        vm.mockCall(registry, abi.encodeWithSignature("isWalletVerified(bytes)", to), abi.encode(true));
    }

    function testFuzz_requestTransferValidation_NeverWidensNeverExceedsTheBalanceAndIgnoresTheOrder(
        uint96 requestedMin,
        uint96 requestedMax,
        uint96 balance,
        uint96 floorA,
        uint96 ceilingA,
        uint96 floorB,
        uint96 ceilingB,
        uint96 clamp
    ) public {
        if (requestedMin > requestedMax) (requestedMin, requestedMax) = (requestedMax, requestedMin);
        vm.mockCall(token, abi.encodeWithSignature("bridgedBalanceOf(bytes)", from), abi.encode(uint256(balance)));
        _configure(mc, floorA, ceilingA, floorB, ceilingB, clamp);
        _configure(reversed, floorA, ceilingA, floorB, ceilingB, clamp);

        uint256 expectedMin = _max3(requestedMin, floorA, floorB);
        uint256 expectedMax = _min(requestedMax, balance);
        if (ceilingA != 0) expectedMax = _min(expectedMax, ceilingA);
        if (ceilingB != 0) expectedMax = _min(expectedMax, ceilingB);
        if (clamp != 0) expectedMax = _min(expectedMax, clamp);

        if (expectedMin > expectedMax) {
            vm.prank(aliceIdentity);
            vm.expectPartialRevert(ErrorsLib.EmptyValidationRange.selector);
            mc.requestTransferValidation(from, to, requestedMin, requestedMax, "");
            vm.prank(aliceIdentity);
            vm.expectPartialRevert(ErrorsLib.EmptyValidationRange.selector);
            reversed.requestTransferValidation(from, to, requestedMin, requestedMax, "");
            return;
        }

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(from, to, requestedMin, requestedMax, "");
        vm.prank(aliceIdentity);
        uint256 reversedId = reversed.requestTransferValidation(from, to, requestedMin, requestedMax, "");
        ITransferValidation.ValidationRecord memory record = mc.validationOf(id);
        ITransferValidation.ValidationRecord memory reversedRecord = reversed.validationOf(reversedId);

        // inside the request, never above the balance
        assertGe(record.amountMin, requestedMin);
        assertLe(record.amountMax, requestedMax);
        assertLe(record.amountMax, balance);
        assertLe(record.amountMin, record.amountMax);
        // exactly the intersection of every rule
        assertEq(record.amountMin, expectedMin);
        assertEq(record.amountMax, expectedMax);
        // the bind order changes nothing
        assertEq(reversedRecord.amountMin, record.amountMin);
        assertEq(reversedRecord.amountMax, record.amountMax);
    }

    function _configure(
        TransferValidationHarness compliance,
        uint256 floorA,
        uint256 ceilingA,
        uint256 floorB,
        uint256 ceilingB,
        uint256 clamp
    ) private {
        compliance.callModuleFunction(abi.encodeCall(BoundsModule.setFloor, (floorA)), address(a));
        compliance.callModuleFunction(abi.encodeCall(BoundsModule.setCeiling, (ceilingA)), address(a));
        compliance.callModuleFunction(abi.encodeCall(BoundsModule.setFloor, (floorB)), address(b));
        compliance.callModuleFunction(abi.encodeCall(BoundsModule.setCeiling, (ceilingB)), address(b));
        compliance.setValidationClamp(clamp);
    }

    function _max3(uint256 x, uint256 y, uint256 z) private pure returns (uint256 m) {
        m = x > y ? x : y;
        m = m > z ? m : z;
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
    }

    function _evmChainKey(uint256 chainId) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
