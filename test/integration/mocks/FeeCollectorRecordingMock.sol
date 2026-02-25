// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

contract FeeCollectorRecordingMock {

    struct FeeCall {
        address feePayer;
        uint8 multiplier;
        uint16 referralCode;
    }

    FeeCall[] public feeCalls;

    function collectFee(address feePayer, uint8 multiplier, uint16 referralCode) external {
        feeCalls.push(FeeCall({ feePayer: feePayer, multiplier: multiplier, referralCode: referralCode }));
    }

    function getFeeCallCount() external view returns (uint256) {
        return feeCalls.length;
    }

    function getLastFeeCall() external view returns (FeeCall memory) {
        return feeCalls[feeCalls.length - 1];
    }

}
