// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { ClaimIssuer } from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TrustedIssuersRegistryProxy } from "contracts/proxy/TrustedIssuersRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { TrustedIssuersRegistry } from "contracts/registry/implementation/TrustedIssuersRegistry.sol";

contract TrustedIssuersRegistryInitUnitTest is Test {

    TrustedIssuersRegistry private tirImplementation;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private owner = makeAddr("Owner");
    address private notOwner = makeAddr("NotOwner");

    function setUp() public {
        tirImplementation = new TrustedIssuersRegistry();
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getTIRImplementation.selector),
            abi.encode(address(tirImplementation))
        );
    }

    function test_init_SetsOwnerFromArgument_NotDeployer() public {
        TrustedIssuersRegistry tir = _deployProxy(owner, new address[](0), new uint256[][](0));

        assertEq(tir.owner(), owner);
        assertNotEq(tir.owner(), address(this));
    }

    function test_init_RegistersAllProvidedIssuersWithTopics() public {
        ClaimIssuer issuer1 = new ClaimIssuer(makeAddr("issuer1Mgmt"));
        ClaimIssuer issuer2 = new ClaimIssuer(makeAddr("issuer2Mgmt"));

        address[] memory issuers = new address[](2);
        issuers[0] = address(issuer1);
        issuers[1] = address(issuer2);

        uint256[][] memory issuerClaims = new uint256[][](2);

        uint256[] memory topics1 = new uint256[](2);
        topics1[0] = 1;
        topics1[1] = 2;
        issuerClaims[0] = topics1;

        uint256[] memory topics2 = new uint256[](1);
        topics2[0] = 3;
        issuerClaims[1] = topics2;

        TrustedIssuersRegistry tir = _deployProxy(owner, issuers, issuerClaims);

        assertTrue(tir.isTrustedIssuer(address(issuer1)));
        assertTrue(tir.isTrustedIssuer(address(issuer2)));

        uint256[] memory storedTopics1 = tir.getTrustedIssuerClaimTopics(IClaimIssuer(address(issuer1)));
        assertEq(storedTopics1.length, 2);
        assertEq(storedTopics1[0], 1);
        assertEq(storedTopics1[1], 2);

        uint256[] memory storedTopics2 = tir.getTrustedIssuerClaimTopics(IClaimIssuer(address(issuer2)));
        assertEq(storedTopics2.length, 1);
        assertEq(storedTopics2[0], 3);

        IClaimIssuer[] memory allIssuers = tir.getTrustedIssuers();
        assertEq(allIssuers.length, 2);
    }

    function test_init_OwnerCanStillAddTrustedIssuerAfterInit() public {
        TrustedIssuersRegistry tir = _deployProxy(owner, new address[](0), new uint256[][](0));

        ClaimIssuer issuer = new ClaimIssuer(makeAddr("issuerMgmt"));
        uint256[] memory topics = new uint256[](1);
        topics[0] = 5;

        vm.prank(owner);
        tir.addTrustedIssuer(IClaimIssuer(address(issuer)), topics);

        assertTrue(tir.isTrustedIssuer(address(issuer)));
    }

    function test_addTrustedIssuer_RevertWhen_NotOwner() public {
        TrustedIssuersRegistry tir = _deployProxy(owner, new address[](0), new uint256[][](0));

        ClaimIssuer issuer = new ClaimIssuer(makeAddr("issuerMgmt"));
        uint256[] memory topics = new uint256[](1);
        topics[0] = 5;

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        tir.addTrustedIssuer(IClaimIssuer(address(issuer)), topics);
    }

    function test_init_RevertWhen_OwnerIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new TrustedIssuersRegistryProxy(implementationAuthority, address(0), new address[](0), new uint256[][](0));
    }

    function test_init_RevertWhen_LengthMismatch() public {
        address[] memory issuers = new address[](1);
        issuers[0] = makeAddr("issuer");
        uint256[][] memory issuerClaims = new uint256[][](0);

        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new TrustedIssuersRegistryProxy(implementationAuthority, owner, issuers, issuerClaims);
    }

    function test_init_RevertWhen_MoreThan5Issuers() public {
        address[] memory issuers = new address[](6);
        uint256[][] memory issuerClaims = new uint256[][](6);

        for (uint256 i = 0; i < 6; i++) {
            issuers[i] = makeAddr(string(abi.encodePacked("issuer", i)));
            uint256[] memory topics = new uint256[](1);
            topics[0] = i + 1;
            issuerClaims[i] = topics;
        }

        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new TrustedIssuersRegistryProxy(implementationAuthority, owner, issuers, issuerClaims);
    }

    function _deployProxy(address _owner, address[] memory _issuers, uint256[][] memory _issuerClaims)
        private
        returns (TrustedIssuersRegistry)
    {
        return TrustedIssuersRegistry(
            address(new TrustedIssuersRegistryProxy(implementationAuthority, _owner, _issuers, _issuerClaims))
        );
    }

}
