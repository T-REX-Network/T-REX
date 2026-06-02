// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryProxy } from "contracts/proxy/IdentityRegistryProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";

import { AccessManagerHelper } from "../../helpers/AccessManagerHelper.sol";

/// @title batchRegisterIdentity coverage
/// @notice `batchRegisterIdentity` (IdentityRegistry.sol:138) is a thin loop over the `restricted`
///         `registerIdentity`, and was otherwise unexercised.
///
///         IMPORTANT WIRING QUIRK (real finding): `batchRegisterIdentity` is itself **not** `restricted` and is
///         **not** mapped to any role in `AccessManagerSetupLib.setupIdentityRegistryRoles`. Because the inner
///         `registerIdentity`'s `restricted` modifier inspects `_msgData()` — which during the internal call is
///         still the *outer* `batchRegisterIdentity` selector — the AccessManager evaluates `canCall` for an
///         unmapped selector, which defaults to the **admin role (0)**. So `batchRegisterIdentity` is callable
///         only by the AccessManager admin, NOT by an `AGENT` — unlike `registerIdentity` (AGENT) and unlike
///         Token's `batchMint`/`batchBurn` (wired to AGENT_MINTER/BURNER). These tests document that behaviour.
contract IdentityRegistryBatchRegisterUnitTest is AccessManagerHelper {

    IdentityRegistry private irImplementation;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private tir = makeAddr("TrustedIssuersRegistry");
    address private ctr = makeAddr("ClaimTopicsRegistry");
    address private irs = makeAddr("IdentityRegistryStorage");
    address private agent = makeAddr("Agent");

    IdentityRegistry private ir;

    function setUp() public {
        irImplementation = new IdentityRegistry();
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getIRImplementation.selector),
            abi.encode(address(irImplementation))
        );
        ir = IdentityRegistry(
            address(new IdentityRegistryProxy(implementationAuthority, tir, ctr, irs, address(accessManager)))
        );

        // registerIdentity is AGENT-gated; wire the role and grant it to `agent`.
        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupIdentityRegistryRoles(accessManager, address(ir));
        accessManager.grantRole(RolesLib.AGENT, agent, NO_DELAY);
        vm.stopPrank();

        // The storage layer is mocked — we only assert the registry forwards to it.
        vm.mockCall(irs, abi.encodeWithSelector(IERC3643IdentityRegistryStorage.addIdentityToStorage.selector), "");
    }

    function test_batchRegisterIdentity_ForwardsEveryEntry() public {
        address user1 = makeAddr("User1");
        address user2 = makeAddr("User2");
        IIdentity id1 = IIdentity(makeAddr("Id1"));
        IIdentity id2 = IIdentity(makeAddr("Id2"));

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        IIdentity[] memory ids = new IIdentity[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint16[] memory countries = new uint16[](2);
        countries[0] = 1;
        countries[1] = 42;

        vm.expectCall(
            irs, abi.encodeWithSelector(IERC3643IdentityRegistryStorage.addIdentityToStorage.selector, user1, id1, 1)
        );
        vm.expectCall(
            irs, abi.encodeWithSelector(IERC3643IdentityRegistryStorage.addIdentityToStorage.selector, user2, id2, 42)
        );

        // Only the AccessManager admin can call it — see the wiring quirk in the contract natspec.
        vm.prank(accessManagerAdmin);
        ir.batchRegisterIdentity(users, ids, countries);
    }

    /// @dev Documents the quirk: an `AGENT` (who CAN call `registerIdentity` directly) is rejected by
    ///      `batchRegisterIdentity` because the unmapped outer selector defaults to admin-only.
    function test_batchRegisterIdentity_RevertWhen_CallerIsAgentNotAdmin() public {
        address[] memory users = new address[](1);
        users[0] = makeAddr("User1");
        IIdentity[] memory ids = new IIdentity[](1);
        ids[0] = IIdentity(makeAddr("Id1"));
        uint16[] memory countries = new uint16[](1);
        countries[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        vm.prank(agent);
        ir.batchRegisterIdentity(users, ids, countries);
    }

}
