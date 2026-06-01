// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { TREXSuiteTest } from "../integration/helpers/TREXSuiteTest.sol";

/// @title TREXGateway fee fuzzing
/// @notice Property tests for the deployment-fee discount math: it must never underflow and must be bounded by
///         the base fee, hitting exactly zero at the 100% (10000 bps) cap.
contract GatewayFuzzTest is TREXSuiteTest {

    function testFuzz_calculateFee(uint256 fee, uint16 discount) public {
        fee = bound(fee, 0, 1e30);
        discount = uint16(bound(discount, 0, 10000)); // applyFeeDiscount caps at 10000

        vm.prank(deployer); // OWNER owns setDeploymentFee
        trexGateway.setDeploymentFee(fee, address(0xFEE), address(0xC0));
        // NOTE: applyFeeDiscount is wired to AGENT (not OWNER) — setupTREXGatewayRoles reassigns the selector to
        // AGENT after assigning it to OWNER, and setTargetFunctionRole is last-write-wins. See SECURITY-ANALYSIS
        // AV-10. So it must be called by `agent`, not `deployer`.
        vm.prank(agent);
        trexGateway.applyFeeDiscount(deployer, discount);

        uint256 got = trexGateway.calculateFee(deployer);
        uint256 expected = fee - ((uint256(discount) * fee) / 10000);

        assertEq(got, expected, "fee mismatch");
        assertLe(got, fee, "fee exceeds base");
        if (discount == 10000) assertEq(got, 0, "100% discount should zero the fee");
        if (discount == 0) assertEq(got, fee, "0% discount should equal base");
    }

    /// Discounts above the cap must revert (guards against calculateFee underflow).
    function testFuzz_discountAboveCapReverts(uint16 discount) public {
        discount = uint16(bound(discount, 10001, type(uint16).max));
        vm.prank(agent); // AGENT owns applyFeeDiscount (see AV-10)
        vm.expectRevert();
        trexGateway.applyFeeDiscount(deployer, discount);
    }
}
