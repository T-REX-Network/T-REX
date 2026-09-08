// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
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

    /// @dev Makes a mock pass the ERC165Checker guard on the token's dependency setters.
    function mockSupportsInterface(address target, bytes4 interfaceId) internal {
        vm.mockCall(target, abi.encodeCall(IERC165.supportsInterface, (type(IERC165).interfaceId)), abi.encode(true));
        vm.mockCall(target, abi.encodeCall(IERC165.supportsInterface, (bytes4(0xffffffff))), abi.encode(false));
        vm.mockCall(target, abi.encodeCall(IERC165.supportsInterface, (interfaceId)), abi.encode(true));
    }

    function mockIdentityRegistry() internal {
        vm.mockCall(
            identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector), abi.encode(true)
        );

        vm.mockCall(identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.deleteIdentity.selector), "");
    }

}
