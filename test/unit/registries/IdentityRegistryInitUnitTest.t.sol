// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { IdentityRegistryProxy } from "contracts/proxy/IdentityRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";

contract IdentityRegistryInitUnitTest is Test {

    IdentityRegistry private irImplementation;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private owner = makeAddr("Owner");
    address private notOwner = makeAddr("NotOwner");

    address private tir = makeAddr("TrustedIssuersRegistry");
    address private ctr = makeAddr("ClaimTopicsRegistry");
    address private irs = makeAddr("IdentityRegistryStorage");
    address private tokenAddress = makeAddr("Token");

    function setUp() public {
        irImplementation = new IdentityRegistry();
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getIRImplementation.selector),
            abi.encode(address(irImplementation))
        );
    }

    function test_init_SetsOwnerFromArgument_NotDeployer() public {
        IdentityRegistry ir = _deployProxy(owner, new address[](0));

        assertEq(ir.owner(), owner);
        assertNotEq(ir.owner(), address(this));
    }

    function test_init_SetsDependencies() public {
        IdentityRegistry ir = _deployProxy(owner, new address[](0));

        assertEq(address(ir.issuersRegistry()), tir);
        assertEq(address(ir.topicsRegistry()), ctr);
        assertEq(address(ir.identityStorage()), irs);
    }

    function test_init_GrantsAgentRoleToTokenAddress() public {
        IdentityRegistry ir = _deployProxy(owner, new address[](0));

        assertTrue(ir.isAgent(tokenAddress));
    }

    function test_init_GrantsAgentRoleForEachIRAgent() public {
        address agent1 = makeAddr("agent1");
        address agent2 = makeAddr("agent2");

        address[] memory irAgents = new address[](2);
        irAgents[0] = agent1;
        irAgents[1] = agent2;

        IdentityRegistry ir = _deployProxy(owner, irAgents);

        assertTrue(ir.isAgent(agent1));
        assertTrue(ir.isAgent(agent2));
        assertTrue(ir.isAgent(tokenAddress));
    }

    function test_init_OwnerCanStillAddAgentAfterInit() public {
        IdentityRegistry ir = _deployProxy(owner, new address[](0));

        address newAgent = makeAddr("newAgent");
        vm.prank(owner);
        ir.addAgent(newAgent);

        assertTrue(ir.isAgent(newAgent));
    }

    function test_addAgent_RevertWhen_NotOwner() public {
        IdentityRegistry ir = _deployProxy(owner, new address[](0));

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        ir.addAgent(makeAddr("someAgent"));
    }

    function test_init_RevertWhen_OwnerIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, address(0), new address[](0), tokenAddress);
    }

    function test_init_RevertWhen_TIRIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, address(0), ctr, irs, owner, new address[](0), tokenAddress);
    }

    function test_init_RevertWhen_CTRIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, address(0), irs, owner, new address[](0), tokenAddress);
    }

    function test_init_RevertWhen_IRSIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, ctr, address(0), owner, new address[](0), tokenAddress);
    }

    function test_init_RevertWhen_TokenAddressIsZero() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, owner, new address[](0), address(0));
    }

    function test_init_RevertWhen_MoreThan5IRAgents() public {
        address[] memory irAgents = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            irAgents[i] = address(uint160(i + 1));
        }

        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, owner, irAgents, tokenAddress);
    }

    function test_init_RevertWhen_IRAgentIsZeroAddress() public {
        address[] memory irAgents = new address[](1);
        irAgents[0] = address(0);

        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, owner, irAgents, tokenAddress);
    }

    function _deployProxy(address _owner, address[] memory _irAgents) private returns (IdentityRegistry) {
        return IdentityRegistry(
            address(new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, _owner, _irAgents, tokenAddress))
        );
    }

}
