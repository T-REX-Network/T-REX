// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

contract FeeCollectorMock {

    function collectFee(address feePayer, uint8 multiplier, uint16 referralCode) external {
        // NOOP
    }

}
