// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { IdentityAggregateModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";

contract TokenRecoveryTest is TREXSuiteTest {

    TREXRegistry public identityRegistry;

    function setUp() public override {
        super.setUp();

        identityRegistry = TREXRegistry(address(token.identityRegistry()));

        vm.prank(agent);
        token.mint(bob, 500);

        vm.prank(agent);
        token.unpause();
    }

    // ============ recoveryAddress() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_recoveryAddress_RevertWhen_NotAgent() public {
        // Add key to bobIdentity for another address. addKey now derives the signer bytes from the
        // module, so a freshly-referenced address must be registered via the data-carrying entry point.
        bytes memory signerData = abi.encodePacked(another);
        vm.prank(bob);
        Identity(payable(address(bobIdentity))).addKeyWithData(keccak256(signerData), 1, 1, signerData, "");

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        token.recoveryAddress(bob, another, address(bobIdentity));
    }

    /// @notice Should revert when wallet to recover has no balance
    function test_recoveryAddress_RevertWhen_NoBalance() public {
        // Use agent to burn all bob's tokens
        uint256 bobBalance = token.balanceOf(bob);
        vm.prank(agent);
        token.burn(bob, bobBalance);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.NoTokenToRecover.selector);
        token.recoveryAddress(bob, another, address(bobIdentity));
    }

    /// @notice Should still recover when the lost wallet is no longer locally registered but is known
    /// globally through the IdFactory fallback — the global fallback makes the identity resolvable.
    function test_recoveryAddress_Success_WhenLostWalletOnlyGloballyRegistered() public {
        // Delete bob from the local identity registry. Bob still has a global identity.
        vm.prank(agent);
        identityRegistry.deleteIdentity(bob);

        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.RecoverySuccess(bob, another, address(bobIdentity));
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertTrue(identityRegistry.isLocallyRegistered(another));
        assertFalse(identityRegistry.isLocallyRegistered(bob));
    }

    /// @notice Should not register the new wallet locally when the global identity registry already binds it
    ///         to the investor: a local copy would outlive the global binding and stop following it.
    function test_recoveryAddress_Success_NewWalletOnlyGloballyRegistered_StaysGlobal() public {
        vm.mockCall(
            address(idFactory),
            abi.encodeWithSelector(
                idFactory.getIdentity.selector, InteroperableAddress.formatEvmV1(block.chainid, another)
            ),
            abi.encode(address(bobIdentity))
        );
        assertTrue(identityRegistry.contains(another));
        assertFalse(identityRegistry.isLocallyRegistered(another));

        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.RecoverySuccess(bob, another, address(bobIdentity));
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertFalse(identityRegistry.isLocallyRegistered(another));
        assertEq(address(identityRegistry.identity(another)), address(bobIdentity));
        assertFalse(identityRegistry.isLocallyRegistered(bob));
        assertEq(token.balanceOf(another), 500);
    }

    /// @notice Should recover and freeze tokens on the new wallet when wallet has frozen token
    function test_recoveryAddress_Success_WithFrozenTokens() public {
        // Add key to bobIdentity for another address. addKey now derives the signer bytes from the
        // module, so a freshly-referenced address must be registered via the data-carrying entry point.
        bytes memory signerData = abi.encodePacked(another);
        vm.prank(bob);
        Identity(payable(address(bobIdentity))).addKeyWithData(keccak256(signerData), 1, 1, signerData, "");

        // Freeze partial tokens on bob
        vm.prank(agent);
        token.freezePartialTokens(bob, 50);

        vm.prank(agent);
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertEq(token.getFrozenTokens(another), 50);
    }

    /// @notice Should revert when identity registry does not contain the lost or new wallet
    /// @notice Should update the identity registry correctly when recovery is successful
    function test_recoveryAddress_Success_WithIdentityTransfer() public {
        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.RecoverySuccess(bob, another, address(bobIdentity));
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertFalse(identityRegistry.isLocallyRegistered(bob));
        assertTrue(identityRegistry.isLocallyRegistered(another));
    }

    /// @notice The lost wallet's local binding shadowed a different global identity: deleting it during
    ///         recovery hands the wallet back to that global identity, which the agent must reconcile.
    function test_recoveryAddress_EmitsIdentityOverrideReleased_WhenLostWalletShadowedAGlobalIdentity() public {
        address identityStorage = address(identityRegistry.identityStorage());
        vm.mockCall(
            address(idFactory),
            abi.encodeWithSelector(
                idFactory.getIdentity.selector, InteroperableAddress.formatEvmV1(block.chainid, bob)
            ),
            abi.encode(address(charlieIdentity))
        );

        vm.expectEmit(identityStorage);
        emit EventsLib.IdentityOverrideReleased(bob, bobIdentity, charlieIdentity);
        vm.prank(agent);
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertFalse(identityRegistry.isLocallyRegistered(bob));
        assertEq(address(identityRegistry.identity(bob)), address(charlieIdentity));
        assertEq(token.balanceOf(another), 500);
    }

    /// @notice Should only remove the lost wallet from the registry when new wallet is already in it
    function test_recoveryAddress_Success_NewWalletAlreadyInRegistry() public {
        // Register another in identity registry
        vm.prank(agent);
        identityRegistry.registerIdentity(another, bobIdentity, 1);

        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.RecoverySuccess(bob, another, address(bobIdentity));
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertFalse(identityRegistry.isLocallyRegistered(bob));
        assertTrue(identityRegistry.isLocallyRegistered(another));
    }

    /// @notice Should revert when the new wallet is already registered with an identity that differs from
    ///         investorOnchainId, instead of silently keeping the new wallet's pre-existing identity
    function test_recoveryAddress_RevertWhen_NewWalletHasDifferentIdentity() public {
        // Register another (new wallet) with a different identity than bob (lost wallet)
        vm.prank(agent);
        identityRegistry.registerIdentity(another, charlieIdentity, 1);

        // Sanity: both wallets registered, with distinct identities, before recovery
        assertTrue(identityRegistry.contains(bob));
        assertTrue(identityRegistry.contains(another));
        assertEq(address(identityRegistry.identity(bob)), address(bobIdentity));
        assertEq(address(identityRegistry.identity(another)), address(charlieIdentity));

        // Recovery must reject: another's on-chain identity (charlieIdentity) does not match investorOnchainId
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.RecoveryNotPossible.selector);
        token.recoveryAddress(bob, another, address(bobIdentity));
    }

    /// @notice Should recover without touching IRS when recovery already happened on another token
    function test_recoveryAddress_Success_RecoveryAlreadyHappened() public {
        // Delete bob and register another (simulating recovery on another token)
        vm.prank(agent);
        identityRegistry.deleteIdentity(bob);
        vm.prank(agent);
        identityRegistry.registerIdentity(another, bobIdentity, 1);

        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.RecoverySuccess(bob, another, address(bobIdentity));
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertFalse(identityRegistry.isLocallyRegistered(bob));
        assertTrue(identityRegistry.isLocallyRegistered(another));
    }

    /// @notice Should transfer the frozen status and transfer frozen tokens when old wallet is frozen and new is not
    function test_recoveryAddress_Success_OldFrozenNewNotFrozen() public {
        // Freeze bob address and partial tokens
        vm.prank(agent);
        token.setAddressFrozen(bob, true);
        vm.prank(agent);
        token.freezePartialTokens(bob, 50);

        vm.prank(agent);
        vm.expectEmit(true, false, false, false, address(token));
        emit IERC3643.TokensFrozen(another, 50);
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertTrue(token.isFrozen(another));
        assertEq(token.getFrozenTokens(another), 50);
    }

    /// @notice Should transfer frozen tokens and keep freeze status when both wallets are frozen
    function test_recoveryAddress_Success_BothFrozen() public {
        // Freeze both addresses and partial tokens on bob
        vm.prank(agent);
        token.setAddressFrozen(bob, true);
        vm.prank(agent);
        token.setAddressFrozen(another, true);
        vm.prank(agent);
        token.freezePartialTokens(bob, 30);

        vm.prank(agent);
        vm.expectEmit(true, false, false, false, address(token));
        emit IERC3643.TokensFrozen(another, 30);
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertTrue(token.isFrozen(another));
        assertEq(token.getFrozenTokens(another), 30);
    }

    /// @notice Should recover tokens without freezing any when there are no frozen tokens
    function test_recoveryAddress_Success_NoFrozenTokens() public {
        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.RecoverySuccess(bob, another, address(bobIdentity));
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertEq(token.getFrozenTokens(another), 0);
    }

    /// @notice Should not emit AddressFrozen when new wallet is already frozen
    function test_recoveryAddress_Success_NewWalletAlreadyFrozen() public {
        // Freeze old wallet and new wallet
        vm.prank(agent);
        token.setAddressFrozen(bob, true);
        vm.prank(agent);
        token.setAddressFrozen(another, true);

        // Recovery should not emit AddressFrozen for new wallet since it's already frozen
        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.AddressFrozen(bob, false, address(token));
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.RecoverySuccess(bob, another, address(bobIdentity));
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertTrue(token.isFrozen(another));
    }

    /// @notice Should recover when only new wallet is in registry (not lost wallet)
    function test_recoveryAddress_Success_OnlyNewWalletInRegistry() public {
        // Delete bob from identity registry but keep another registered
        vm.prank(agent);
        identityRegistry.deleteIdentity(bob);

        // Register another in identity registry
        vm.prank(agent);
        identityRegistry.registerIdentity(another, bobIdentity, 1);

        // Recovery should work because new wallet is in registry
        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit IERC3643.RecoverySuccess(bob, another, address(bobIdentity));
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertEq(token.balanceOf(another), 500);
        assertTrue(identityRegistry.isLocallyRegistered(another));
    }

    // ============ Identity-keyed compliance (issue #70) ============

    /// @notice A module keyed by identity sees both wallets resolve during the compliance hook: the new
    ///         wallet is registered before the move and the lost wallet deleted after the hook. Before the
    ///         fix the lost wallet was deleted first, so the module debited the zero identity.
    function test_recoveryAddress_Success_IdentityKeyedModuleKeepsAggregate() public {
        IdentityAggregateModule module = _bindIdentityAggregateModule();
        module.seed(address(bobIdentity), 500);
        _unbindGlobally(bob);

        vm.prank(agent);
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertEq(module.transferHookCalls(), 1, "hook not reached");
        assertEq(module.aggregate(address(bobIdentity)), 500, "aggregate corrupted by the recovery");
        assertFalse(identityRegistry.isLocallyRegistered(bob));
        assertEq(address(identityRegistry.identity(another)), address(bobIdentity));
    }

    /// @notice The debit and the credit land on different identities when the new wallet is already bound
    ///         to one: the lost identity is emptied and the new identity carries the balance.
    function test_recoveryAddress_Success_IdentityKeyedModuleMovesAcrossIdentities() public {
        IdentityAggregateModule module = _bindIdentityAggregateModule();
        module.seed(address(bobIdentity), 500);
        _unbindGlobally(bob);
        vm.prank(agent);
        identityRegistry.registerIdentity(another, aliceIdentity, 1);

        vm.prank(agent);
        token.recoveryAddress(bob, another, address(aliceIdentity));

        assertEq(module.aggregate(address(bobIdentity)), 0, "lost identity not debited");
        assertEq(module.aggregate(address(aliceIdentity)), 500, "new identity not credited");
    }

    /// @notice The lost wallet's local binding shadows a global one. The hook must debit the local identity
    ///         that held the tokens, not the global one the wallet falls back to once the local entry is gone.
    function test_recoveryAddress_Success_IdentityKeyedModuleDebitsLocalIdentityNotGlobalShadow() public {
        IdentityAggregateModule module = _bindIdentityAggregateModule();
        module.seed(address(bobIdentity), 500);
        vm.mockCall(
            address(idFactory),
            abi.encodeWithSelector(
                idFactory.getIdentity.selector, InteroperableAddress.formatEvmV1(block.chainid, bob)
            ),
            abi.encode(address(charlieIdentity))
        );

        vm.prank(agent);
        token.recoveryAddress(bob, another, address(bobIdentity));

        assertEq(module.aggregate(address(bobIdentity)), 500, "aggregate corrupted");
        assertEq(module.aggregate(address(charlieIdentity)), 0, "global shadow leaked into hook");
    }

    /// @dev Makes the ONCHAINID factory answer "unknown" for `wallet`, so only its local binding speaks for
    ///  it. Without this the global fallback keeps resolving the wallet after `deleteIdentity` and would hide
    ///  the pre-fix corruption.
    function _unbindGlobally(address wallet) private {
        vm.mockCall(
            address(idFactory),
            abi.encodeWithSelector(
                idFactory.getIdentity.selector, InteroperableAddress.formatEvmV1(block.chainid, wallet)
            ),
            abi.encode(address(0))
        );
    }

    function _bindIdentityAggregateModule() private returns (IdentityAggregateModule module) {
        module = IdentityAggregateModule(
            address(
                new ModuleProxy(address(new IdentityAggregateModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.prank(deployer);
        ModularCompliance(address(token.compliance())).addModule(address(module));
    }

}
