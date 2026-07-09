// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
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

    function setUp() public override {
        super.setUp();

        pOnchainId = onchainId;
        pIdentityRegistry = identityRegistry;
        pCompliance = compliance;
        pTokenDecimals = 18;
        pName = "Token";
        pSymbol = "TKN";
        pOwner = address(this);
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

    function testTokenInitWithOnchainIdZeroAddress() public {
        pOnchainId = address(0);
        Token newToken = initCall();

        assertEq(newToken.onchainID(), address(0));
    }

    function testTokenInitNominal() public {
        vm.expectEmit(true, true, true, true);
        emit ERC3643EventsLib.UpdatedTokenInformation(pName, pSymbol, pTokenDecimals, "5.0.0", address(pOnchainId));
        Token newToken = initCall();

        assertEq(newToken.name(), pName);
        assertEq(newToken.symbol(), pSymbol);
        assertEq(newToken.decimals(), pTokenDecimals);
        assertEq(address(newToken.identityRegistry()), address(pIdentityRegistry));
        assertEq(address(newToken.compliance()), address(pCompliance));
        assertEq(address(newToken.onchainID()), address(pOnchainId));
        assertEq(IAccessManaged(address(newToken)).authority(), pOwner);

        assertTrue(newToken.paused());
    }

    /// ----- Helpers -----

    function initCall() internal returns (Token) {
        return Token(
            address(
                new ERC1967Proxy(
                    address(tokenImplementation),
                    abi.encodeCall(
                        Token.init, (pName, pSymbol, pTokenDecimals, pIdentityRegistry, pCompliance, pOnchainId, pOwner)
                    )
                )
            )
        );
    }

}
