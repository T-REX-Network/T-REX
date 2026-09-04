// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";

import { AccessManagerHelper } from "test/integration/helpers/AccessManagerHelper.sol";
import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

abstract contract TokenBaseUnitTest is AccessManagerHelper {

    Token tokenImplementation;
    Token token;

    address tokenBeacon;

    address identityRegistry = makeAddr("IdentityRegistryMock");
    address compliance = makeAddr("ComplianceMock");
    address onchainId = makeAddr("OnchainIdMock");

    address user1 = makeAddr("User1");
    address user2 = makeAddr("User2");

    address agent = makeAddr("Agent");

    constructor() {
        tokenImplementation = new Token();
        tokenBeacon = BeaconProxyDeployer.newBeacon(address(tokenImplementation));

        mockCompliance();
        mockIdentityRegistry();
    }

    function setUp() public virtual {
        // the AccessManager cannot be mocked: AccessManaged calls canCall on it for every restricted function
        _deployAccessManager();

        token = Token(
            BeaconProxyDeployer.newProxy(
                tokenBeacon,
                abi.encodeCall(
                    Token.init,
                    ("Token", "TKN", 18, identityRegistry, compliance, address(onchainId), address(accessManager))
                )
            )
        );

        AccessManagerSetupLib.setupTokenRoles(accessManager, address(token));
        _grantAllAgentRoles(agent);
    }

    function mockCompliance() internal {
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.bindToken.selector), "");
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.unbindToken.selector), "");
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector), abi.encode(true));
        vm.mockCall(compliance, abi.encodeWithSelector(IModularCompliance.canSpenderCall.selector), abi.encode(true));

        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.created.selector), "");
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.destroyed.selector), "");
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), "");
    }

    function mockIdentityRegistry() internal {
        vm.mockCall(
            identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector), abi.encode(true)
        );

        vm.mockCall(identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.deleteIdentity.selector), "");

        // Reconciliation runs on every balance move. Left inert here — no identity, nothing cached and
        // nothing attested — so it writes nothing and these suites keep testing their own subject.
        // Tests that care about it override these.
        vm.mockCall(
            identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.identity.selector), abi.encode(address(0))
        );
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(ITREXRegistry.reconcileAttribute.selector),
            abi.encode(uint256(0), uint16(0), uint16(0), false)
        );
    }

}
