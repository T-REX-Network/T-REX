// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { VersionLib } from "contracts/libraries/VersionLib.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice The platform and a suite answer to different AccessManagers, as a deployment does: the factory
///         deploys a fresh manager per suite whose only admin, from its first block, is the issuer, so no platform
///         key opens a suite door and no suite key opens a platform door, whatever its power on its own side. The fixture
///         keeps the two apart for the same reason; one manager for both could not state any of this.
/// @notice The platform manager and the suite manager keep platform keys and suite keys apart, as a deployment
///         keeps them apart. The fixture passes its own `suiteManager` as `tokenDetails.accessManager`, so this
///         file models an issuer bringing one manager shared by every suite the fixture deploys. The other path,
///         where the factory mints a fresh manager per suite and holds no role on it, is covered in
///         `TREXFactoryAccessManager.t.sol`.
contract PlatformSuiteSeparationTest is TREXSuiteTest {

    address platformAdmin = makeAddr("platformAdmin");
    address suiteOwner = makeAddr("suiteOwner");

    function setUp() public override {
        super.setUp();
        platformManager.grantRole(AccessManagerSetupLib.ADMIN_ROLE, platformAdmin, NO_EXECUTION_DELAY);
        _grantOwnerRole(suiteOwner);
    }

    /// @notice Every platform contract names the platform manager and every suite contract the suite manager.
    function test_platformAndSuiteContracts_AnswerToDifferentManagers() public view {
        assertNotEq(address(platformManager), address(suiteManager));

        assertEq(IAccessManaged(address(trexFactory)).authority(), address(platformManager));
        assertEq(IAccessManaged(address(trexImplementationAuthority)).authority(), address(platformManager));
        assertEq(IAccessManaged(address(trustedGatewayRegistry)).authority(), address(platformManager));
        assertEq(IAccessManaged(address(idFactory)).authority(), address(platformManager));

        assertEq(IAccessManaged(address(token)).authority(), address(suiteManager));
        assertEq(IAccessManaged(address(token.identityRegistry())).authority(), address(suiteManager));
        assertEq(IAccessManaged(address(token.identityRegistry().identityStorage())).authority(), address(suiteManager));
        assertEq(IAccessManaged(address(token.compliance())).authority(), address(suiteManager));
    }

    /// @notice ADMIN_ROLE on the platform manager reaches no suite door: a token asks its own authority, which
    ///         has never heard of the platform admin.
    function test_platformAdmin_CannotOperateTheSuite() public {
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, platformAdmin);
        // Resolved first: a view call made after `expectRevert` would be the call it watches.
        ModularCompliance compliance = ModularCompliance(address(token.compliance()));
        IERC3643IdentityRegistry registry = token.identityRegistry();

        vm.prank(platformAdmin);
        vm.expectRevert(unauthorized);
        token.mint(alice, 1);

        vm.prank(platformAdmin);
        vm.expectRevert(unauthorized);
        compliance.addModule(makeAddr("module"));

        vm.prank(platformAdmin);
        vm.expectRevert(unauthorized);
        registry.registerIdentity(david, aliceIdentity, 0);
    }

    /// @notice The suite OWNER decides the suite's rules and nothing about what future suites inherit.
    function test_suiteOwner_CannotConfigureThePlatform() public {
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, suiteOwner);

        vm.prank(suiteOwner);
        vm.expectRevert(unauthorized);
        trexFactory.setImplementationAuthority(address(trexImplementationAuthority));

        vm.prank(suiteOwner);
        vm.expectRevert(unauthorized);
        trexImplementationAuthority.publishAndUpgrade(VersionLib.pack(5, 0, 1), _suiteImplementations());

        vm.prank(suiteOwner);
        vm.expectRevert(unauthorized);
        trustedGatewayRegistry.setTrustedGateway(makeAddr("gateway"), true);
    }

    /// @notice A role id is only meaningful on the manager it was granted on: the deployer holds the suite
    ///         deployer role on the platform manager and the OWNER role on the suite manager, and neither
    ///         manager knows about the other grant.
    function test_roles_LiveOnlyOnTheManagerTheyWereGrantedOn() public view {
        (bool deployerOnPlatform,) = platformManager.hasRole(_suiteDeployerRole(), deployer);
        (bool deployerOnSuite,) = suiteManager.hasRole(_suiteDeployerRole(), deployer);
        assertTrue(deployerOnPlatform, "suite deployer must be held on the platform manager");
        assertFalse(deployerOnSuite, "suite deployer must not exist on the suite manager");

        (bool ownerOnSuite,) = suiteManager.hasRole(_role(RolesLib.Role.OWNER), deployer);
        (bool ownerOnPlatform,) = platformManager.hasRole(_role(RolesLib.Role.OWNER), deployer);
        assertTrue(ownerOnSuite, "suite OWNER must be held on the suite manager");
        assertFalse(ownerOnPlatform, "suite OWNER must not exist on the platform manager");
    }

}
