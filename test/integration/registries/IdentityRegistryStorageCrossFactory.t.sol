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

    function setUp() public override {
        super.setUp();
        suiteRegistry = TREXRegistry(address(token.identityRegistry()));
        irs = IdentityRegistryStorage(address(suiteRegistry.identityStorage()));
        vm.prank(agent);
        token.unpause();
        IdentityFactory otherFactory = _newIdentityFactory();
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
    }

    /// @notice A registry on another IdentityFactory holding the storage's writer role, never bound to it, cannot
    ///         bind a funded wallet to another identity: the storage checks the write against its bound
    ///         registry's factory, which links the wallet to its holder.
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

}
