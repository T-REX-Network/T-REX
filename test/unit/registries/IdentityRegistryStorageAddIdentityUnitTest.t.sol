// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test, Vm } from "@forge-std/Test.sol";
import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";

import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

/// @dev The registry and the identity factory are mocked at the ABI level: on registration the storage only
///      asks each bound registry for its factory and that factory for the wallet's identity, to tell whether
///      the local binding shadows a global one.
contract IdentityRegistryStorageAddIdentityUnitTest is Test {

    IdentityRegistryStorage private irs;
    AccessManager private accessManager;

    address private registry = makeAddr("registry");
    address private idFactory = makeAddr("idFactory");
    address private wallet = makeAddr("wallet");
    address private globalIdentity = makeAddr("globalIdentity");
    address private localIdentity = makeAddr("localIdentity");

    address private otherRegistry = makeAddr("otherRegistry");
    address private otherIdFactory = makeAddr("otherIdFactory");
    address private otherWallet = makeAddr("otherWallet");
    address private otherIdentity = makeAddr("otherIdentity");

    function setUp() public {
        accessManager = new AccessManager(address(this));
        accessManager.grantRole(RolesLib.IRS_BINDER, address(this), 0);
        accessManager.grantRole(RolesLib.AGENT, address(this), 0);

        address beacon = BeaconProxyDeployer.newBeacon(address(new IdentityRegistryStorage()));
        irs = IdentityRegistryStorage(
            BeaconProxyDeployer.newProxy(
                beacon, abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0)))
            )
        );
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(irs));

        vm.mockCall(
            registry, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.mockCall(registry, abi.encodeWithSelector(ITREXRegistry.identityFactory.selector), abi.encode(idFactory));
        vm.mockCall(
            idFactory, abi.encodeCall(IIdentityFactory.getIdentity, (_account(wallet))), abi.encode(globalIdentity)
        );
        vm.mockCall(
            idFactory, abi.encodeCall(IIdentityFactory.getIdentity, (_account(otherWallet))), abi.encode(address(0))
        );

        // A second registry built on another factory: it knows `otherWallet`, the first one does not.
        vm.mockCall(
            otherRegistry, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.mockCall(
            otherRegistry, abi.encodeWithSelector(ITREXRegistry.identityFactory.selector), abi.encode(otherIdFactory)
        );
        vm.mockCall(
            otherIdFactory, abi.encodeCall(IIdentityFactory.getIdentity, (_account(wallet))), abi.encode(address(0))
        );
        vm.mockCall(
            otherIdFactory,
            abi.encodeCall(IIdentityFactory.getIdentity, (_account(otherWallet))),
            abi.encode(otherIdentity)
        );
    }

    function test_addIdentityToStorage_EmitsIdentityOverridden_WhenGlobalIdentityDiffers() public {
        irs.bindIdentityRegistry(registry);

        vm.expectEmit(address(irs));
        emit ERC3643EventsLib.IdentityStored(wallet, IIdentity(localIdentity));
        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverridden(wallet, IIdentity(globalIdentity), IIdentity(localIdentity));
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        assertEq(address(irs.storedIdentity(wallet)), localIdentity);
        assertTrue(irs.isLocallyStored(wallet));
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenNoRegistryBound() public {
        vm.recordLogs();
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenGlobalRegistryDoesNotKnowTheWallet() public {
        irs.bindIdentityRegistry(registry);

        vm.recordLogs();
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenGlobalIdentityMatches() public {
        irs.bindIdentityRegistry(registry);

        vm.recordLogs();
        irs.addIdentityToStorage(wallet, IIdentity(globalIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
    }

    function test_addIdentityToStorage_EmitsIdentityOverridden_FromSecondBoundRegistry() public {
        irs.bindIdentityRegistry(registry);
        irs.bindIdentityRegistry(otherRegistry);

        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverridden(otherWallet, IIdentity(otherIdentity), IIdentity(localIdentity));
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);
    }

    function _assertOnlyIdentityStored(Vm.Log[] memory logs) private pure {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], ERC3643EventsLib.IdentityStored.selector);
    }

    function _account(address _wallet) private view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(block.chainid, _wallet);
    }

}
