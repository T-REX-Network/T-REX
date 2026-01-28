// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { TokenProxy } from "contracts/proxy/TokenProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { Token } from "contracts/token/Token.sol";

import { AccessManagerHelper } from "../../helpers/AccessManagerHelper.sol";

abstract contract TokenBaseUnitTest is Test, AccessManagerHelper {

    Token tokenImplementation;
    Token token;

    address implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address identityRegistry = makeAddr("IdentityRegistryMock");
    address compliance = makeAddr("ComplianceMock");
    address onchainId = makeAddr("OnchainIdMock");

    address feeCollector = makeAddr("FeeCollectorMock");

    address user1 = makeAddr("User1");
    address user2 = makeAddr("User2");

    address agent = makeAddr("Agent");

    constructor() {
        tokenImplementation = new Token();

        _mockFeeCollector();
        _mockImplementationAuthority();
        _mockCompliance();
        _mockIdentityRegistry();
    }

    function setUp() public virtual {
        token = Token(
            address(
                new TokenProxy(
                    implementationAuthority,
                    identityRegistry,
                    compliance,
                    "Token",
                    "TKN",
                    18,
                    address(onchainId),
                    address(accessManager),
                    feeCollector
                )
            )
        );

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupTokenRoles(accessManager, address(token));
        vm.stopPrank();

        _setRoles(address(this), agent);
    }

    function _mockImplementationAuthority() internal {
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getTokenImplementation.selector),
            abi.encode(address(tokenImplementation))
        );
    }

    function _mockCompliance() internal {
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.bindToken.selector), "");
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.unbindToken.selector), "");
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector), abi.encode(true));

        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.created.selector), "");
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.destroyed.selector), "");
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), "");
    }

    function _mockIdentityRegistry() internal {
        vm.mockCall(
            identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector), abi.encode(true)
        );

        vm.mockCall(identityRegistry, abi.encodeWithSelector(IERC3643IdentityRegistry.deleteIdentity.selector), "");

        _mockIdentity(user1, user1Identity);
        _mockIdentity(user2, user2Identity);
    }

    function _mockIdentity(address user, address identity) internal {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.identity.selector, user),
            abi.encode(identity)
        );
    }

     function _mockFeeCollector() internal {
        vm.mockCall(feeCollector, abi.encodeWithSignature("collectFee(address,uint8,uint16)"), "");
    }

    function mockFeeCollector() internal {
        vm.mockCall(feeCollector, abi.encodeWithSignature("collectFee(address,uint8,uint16)"), "");
    }

}
