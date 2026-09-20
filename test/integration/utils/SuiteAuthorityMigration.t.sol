// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { KeyManager } from "@onchain-id/solidity/contracts/KeyManager.sol";
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Errors as IdentityErrors } from "@onchain-id/solidity/contracts/libraries/Errors.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { Token } from "contracts/token/Token.sol";
import { SuiteAuthorityMigrator } from "contracts/utils/SuiteAuthorityMigrator.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract SuiteAuthorityMigrationTest is TREXSuiteTest {

    SuiteAuthorityMigrator internal migrator;
    AccessManager internal newAuthority;
    UpgradeableBeacon internal beacon;
    IERC173[] internal extras;
    address internal identity;

    function setUp() public override {
        super.setUp();
        migrator = new SuiteAuthorityMigrator();
        newAuthority = new AccessManager(address(this));
        beacon = new UpgradeableBeacon(address(tokenImplementation), address(accessManager));
        extras.push(IERC173(address(beacon)));
        identity = token.onchainID();
    }

    function test_migrateSuite_Success_RotatesEverySuiteContractAndExtraTarget() public {
        _wire(_tokens(address(token)));

        _migrate(address(token), true);

        _assertOwnedBy(_suite(token), address(newAuthority));
        assertEq(beacon.owner(), address(newAuthority));
    }

    function test_migrateSuite_Success_NewAuthorityAdministersIdentityAndOldCannot() public {
        _wire(_tokens(address(token)));

        _migrate(address(token), true);

        assertTrue(_isManager(identity, address(newAuthority)));
        assertFalse(_isManager(identity, address(accessManager)));

        newAuthority.execute(identity, _addKeyCall(another));
        assertTrue(_isManager(identity, another));

        bytes memory signerData = abi.encodePacked(bob);
        vm.prank(address(accessManager));
        vm.expectRevert(IdentityErrors.SenderDoesNotHaveManagementKey.selector);
        KeyManager(identity)
            .addKeyWithData(keccak256(signerData), KeyPurposes.MANAGEMENT, KeyTypes.ECDSA, signerData, bytes(""));
        assertFalse(_isManager(identity, bob));
    }

    function test_migrateSuite_Success_EmitsEvent() public {
        _wire(_tokens(address(token)));

        vm.expectEmit(true, true, true, true, address(migrator));
        emit EventsLib.SuiteAuthorityMigrated(address(token), address(accessManager), address(newAuthority), true);
        _migrate(address(token), true);
    }

    function test_migrateSuite_Success_WhenNewAuthorityAlreadyHoldsManagement() public {
        accessManager.execute(identity, _addKeyCall(address(newAuthority)));
        _wire(_tokens(address(token)));

        _migrate(address(token), true);

        assertTrue(_isManager(identity, address(newAuthority)));
        assertFalse(_isManager(identity, address(accessManager)));
        assertEq(IERC173(address(token)).owner(), address(newAuthority));
    }

    function test_migrateSuite_Success_WhenAdministratorIsDelayed() public {
        _wire(_tokens(address(token)));
        address delayedAdmin = makeAddr("delayedAdmin");
        accessManager.grantRole(accessManager.ADMIN_ROLE(), delayedAdmin, 1 days);
        bytes memory data = _migrateCall(address(token), true);
        bytes32 operationId = accessManager.hashOperation(delayedAdmin, address(migrator), data);

        vm.prank(delayedAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operationId));
        accessManager.execute(address(migrator), data);
        _assertUntouched(token, identity, address(accessManager));

        vm.prank(delayedAdmin);
        accessManager.schedule(address(migrator), data, uint48(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        vm.prank(delayedAdmin);
        accessManager.execute(address(migrator), data);

        _assertOwnedBy(_suite(token), address(newAuthority));
        assertTrue(_isManager(identity, address(newAuthority)));
        assertFalse(_isManager(identity, address(accessManager)));
    }

    function test_migrateSuite_Success_MigratesIsolatedSuiteBeacons() public {
        (address isolated, ITREXImplementationAuthority.SuiteBeacons memory beacons) = _deployIsolatedSuite();
        delete extras;
        extras.push(IERC173(beacons.tokenBeacon));
        extras.push(IERC173(beacons.trexRegistryBeacon));
        extras.push(IERC173(beacons.irsBeacon));
        extras.push(IERC173(beacons.mcBeacon));
        _wire(_tokens(isolated));

        _migrate(isolated, true);

        _assertOwnedBy(_suite(Token(isolated)), address(newAuthority));
        for (uint256 i = 0; i < extras.length; i++) {
            assertEq(extras[i].owner(), address(newAuthority));
        }
    }

    function test_migrateSuite_RevertWhen_IdentityRegistryStorageIsShared() public {
        Token sibling = _deployTokenSharingStorage();
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(sibling);
        _wire(tokens);
        address irs = address(token.identityRegistry().identityStorage());

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SharedIdentityRegistryStorage.selector, irs));
        _migrate(address(token), true);

        _assertUntouched(token, identity, address(accessManager));
        _assertOwnedBy(_suite(sibling), address(accessManager));
    }

    function test_migrateSuites_Success_WhenEverySuiteSharingStorageIsMigratedTogether() public {
        Token sibling = _deployTokenSharingStorage();
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(sibling);
        _wire(tokens);

        accessManager.execute(
            address(migrator),
            abi.encodeCall(SuiteAuthorityMigrator.migrateSuites, (tokens, extras, address(newAuthority), true))
        );

        _assertOwnedBy(_suite(token), address(newAuthority));
        _assertOwnedBy(_suite(sibling), address(newAuthority));
        assertTrue(_isManager(identity, address(newAuthority)));
        assertTrue(_isManager(sibling.onchainID(), address(newAuthority)));
        assertFalse(_isManager(identity, address(accessManager)));
        assertFalse(_isManager(sibling.onchainID(), address(accessManager)));
    }

    function test_migrateSuite_RevertWhen_IdentityNotManagedByAuthority() public {
        (Token suppliedToken, address suppliedIdentity, address wallet) = _deployTokenWithSuppliedIdentity();
        _wire(_tokens(address(suppliedToken)));

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.IdentityNotManagedByAuthority.selector, suppliedIdentity, address(accessManager)
            )
        );
        _migrate(address(suppliedToken), true);

        _assertUntouched(suppliedToken, suppliedIdentity, wallet);
    }

    function test_migrateSuite_Success_WhenSuppliedIdentityIsSkipped() public {
        (Token suppliedToken, address suppliedIdentity, address wallet) = _deployTokenWithSuppliedIdentity();
        _wire(_tokens(address(suppliedToken)));

        vm.expectEmit(true, true, true, true, address(migrator));
        emit EventsLib.SuiteAuthorityMigrated(
            address(suppliedToken), address(accessManager), address(newAuthority), false
        );
        _migrate(address(suppliedToken), false);

        _assertOwnedBy(_suite(suppliedToken), address(newAuthority));
        assertTrue(_isManager(suppliedIdentity, wallet));
        assertFalse(_isManager(suppliedIdentity, address(newAuthority)));
        assertFalse(_isManager(suppliedIdentity, address(accessManager)));
    }

    function test_migrateSuite_RevertWhen_TargetNotOwnedByAuthority_LeavesIdentityUnchanged() public {
        UpgradeableBeacon foreign = new UpgradeableBeacon(address(tokenImplementation), another);
        extras.push(IERC173(address(foreign)));
        _wire(_tokens(address(token)));

        vm.expectRevert(ErrorsLib.AuthorityMismatch.selector);
        _migrate(address(token), true);

        _assertUntouched(token, identity, address(accessManager));
        assertFalse(_isManager(identity, address(newAuthority)));
    }

    function test_migrateSuite_RevertWhen_KeyRemovalRevertsAfterAuthoritiesMoved() public {
        _wire(_tokens(address(token)));
        vm.mockCallRevert(identity, abi.encodeWithSelector(IERC734.removeKey.selector), "key removal refused");

        vm.expectRevert("key removal refused");
        _migrate(address(token), true);

        _assertUntouched(token, identity, address(accessManager));
        assertFalse(_isManager(identity, address(newAuthority)));
    }

    function test_migrateSuite_RevertWhen_KeyRemovalSucceedsWithoutRemoving() public {
        _wire(_tokens(address(token)));
        vm.mockCall(identity, abi.encodeWithSelector(IERC734.removeKey.selector), abi.encode(true));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.IdentityRotationFailed.selector, identity));
        _migrate(address(token), true);

        _assertUntouched(token, identity, address(accessManager));
        assertFalse(_isManager(identity, address(newAuthority)));
    }

    function test_migrateSuite_RevertWhen_KeyAdditionSucceedsWithoutAdding() public {
        _wire(_tokens(address(token)));
        vm.mockCall(identity, abi.encodeWithSelector(KeyManager.addKeyWithData.selector), "");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.IdentityRotationFailed.selector, identity));
        _migrate(address(token), true);

        _assertUntouched(token, identity, address(accessManager));
        assertFalse(_isManager(identity, address(newAuthority)));
    }

    function test_migrateSuite_RevertWhen_MigratorNotAuthorisedOnOldAuthority() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                address(migrator),
                identity,
                KeyManager.addKeyWithData.selector
            )
        );
        _migrate(address(token), true);

        _assertUntouched(token, identity, address(accessManager));
    }

    function test_migrateSuite_RevertWhen_NotCalledThroughCurrentAuthority() public {
        _wire(_tokens(address(token)));

        vm.expectRevert(ErrorsLib.OnlyAuthorityCanCall.selector);
        migrator.migrateSuite(address(token), extras, address(newAuthority), true);

        vm.prank(address(newAuthority));
        vm.expectRevert(ErrorsLib.OnlyAuthorityCanCall.selector);
        migrator.migrateSuite(address(token), extras, address(newAuthority), true);
    }

    function test_migrateSuite_RevertWhen_CallerIsNotAdminOfOldAuthority() public {
        _wire(_tokens(address(token)));
        bytes memory data = _migrateCall(address(token), true);

        vm.prank(another);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                another,
                address(migrator),
                SuiteAuthorityMigrator.migrateSuite.selector
            )
        );
        accessManager.execute(address(migrator), data);
    }

    function test_migrateSuite_RevertWhen_NewAuthorityIsCurrentAuthority() public {
        _wire(_tokens(address(token)));

        vm.expectRevert(ErrorsLib.SameAuthority.selector);
        accessManager.execute(
            address(migrator),
            abi.encodeCall(SuiteAuthorityMigrator.migrateSuite, (address(token), extras, address(accessManager), true))
        );
    }

    function test_migrateSuite_RevertWhen_NewAuthorityIsZero() public {
        _wire(_tokens(address(token)));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        accessManager.execute(
            address(migrator),
            abi.encodeCall(SuiteAuthorityMigrator.migrateSuite, (address(token), extras, address(0), true))
        );
    }

    function test_migrateSuite_RevertWhen_SkippingRotationOfAnIdentityTheOldAuthorityManages() public {
        _wire(_tokens(address(token)));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.IdentityRotationRequired.selector, identity));
        _migrate(address(token), false);

        _assertUntouched(token, identity, address(accessManager));
        assertFalse(_isManager(identity, address(newAuthority)));
    }

    function test_migrateSuite_RevertWhen_NewAuthorityIsNotAContract() public {
        _wire(_tokens(address(token)));
        address eoa = makeAddr("eoa");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NewAuthorityNotAContract.selector, eoa));
        accessManager.execute(
            address(migrator), abi.encodeCall(SuiteAuthorityMigrator.migrateSuite, (address(token), extras, eoa, true))
        );

        _assertUntouched(token, identity, address(accessManager));
    }

    function _migrate(address tokenAddress, bool rotateIdentity) private {
        accessManager.execute(address(migrator), _migrateCall(tokenAddress, rotateIdentity));
    }

    function _migrateCall(address tokenAddress, bool rotateIdentity) private view returns (bytes memory) {
        return abi.encodeCall(
            SuiteAuthorityMigrator.migrateSuite, (tokenAddress, extras, address(newAuthority), rotateIdentity)
        );
    }

    function _wire(address[] memory tokens) private {
        address[] memory extraAddresses = new address[](extras.length);
        for (uint256 i = 0; i < extras.length; i++) {
            extraAddresses[i] = address(extras[i]);
        }
        AccessManagerSetupLib.setupSuiteMigrationRoles(accessManager, address(migrator), tokens, extraAddresses);
        (bool granted,) = accessManager.hasRole(RolesLib.SUITE_MIGRATOR, address(migrator));
        assertTrue(granted);
    }

    function _tokens(address tokenAddress) private pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = tokenAddress;
    }

    function _deployTokenWithSuppliedIdentity() private returns (Token, address, address) {
        address wallet = makeAddr("issuerWallet");
        IIdentity supplied = _deployIdentity(wallet, "supplied-oid");
        ITREXFactory.TokenDetails memory tokenDetails = _details("Supplied", "SUP");
        tokenDetails.ONCHAINID = address(supplied);
        _deploySuite("supplied", tokenDetails, _noClaims());
        return (Token(trexFactory.getToken("supplied")), address(supplied), wallet);
    }

    function _deployTokenSharingStorage() private returns (Token) {
        ITREXFactory.TokenDetails memory tokenDetails = _details("Sibling", "SIB");
        tokenDetails.irs = address(token.identityRegistry().identityStorage());
        _deploySuite("sibling", tokenDetails, _noClaims());
        Token sibling = Token(trexFactory.getToken("sibling"));
        _grantIRSBinderRole(address(this));
        IdentityRegistryStorage(tokenDetails.irs).bindIdentityRegistry(address(sibling.identityRegistry()));
        return sibling;
    }

    function _deployIsolatedSuite()
        private
        returns (address tokenAddress, ITREXImplementationAuthority.SuiteBeacons memory beacons)
    {
        vm.recordLogs();
        vm.prank(deployer);
        trexFactory.deployTREXSuiteIsolated("isolated", _details("Isolated", "ISO"), _noClaims());
        tokenAddress = trexFactory.getToken("isolated");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(trexFactory) && logs[i].topics[0] == EventsLib.IsolatedSuiteDeployed.selector
            ) {
                beacons = abi.decode(logs[i].data, (ITREXImplementationAuthority.SuiteBeacons));
            }
        }
        assertNotEq(beacons.tokenBeacon, address(0));
    }

    function _details(string memory name, string memory symbol)
        private
        view
        returns (ITREXFactory.TokenDetails memory)
    {
        return ITREXFactory.TokenDetails({
            name: name,
            symbol: symbol,
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(accessManager),
            accessManagerAdmin: address(0)
        });
    }

    function _noClaims() private pure returns (ITREXFactory.ClaimDetails memory) {
        return ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
    }

    function _assertUntouched(Token target, address oid, address manager) private view {
        _assertOwnedBy(_suite(target), address(accessManager));
        assertEq(beacon.owner(), address(accessManager));
        assertTrue(_isManager(oid, manager));
    }

    function _assertOwnedBy(IERC173[] memory suite, address owner) private view {
        for (uint256 i = 0; i < suite.length; i++) {
            assertEq(suite[i].owner(), owner);
        }
    }

    function _suite(Token target) private view returns (IERC173[] memory suite) {
        suite = new IERC173[](4);
        suite[0] = IERC173(address(target));
        suite[1] = IERC173(address(target.identityRegistry()));
        suite[2] = IERC173(address(target.identityRegistry().identityStorage()));
        suite[3] = IERC173(address(target.compliance()));
    }

    function _isManager(address oid, address account) private view returns (bool) {
        return IERC734(oid).keyHasPurpose(keccak256(abi.encodePacked(account)), KeyPurposes.MANAGEMENT);
    }

    function _addKeyCall(address account) private pure returns (bytes memory) {
        bytes memory signerData = abi.encodePacked(account);
        return abi.encodeCall(
            KeyManager.addKeyWithData,
            (keccak256(signerData), KeyPurposes.MANAGEMENT, KeyTypes.ECDSA, signerData, bytes(""))
        );
    }

}
