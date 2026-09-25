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
import { RecordingModule, RuleOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { ModularComplianceBaseUnitTest } from "test/unit/compliance/helpers/ModularComplianceBaseUnitTest.t.sol";
import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

/// @dev The three properties of an issued range, over random requests, balances and rule answers: it sits
///      inside what the caller asked for, never above what the wallet holds, and does not depend on the order
///      the rules were bound in.
///
///      A rule answers one number, so it can only lower the maximum. The caller's minimum is never raised,
///      which is the property the first assertion pins.
contract AllowedAmountFuzzTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;

    bytes internal from = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
    bytes internal to = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");

    TransferValidationHarness internal reversed;
    RuleOnlyModule internal a;
    RuleOnlyModule internal b;

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
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, address(reversed), 1);

        a = RuleOnlyModule(
            address(new ModuleProxy(address(new RuleOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        b = RuleOnlyModule(
            address(new ModuleProxy(address(new RuleOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
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
        uint96 allowedByA,
        uint96 allowedByB
    ) public {
        if (requestedMin > requestedMax) {
            (requestedMin, requestedMax) = (requestedMax, requestedMin);
        }
        // The wallet's room is the token's now: what it can still send is its balance less any reservation.
        vm.mockCall(token, abi.encodeWithSignature("availableOf(bytes)", from), abi.encode(uint256(balance)));
        vm.mockCall(token, abi.encodeWithSignature("reserveForValidation(bytes,uint256)"), "");
        a.setAllowedAmount(allowedByA);
        b.setAllowedAmount(allowedByB);

        uint256 expectedMin = requestedMin;
        uint256 expectedMax = _min(_min(requestedMax, balance), _min(allowedByA, allowedByB));

        if (expectedMin > expectedMax || expectedMax == 0) {
            bytes4 expected =
                expectedMin > expectedMax ? ErrorsLib.EmptyValidationRange.selector : ErrorsLib.ZeroValue.selector;
            vm.prank(aliceIdentity);
            vm.expectPartialRevert(expected);
            mc.requestTransferValidation(from, to, requestedMin, requestedMax, "");
            vm.prank(aliceIdentity);
            vm.expectPartialRevert(expected);
            reversed.requestTransferValidation(from, to, requestedMin, requestedMax, "");
            return;
        }

        vm.prank(aliceIdentity);
        uint256 id = mc.requestTransferValidation(from, to, requestedMin, requestedMax, "");
        vm.prank(aliceIdentity);
        uint256 reversedId = reversed.requestTransferValidation(from, to, requestedMin, requestedMax, "");
        ITransferValidation.Validation memory validation = mc.validationOf(id);
        ITransferValidation.Validation memory reversedValidation = reversed.validationOf(reversedId);

        assertEq(validation.amountMin, requestedMin, "the caller's minimum is never raised");
        assertLe(validation.amountMax, requestedMax, "never wider than the request");
        assertLe(validation.amountMax, balance, "never above what the wallet holds");
        assertLe(validation.amountMin, validation.amountMax);
        assertEq(validation.amountMax, expectedMax, "the smallest rule answer wins");
        assertEq(reversedValidation.amountMin, validation.amountMin, "the bind order does not matter");
        assertEq(reversedValidation.amountMax, validation.amountMax);
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
