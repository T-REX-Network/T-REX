// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { AbstractFeeCollectorProxy } from "contracts/proxy/AbstractFeeCollectorProxy.sol";
import { TokenProxy } from "contracts/proxy/TokenProxy.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";
import { Token } from "contracts/token/Token.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";
import { FeeCollectorRecordingMock } from "../mocks/FeeCollectorRecordingMock.sol";

contract TokenFeeCollectorTest is TREXSuiteTest {

    FeeCollectorRecordingMock public recordingFeeCollector;
    TokenProxy public tokenProxy;
    IdentityRegistry public identityRegistry;

    function setUp() public override {
        super.setUp();

        identityRegistry = IdentityRegistry(address(token.identityRegistry()));
        tokenProxy = TokenProxy(payable(address(token)));

        recordingFeeCollector = new FeeCollectorRecordingMock();

        // Set the recording fee collector on the token
        vm.prank(deployer);
        tokenProxy.setFeeCollector(address(recordingFeeCollector));

        // Mint tokens and unpause
        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.mint(bob, 500);
        token.unpause();
        vm.stopPrank();
    }

    // ============ setFeeCollector() Tests ============

    /// @notice Should revert when called by unauthorized user
    function test_setFeeCollector_RevertWhen_NotAuthorized() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        tokenProxy.setFeeCollector(address(recordingFeeCollector));
    }

    /// @notice Should update fee collector when called by TOKEN_ADMIN
    function test_setFeeCollector_Success() public {
        FeeCollectorRecordingMock newCollector = new FeeCollectorRecordingMock();

        vm.prank(deployer);
        tokenProxy.setFeeCollector(address(newCollector));

        // Verify by configuring a fee and triggering it
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.transfer.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 1;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        vm.prank(alice);
        token.transfer(bob, 100);

        assertEq(newCollector.getFeeCallCount(), 1);
    }

    /// @notice Should emit FeeCollectorUpdated event
    function test_setFeeCollector_EmitsEvent() public {
        FeeCollectorRecordingMock newCollector = new FeeCollectorRecordingMock();

        vm.prank(deployer);
        vm.expectEmit(true, true, true, false, address(token));
        emit EventsLib.FeeCollectorUpdated(address(recordingFeeCollector), address(newCollector), deployer);
        tokenProxy.setFeeCollector(address(newCollector));
    }

    // ============ setFunctionsFees() Tests ============

    /// @notice Should revert when called by unauthorized user
    function test_setFunctionsFees_RevertWhen_NotAuthorized() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.transfer.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 1;

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        tokenProxy.setFunctionsFees(selectors, multipliers);
    }

    /// @notice Should set fees for multiple functions
    function test_setFunctionsFees_Success() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = Token.transfer.selector;
        selectors[1] = Token.transferFrom.selector;
        uint8[] memory multipliers = new uint8[](2);
        multipliers[0] = 3;
        multipliers[1] = 5;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        // Verify transfer fee works with multiplier 3
        vm.prank(alice);
        token.transfer(bob, 100);

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.multiplier, 3);

        // Verify transferFrom fee works with multiplier 5
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        token.transferFrom(alice, bob, 50);

        call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.multiplier, 5);
    }

    /// @notice Should disable fees when multiplier is set to 0
    function test_setFunctionsFees_DisableWithZeroMultiplier() public {
        // First enable fees
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.transfer.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 2;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        // Verify fee is collected
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(recordingFeeCollector.getFeeCallCount(), 1);

        // Disable fees by setting multiplier to 0
        multipliers[0] = 0;
        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        // Verify fee is no longer collected
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(recordingFeeCollector.getFeeCallCount(), 1);
    }

    // ============ Fee Collection Tests ============

    /// @notice Should call collectFee with correct feePayer on transfer
    function test_feeCollection_Transfer_CorrectFeePayer() public {
        _enableTransferFee(2);

        vm.prank(alice);
        token.transfer(bob, 100);

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.feePayer, alice);
        assertEq(call.multiplier, 2);
        assertEq(call.referralCode, 0);
    }

    /// @notice Should call collectFee with correct feePayer on transferFrom
    function test_feeCollection_TransferFrom_CorrectFeePayer() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.transferFrom.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 4;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        vm.prank(alice);
        token.approve(bob, 200);

        vm.prank(bob);
        token.transferFrom(alice, bob, 100);

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.feePayer, bob);
        assertEq(call.multiplier, 4);
        assertEq(call.referralCode, 0);
    }

    /// @notice Should not call collectFee when no fees configured
    function test_feeCollection_NoFeeWhenNotConfigured() public {
        // No fees configured, just do a transfer
        vm.prank(alice);
        token.transfer(bob, 100);

        assertEq(recordingFeeCollector.getFeeCallCount(), 0);
    }

    /// @notice Should collect fee on batchTransfer when configured for batchTransfer selector
    function test_feeCollection_BatchTransfer() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.batchTransfer.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 2;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        address[] memory toList = new address[](2);
        toList[0] = bob;
        toList[1] = charlie;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(alice);
        token.batchTransfer(toList, amounts);

        // batchTransfer has its own selector, fees collected once for the outer call
        assertEq(recordingFeeCollector.getFeeCallCount(), 1);
        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.feePayer, alice);
        assertEq(call.multiplier, 2);
    }

    /// @notice Should collect fee on mint when configured
    function test_feeCollection_Mint() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.mint.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 7;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        vm.prank(agent);
        token.mint(alice, 500);

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.feePayer, agent);
        assertEq(call.multiplier, 7);
    }

    /// @notice Should collect fee on burn when configured
    function test_feeCollection_Burn() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.burn.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 3;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        vm.prank(agent);
        token.burn(alice, 100);

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.feePayer, agent);
        assertEq(call.multiplier, 3);
    }

    /// @notice Should collect fee on forcedTransfer when configured
    function test_feeCollection_ForcedTransfer() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.forcedTransfer.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 10;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        vm.prank(agent);
        token.forcedTransfer(alice, bob, 100);

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.feePayer, agent);
        assertEq(call.multiplier, 10);
    }

    // ============ callWithReferralCode() Tests ============

    /// @notice Should pass referral code to fee collector
    function test_callWithReferralCode_PassesReferralCode() public {
        _enableTransferFee(2);

        vm.prank(alice);
        tokenProxy.callWithReferralCode(42, abi.encodeCall(Token.transfer, (bob, 100)));

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.feePayer, alice);
        assertEq(call.multiplier, 2);
        assertEq(call.referralCode, 42);
    }

    /// @notice Should pass referral code with transferFrom
    function test_callWithReferralCode_TransferFrom() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.transferFrom.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = 5;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);

        vm.prank(alice);
        token.approve(bob, 200);

        vm.prank(bob);
        tokenProxy.callWithReferralCode(999, abi.encodeCall(Token.transferFrom, (alice, bob, 100)));

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.feePayer, bob);
        assertEq(call.multiplier, 5);
        assertEq(call.referralCode, 999);
    }

    /// @notice Should bubble up revert from underlying function
    function test_callWithReferralCode_BubblesUpRevert() public {
        _enableTransferFee(1);

        // Alice tries to transfer more than her balance
        vm.prank(alice);
        vm.expectRevert();
        tokenProxy.callWithReferralCode(1, abi.encodeCall(Token.transfer, (bob, 999_999)));
    }

    /// @notice Should have referral code 0 when calling directly without callWithReferralCode
    function test_feeCollection_DefaultReferralCodeIsZero() public {
        _enableTransferFee(1);

        vm.prank(alice);
        token.transfer(bob, 100);

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.referralCode, 0);
    }

    /// @notice Should work with referral code 0
    function test_callWithReferralCode_ZeroReferralCode() public {
        _enableTransferFee(1);

        vm.prank(alice);
        tokenProxy.callWithReferralCode(0, abi.encodeCall(Token.transfer, (bob, 100)));

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.referralCode, 0);
    }

    /// @notice Should work with max referral code value
    function test_callWithReferralCode_MaxReferralCode() public {
        _enableTransferFee(1);

        vm.prank(alice);
        tokenProxy.callWithReferralCode(type(uint16).max, abi.encodeCall(Token.transfer, (bob, 100)));

        FeeCollectorRecordingMock.FeeCall memory call = recordingFeeCollector.getLastFeeCall();
        assertEq(call.referralCode, type(uint16).max);
    }

    // ============ Constructor Tests ============

    /// @notice Should revert when feeCollector is zero address in constructor
    function test_constructor_RevertWhen_FeeCollectorZeroAddress() public {
        address compliance = address(token.compliance());

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TokenProxy(
            address(trexImplementationAuthority),
            address(identityRegistry),
            compliance,
            "Test",
            "TST",
            0,
            address(0),
            address(accessManager),
            address(0)
        );
    }

    // ============ Helpers ============

    function _enableTransferFee(uint8 multiplier) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Token.transfer.selector;
        uint8[] memory multipliers = new uint8[](1);
        multipliers[0] = multiplier;

        vm.prank(deployer);
        tokenProxy.setFunctionsFees(selectors, multipliers);
    }

}
