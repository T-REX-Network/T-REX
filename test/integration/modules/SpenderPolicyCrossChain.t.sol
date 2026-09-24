// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { SpenderVerificationModule } from "contracts/compliance/modular/modules/SpenderVerificationModule.sol";
import { SpenderWhitelistModule } from "contracts/compliance/modular/modules/SpenderWhitelistModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The two shipped spender policies against a satellite operator. No module runs on a satellite, so the
///      issuance of a validation is the only place the operator it names can be refused: a policy that only
///      guarded `transferFrom` would let any operator execute a cross-chain movement.
///
///      Both modules are exercised the same way on both sides of the boundary, so the pair says what the
///      spender in the context is for: one policy, one answer, whichever chain the operator sits on.
contract SpenderPolicyCrossChainTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;

    bytes internal aliceSat;
    bytes internal bobSat;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.prank(agent);
        token.unpause();
    }

    // ==== SpenderWhitelistModule ====

    /// @notice An operator the issuer never listed cannot be named on a validation, even though the module
    ///         never runs on the satellite that would execute it.
    function test_requestTransferValidation_RevertWhen_TheWhitelistDoesNotListTheSatelliteOperator() public {
        _bindWhitelist();
        bytes memory operator = _satelliteOperator("unlistedOperator");

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationSpenderRefused.selector, operator));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 100, operator);
    }

    /// @notice Listing that same satellite wallet lets the validation through, and the operator travels on the
    ///         wire for the satellite to enforce.
    function test_requestTransferValidation_Success_WhenTheSatelliteOperatorIsListed() public {
        SpenderWhitelistModule whitelist = _bindWhitelist();
        bytes memory operator = _satelliteOperator("listedOperator");

        vm.prank(deployer);
        boundCompliance.callModuleFunction(
            abi.encodeCall(SpenderWhitelistModule.allowSpender, (operator)), address(whitelist)
        );
        assertTrue(whitelist.isSpenderAllowed(address(boundCompliance), operator));

        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 100, operator);

        assertEq(boundCompliance.validationOf(id).amountMax, 100);
        ERC7786GatewayMock gateway = ERC7786GatewayMock(token.routeFor(polygon));
        assertEq(_decodeQueuedValidation(gateway, 0).spender, operator, "the operator travels");
    }

    /// @notice A native operator and a satellite one are separate entries: listing one does not list the other.
    function test_allowSpender_Success_WhenNativeAndSatelliteAreDistinctEntries() public {
        SpenderWhitelistModule whitelist = _bindWhitelist();
        bytes memory operator = _satelliteOperator("twoSidedOperator");
        bytes memory native = InteroperableAddress.formatEvmV1(block.chainid, charlie);

        vm.prank(deployer);
        boundCompliance.callModuleFunction(
            abi.encodeCall(SpenderWhitelistModule.allowSpender, (native)), address(whitelist)
        );

        assertTrue(whitelist.isSpenderAllowed(address(boundCompliance), native));
        assertFalse(whitelist.isSpenderAllowed(address(boundCompliance), operator), "listing is per wallet");

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationSpenderRefused.selector, operator));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 100, operator);
    }

    // ==== SpenderVerificationModule ====

    /// @notice A satellite operator bound to no identity is not eligible, so a validation cannot name it.
    function test_requestTransferValidation_RevertWhen_TheSatelliteOperatorIsUnverified() public {
        _bindVerification();
        bytes memory operator = _satelliteOperator("unlinkedOperator");

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationSpenderRefused.selector, operator));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 100, operator);
    }

    /// @notice The same operator passes once its wallet is linked to a verified identity, which is the whole
    ///         point of resolving the spender through the registry rather than as a bare address.
    function test_requestTransferValidation_Success_WhenTheSatelliteOperatorIsVerified() public {
        _bindVerification();
        bytes memory operator = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("verifiedOperator"));

        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 100, operator);

        assertEq(boundCompliance.validationOf(id).amountMax, 100);
    }

    /// @notice A validation that names no operator asks no policy: the sender executes it itself.
    function test_requestTransferValidation_Success_WhenNoOperatorIsNamedUnderAClosedPolicy() public {
        _bindWhitelist();

        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 100, "");

        assertEq(boundCompliance.validationOf(id).amountMax, 100);
    }

    // ==== Helpers ====

    function _bindWhitelist() private returns (SpenderWhitelistModule whitelist) {
        whitelist = SpenderWhitelistModule(
            address(
                new ModuleProxy(
                    address(new SpenderWhitelistModule()),
                    abi.encodeCall(SpenderWhitelistModule.initialize, (address(accessManager)))
                )
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(whitelist));
    }

    function _bindVerification() private returns (SpenderVerificationModule verification) {
        verification = SpenderVerificationModule(
            address(
                new ModuleProxy(
                    address(new SpenderVerificationModule()),
                    abi.encodeCall(SpenderVerificationModule.initialize, (address(accessManager)))
                )
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(verification));
    }

    /// @dev A canonical satellite wallet that is linked to no identity, so only a whitelist can admit it.
    function _satelliteOperator(string memory label) private returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(POLYGON, makeAddr(label));
    }

}
