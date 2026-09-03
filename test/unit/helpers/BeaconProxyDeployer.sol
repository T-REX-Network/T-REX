// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Deploys a single suite contract behind its own beacon, for unit tests that exercise one
///         implementation in isolation and do not need a TREXImplementationAuthority.
///         Internal library functions are inlined, so the beacon and proxy are created by the calling
///         test contract, which also owns the beacon.
///
///         `newBeacon` and `newProxy` are separate on purpose: a test asserting that `init` reverts must
///         have the beacon already deployed, otherwise `vm.expectRevert` binds to the beacon creation.
library BeaconProxyDeployer {

    function newBeacon(address implementation) internal returns (address) {
        return address(new UpgradeableBeacon(implementation, address(this)));
    }

    function newProxy(address beacon, bytes memory initData) internal returns (address) {
        return address(new BeaconProxy(beacon, initData));
    }

}
