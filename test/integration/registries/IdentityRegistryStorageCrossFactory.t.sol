// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract IdentityRegistryStorageCrossFactoryTest is TREXSuiteTest {

    TREXRegistry internal suiteRegistry;
    TREXRegistry internal otherRegistry;
    IdentityRegistryStorage internal irs;
    IdentityFactory internal otherFactory;

    function setUp() public override {
        super.setUp();
        suiteRegistry = TREXRegistry(address(token.identityRegistry()));
        irs = IdentityRegistryStorage(address(suiteRegistry.identityStorage()));
        vm.prank(agent);
        token.unpause();
        otherFactory = _newIdentityFactory();
        otherRegistry = TREXRegistry(
            address(
                new ERC1967Proxy(
                    address(new TREXRegistry(address(otherFactory))),
                    abi.encodeCall(
                        TREXRegistry.init,
                        (address(irs), address(accessManager), new uint256[](0), new address[](0), new uint256[][](0))
                    )
                )
            )
        );
        AccessManagerSetupLib.setupTREXRegistryRoles(accessManager, address(otherRegistry), DOMAIN);
        _grantStorageWriterRole(address(otherRegistry));
        _grantIRSBinderRole(address(this));
    }

    /// @notice A registry on another IdentityFactory holding the storage's writer role, never bound to it, cannot
    ///         bind a funded wallet to another identity: the storage checks the write against its own factory,
    ///         which links the wallet to its holder.
    function test_registerIdentity_RevertWhen_ARegistryOnAnotherFactoryBindsAFundedWallet() public {
        address registryAgent = makeAddr("registryAgent");
        _grantAgentRole(registryAgent);
        IIdentity agentIdentity = _deployIdentity(registryAgent, "registryAgent");
        address victim = makeAddr("victim");
        IIdentity victimIdentity = _deployIdentity(victim, "victim");
        vm.prank(agent);
        token.mint(victim, 1000);

        vm.prank(registryAgent);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, victim, address(victimIdentity))
        );
        otherRegistry.registerIdentity(victim, agentIdentity, 0);

        assertEq(address(suiteRegistry.identity(victim)), address(victimIdentity));
        assertEq(token.balanceOf(victim), 1000);
    }

    /// @notice Unbinding every registry does not lift the check: the storage keeps the factory it was created with,
    ///         so a writer on another factory still cannot bind a funded wallet to another identity.
    function test_registerIdentity_RevertWhen_EveryRegistryIsUnbound_AndARegistryOnAnotherFactoryBindsAFundedWallet()
        public
    {
        address registryAgent = makeAddr("registryAgent");
        _grantAgentRole(registryAgent);
        IIdentity agentIdentity = _deployIdentity(registryAgent, "registryAgent");
        address victim = makeAddr("victim");
        IIdentity victimIdentity = _deployIdentity(victim, "victim");
        vm.prank(agent);
        token.mint(victim, 1000);
        irs.unbindIdentityRegistry(address(suiteRegistry));

        vm.prank(registryAgent);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, victim, address(victimIdentity))
        );
        otherRegistry.registerIdentity(victim, agentIdentity, 0);

        assertEq(address(suiteRegistry.identity(victim)), address(victimIdentity));
        assertEq(token.balanceOf(victim), 1000);
    }

    /// @notice A storage with no registry bound still refuses a registry on another factory, so unbinding
    ///         everything cannot switch the storage to a factory that does not know its funded wallets.
    function test_bindIdentityRegistry_RevertWhen_EveryRegistryIsUnbound_AndTheNewRegistryIsOnAnotherFactory() public {
        irs.unbindIdentityRegistry(address(suiteRegistry));

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.IdentityFactoryMismatch.selector, address(idFactory), address(otherFactory)
            )
        );
        irs.bindIdentityRegistry(address(otherRegistry));
    }

    /// @notice A storage binds its first registry at init without asking its factory, so the registry checks each
    ///         registration against its own IdentityFactory too: a registry agent cannot bind a wallet that this
    ///         factory links to another identity, even when the storage is pinned to a factory that does not know it.
    function test_registerIdentity_RevertWhen_TheStorageIsPinnedToAnotherFactory_AndTheWalletIsLinkedElsewhere()
        public
    {
        TREXRegistry registryOnSuiteFactory = _deployRegistryOnAStoragePinnedTo(otherFactory);
        address registryAgent = makeAddr("registryAgent");
        _grantAgentRole(registryAgent);
        IIdentity agentIdentity = _deployIdentity(registryAgent, "registryAgent");
        address victim = makeAddr("victim");
        IIdentity victimIdentity = _deployIdentity(victim, "victim");

        vm.prank(registryAgent);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, victim, address(victimIdentity))
        );
        registryOnSuiteFactory.registerIdentity(victim, agentIdentity, 0);

        assertEq(address(registryOnSuiteFactory.identity(victim)), address(victimIdentity));
    }

    /// @dev A registry on the suite's IdentityFactory, bound at init to a fresh storage pinned to `pinnedFactory`.
    function _deployRegistryOnAStoragePinnedTo(IdentityFactory pinnedFactory) private returns (TREXRegistry) {
        address registryImplementation = address(new TREXRegistry(address(idFactory)));
        IdentityRegistryStorage storageImplementation = new IdentityRegistryStorage();
        address predictedRegistry = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        IdentityRegistryStorage pinnedStorage = IdentityRegistryStorage(
            address(
                new ERC1967Proxy(
                    address(storageImplementation),
                    abi.encodeCall(
                        IdentityRegistryStorage.init,
                        (address(accessManager), predictedRegistry, address(pinnedFactory))
                    )
                )
            )
        );
        TREXRegistry registry = TREXRegistry(
            address(
                new ERC1967Proxy(
                    registryImplementation,
                    abi.encodeCall(
                        TREXRegistry.init,
                        (
                            address(pinnedStorage),
                            address(accessManager),
                            new uint256[](0),
                            new address[](0),
                            new uint256[][](0)
                        )
                    )
                )
            )
        );
        assertEq(address(registry), predictedRegistry, "the storage bound the registry it was told about");
        AccessManagerSetupLib.setupTREXRegistryRoles(accessManager, address(registry), DOMAIN);
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(pinnedStorage), DOMAIN);
        _grantStorageWriterRole(address(registry));
        return registry;
    }

}
