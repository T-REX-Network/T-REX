// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { Token } from "contracts/token/Token.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenInitUnitTest is TokenBaseUnitTest {

    string pName;
    string pSymbol;
    uint8 pTokenDecimals;
    address pIdentityRegistry;
    address pCompliance;
    address pOnchainId;
    address pOwner;
    address[] pTokenAgents;

    function setUp() public override {
        super.setUp();

        pOnchainId = onchainId;
        pIdentityRegistry = identityRegistry;
        pCompliance = compliance;
        pTokenDecimals = 18;
        pName = "Token";
        pSymbol = "TKN";
        pOwner = address(this);
        delete pTokenAgents;
    }

    function testTokenInitRevertsIfNameIsEmpty() public {
        pName = "";
        vm.expectRevert(ErrorsLib.EmptyString.selector);
        initCall();
    }

    function testTokenInitRevertsIfSymbolIsEmpty() public {
        pSymbol = "";
        vm.expectRevert(ErrorsLib.EmptyString.selector);
        initCall();
    }

    function testTokenInitRevertsIfDecimalsIsOutOfRange() public {
        pTokenDecimals = 19;
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DecimalsOutOfRange.selector, pTokenDecimals));
        initCall();
    }

    function testTokenInitRevertsIfIdentityRegistryIsZeroAddress() public {
        pIdentityRegistry = address(0);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        initCall();
    }

    function testTokenInitRevertsIfComplianceIsZeroAddress() public {
        pCompliance = address(0);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        initCall();
    }

    function testTokenInitRevertsIfOwnerIsZeroAddress() public {
        pOwner = address(0);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        initCall();
    }

    function testTokenInitRevertsIfTokenAgentsCapExceeded() public {
        pTokenAgents = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            pTokenAgents[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxAgentsReached.selector, 5));
        initCall();
    }

    function testTokenInitWithOnchainIdZeroAddress() public {
        pOnchainId = address(0);
        Token newToken = initCall();

        assertEq(newToken.onchainID(), address(0));
    }

    function testTokenInitNominal() public {
        vm.expectEmit(true, true, true, true);
        emit OwnableUpgradeable.OwnershipTransferred(address(0), pOwner);
        vm.expectEmit(true, true, true, true);
        emit ERC3643EventsLib.UpdatedTokenInformation(pName, pSymbol, pTokenDecimals, "5.0.0", address(pOnchainId));
        Token newToken = initCall();

        assertEq(newToken.name(), pName);
        assertEq(newToken.symbol(), pSymbol);
        assertEq(newToken.decimals(), pTokenDecimals);
        assertEq(address(newToken.identityRegistry()), address(pIdentityRegistry));
        assertEq(address(newToken.compliance()), address(pCompliance));
        assertEq(address(newToken.onchainID()), address(pOnchainId));
        assertEq(newToken.owner(), pOwner);

        assertTrue(newToken.paused());
    }

    function testTokenInitGrantsAgentRoleToEveryTokenAgent() public {
        pTokenAgents = new address[](3);
        pTokenAgents[0] = makeAddr("AgentA");
        pTokenAgents[1] = makeAddr("AgentB");
        pTokenAgents[2] = makeAddr("AgentC");

        vm.expectEmit(true, true, true, true);
        emit EventsLib.AgentAdded(pTokenAgents[0]);
        vm.expectEmit(true, true, true, true);
        emit EventsLib.AgentAdded(pTokenAgents[1]);
        vm.expectEmit(true, true, true, true);
        emit EventsLib.AgentAdded(pTokenAgents[2]);
        Token newToken = initCall();

        for (uint256 i = 0; i < pTokenAgents.length; i++) {
            assertTrue(newToken.isAgent(pTokenAgents[i]), "configured token agent must hold agent role");
        }
    }

    /// ----- Helpers -----

    function initCall() internal returns (Token) {
        return Token(
            address(
                new ERC1967Proxy(
                    address(tokenImplementation),
                    abi.encodeCall(
                        Token.init,
                        (
                            pName,
                            pSymbol,
                            pTokenDecimals,
                            pIdentityRegistry,
                            pCompliance,
                            pOnchainId,
                            pOwner,
                            pTokenAgents
                        )
                    )
                )
            )
        );
    }

}
