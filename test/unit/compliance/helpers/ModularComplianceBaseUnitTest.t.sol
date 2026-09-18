// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { AccessManagerHelper } from "test/integration/helpers/AccessManagerHelper.sol";
import { TransferValidationHarness } from "test/integration/helpers/TransferValidationHarness.sol";
import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

/// @notice Base for the ModularCompliance unit suites: one compliance behind a beacon proxy and a real
///         AccessManager, its selectors wired through `AccessManagerSetupLib`, the token and the registry
///         replaced by addresses ready for `vm.mockCall`.
/// @dev The implementation is {TransferValidationHarness}, a ModularCompliance that also exposes the validation
///      layer's internal hooks; suites that need none of them use it as a plain compliance.
abstract contract ModularComplianceBaseUnitTest is AccessManagerHelper {

    TransferValidationHarness public mc;
    address public mcBeacon;

    address public token = makeAddr("Token");
    address public registry = makeAddr("Registry");
    address public stranger = makeAddr("Stranger");

    function setUp() public virtual {
        _deployAccessManager();
        mcBeacon = BeaconProxyDeployer.newBeacon(address(new TransferValidationHarness()));
        mc = TransferValidationHarness(
            BeaconProxyDeployer.newProxy(
                mcBeacon,
                abi.encodeCall(
                    ModularCompliance.init, (token, address(accessManager), new address[](0), new bytes[](0))
                )
            )
        );
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, address(mc));
        _grantOwnerRole(address(this));
        _grantComplianceManagerRole(address(this));
        _grantAgentRole(agentAccount);
    }

    address public agentAccount = makeAddr("Agent");

}
