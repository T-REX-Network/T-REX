// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import {
    RecordingModule,
    RuleOnlyModule,
    SpenderOnlyModule,
    TrackerOnlyModule
} from "test/integration/mocks/CapabilityModules.sol";

/// @dev How the rules narrow an issued range, against real modules: the smallest answer wins, the order does
///      not matter, a refusal stops the issuance, and a relocation between one identity's wallets consults
///      nobody. Every issuance here goes out through a real mock gateway.
///
///      A rule answers one number, the largest amount it allows, so it can only ever lower the maximum. The
///      minimum is the caller's and is never raised: an issued range the caller did not ask for would let a
///      satellite execute an amount the caller never proposed.
contract AllowedAmountIssuanceTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 100;

    bytes internal aliceSat;
    bytes internal bobSat;
    RuleOnlyModule internal first;
    RuleOnlyModule internal second;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        first = RuleOnlyModule(_deployRule(address(new RuleOnlyModule())));
        second = RuleOnlyModule(_deployRule(address(new RuleOnlyModule())));
    }

    /// @notice One rule caps the balance-capped request.
    function test_requestTransferValidation_Success_WhenOneRuleNarrows() public {
        _bindAllowing(first, 80);

        (uint256 min, uint256 max) = _issue(10, 200);

        assertEq(min, 10, "the caller's minimum is never raised");
        assertEq(max, 80);
    }

    /// @notice Two rules: the smallest answer wins, and both are consulted with the same request.
    function test_requestTransferValidation_Success_WhenTwoRulesAnswer() public {
        _bindAllowing(first, 90);
        _bindAllowing(second, 80);

        (uint256 min, uint256 max) = _issue(10, 200);

        assertEq(min, 10);
        assertEq(max, 80, "the smallest answer wins");
    }

    /// @notice Every rule sees the same request, so the result does not depend on the bind order. Bound the
    ///         other way round, on a compliance of its own so no earlier reservation clouds the comparison.
    function test_requestTransferValidation_Success_WhenTheBindOrderChanges() public {
        _bindAllowing(first, 90);
        _bindAllowing(second, 80);
        (, uint256 looserFirst) = _issue(10, 200);

        vm.prank(deployer);
        boundCompliance.removeModule(address(first));
        vm.prank(deployer);
        boundCompliance.removeModule(address(second));

        // A second sender, so this issuance starts from a wallet with nothing reserved against it.
        bytes memory carolSat =
            _fundSatelliteWallet(charlieIdentity, charlie, POLYGON, makeAccount("carolOnPolygon"), BALANCE);
        _bindAllowing(second, 80);
        _bindAllowing(first, 90);
        uint256 id = _requestValidation(address(charlieIdentity), carolSat, bobSat, 10, 200);
        uint256 tighterFirst = boundCompliance.validationOf(id).amountMax;

        assertEq(looserFirst, 80, "the smallest answer wins");
        assertEq(tighterFirst, 80, "and it still wins the other way round");
    }

    /// @notice A rule that allows nothing stops the issuance: there is no range left to issue.
    function test_requestTransferValidation_RevertWhen_ARuleRefuses() public {
        _bindAllowing(first, 0);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 200, "");
    }

    /// @notice Rules that between them allow less than the caller's minimum empty the range.
    function test_requestTransferValidation_RevertWhen_TheRulesEmptyTheRange() public {
        _bindAllowing(first, 80);
        _bindAllowing(second, 40);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 50, 40));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 50, 200, "");
    }

    /// @notice A rule answering more than the wallet holds changes nothing: the balance already capped it.
    function test_requestTransferValidation_Success_WhenARuleAnswersWiderThanTheBalance() public {
        _bindAllowing(first, type(uint256).max);

        (uint256 min, uint256 max) = _issue(10, 200);

        assertEq(min, 10);
        assertEq(max, BALANCE, "capped at what the wallet holds");
    }

    /// @notice A module that is not a rule is never asked for an amount, whatever it implements.
    function test_requestTransferValidation_Success_WhenAModuleIsNotARule() public {
        _bindAllowing(first, 80);
        address tracker = _deployRule(address(new TrackerOnlyModule()));
        vm.prank(deployer);
        boundCompliance.addModule(tracker);

        // Never called at all, whatever the arguments would have been: a selector-wide expectation.
        vm.expectCall(tracker, abi.encodeWithSelector(IModule.allowedAmount.selector), 0);
        (uint256 min, uint256 max) = _issue(10, 200);

        assertEq(min, 10);
        assertEq(max, 80);
    }

    /// @notice A validation that names a spender is judged by the `SPENDER` modules at issuance. No module
    ///         runs on the satellite, so this is the only place that spender can be refused.
    function test_requestTransferValidation_RevertWhen_ASpenderPolicyRefuses() public {
        SpenderOnlyModule policy = SpenderOnlyModule(_deployRule(address(new SpenderOnlyModule())));
        policy.setSpenderAllowed(false);
        vm.prank(deployer);
        boundCompliance.addModule(address(policy));
        bytes memory spender = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("spenderOnPolygon"));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationSpenderRefused.selector, spender));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 200, spender);

        assertEq(boundCompliance.lastValidationId(), 0, "nothing was issued");
    }

    /// @notice The same policy lets the issuance through once it accepts the named spender.
    function test_requestTransferValidation_Success_WhenASpenderPolicyAccepts() public {
        SpenderOnlyModule policy = SpenderOnlyModule(_deployRule(address(new SpenderOnlyModule())));
        vm.prank(deployer);
        boundCompliance.addModule(address(policy));
        bytes memory spender = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("spenderOnPolygon"));

        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 200, spender);

        assertEq(boundCompliance.validationOf(id).amountMax, BALANCE);
    }

    /// @notice A validation the sender executes itself names no spender, so no policy is asked.
    function test_requestTransferValidation_Success_WhenNoSpenderIsNamed() public {
        SpenderOnlyModule policy = SpenderOnlyModule(_deployRule(address(new SpenderOnlyModule())));
        policy.setSpenderAllowed(false);
        vm.prank(deployer);
        boundCompliance.addModule(address(policy));

        // Never called at all, whatever the arguments would have been: a selector-wide expectation.
        vm.expectCall(address(policy), abi.encodeWithSelector(IModule.moduleCheckSpender.selector), 0);
        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 200, "");

        assertEq(boundCompliance.validationOf(id).amountMax, BALANCE);
    }

    /// @notice Two wallets of one identity: no rule is consulted and only the balance narrows, because
    ///         relocating your own tokens changes no position.
    function test_requestTransferValidation_Success_WhenBothWalletsBelongToOneIdentity() public {
        _bindAllowing(first, 0);
        bytes memory aliceOther = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));

        // Never called at all, whatever the arguments would have been: a selector-wide expectation.
        vm.expectCall(address(first), abi.encodeWithSelector(IModule.allowedAmount.selector), 0);
        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, aliceOther, 10, 200, "");

        ITransferValidation.Validation memory validation = boundCompliance.validationOf(id);
        assertEq(validation.amountMin, 10);
        assertEq(validation.amountMax, BALANCE);
    }

    function _issue(uint256 requestedMin, uint256 requestedMax) private returns (uint256 min, uint256 max) {
        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, requestedMin, requestedMax);
        ITransferValidation.Validation memory validation = boundCompliance.validationOf(id);
        return (validation.amountMin, validation.amountMax);
    }

    function _bindAllowing(RuleOnlyModule module, uint256 allowed) private {
        vm.prank(deployer);
        boundCompliance.addModule(address(module));
        module.setAllowedAmount(allowed);
    }

    function _deployRule(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

}
