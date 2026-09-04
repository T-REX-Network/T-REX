// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";

import { Countries } from "test/integration/helpers/Countries.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import {
    MockAttributeSyncModule,
    MockRevertingSyncModule,
    RecordingModule
} from "test/integration/mocks/CapabilityModules.sol";

/// @notice The reconciliation loop of issue #18: the registry cache is the operative country, the
///         claim is the source, and `reconcile` is the only thing that moves one onto the other.
contract TokenReconcileTest is TREXSuiteTest {

    TREXRegistry internal registry;
    ModularCompliance internal mc;
    MockAttributeSyncModule internal syncModule;

    uint256 internal topic;

    function setUp() public override {
        super.setUp();

        token = _deployTokenWithClaimTopic("reconcile", "Reconcile Token", "RCT");
        registry = TREXRegistry(address(token.identityRegistry()));
        mc = ModularCompliance(address(token.compliance()));
        topic = registry.COUNTRY_CLAIM_TOPIC();

        _registerIdentities(token);

        bytes memory claimData = "Some claim public data.";
        _addClaim(aliceIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), alice);
        _addClaim(bobIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), bob);

        syncModule = MockAttributeSyncModule(
            address(
                new ModuleProxy(address(new MockAttributeSyncModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.prank(deployer);
        mc.addModule(address(syncModule));

        // Minting reconciles bob, so his cache is already filled here. alice holds nothing and is
        // therefore the untouched wallet the first-sync cases use.
        vm.startPrank(agent);
        token.mint(bob, 500);
        token.unpause();
        vm.stopPrank();
    }

    // ============ First reconcile ============

    /// @notice The cache is born empty and filled by the first sync, never by a caller's assertion.
    /// @dev alice holds nothing, so no balance move has reconciled her yet.
    function test_reconcile_Success_FillsAnEmptyCacheFromTheClaim() public {
        assertEq(registry.investorCountry(alice), 0);
        assertEq(registry.attestedCountry(alice), Countries.FRANCE);

        uint256 before = syncModule.attributeSyncCalls();
        token.reconcile(alice);

        assertEq(registry.investorCountry(alice), Countries.FRANCE);
        assertEq(syncModule.attributeSyncCalls(), before + 1);
    }

    /// @notice The module is handed the old value, the new value and the investor's whole position.
    function test_reconcile_Success_HandsTheModuleThePosition() public {
        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);

        token.reconcile(bob);

        assertEq(syncModule.lastInvestor(), bob);
        assertEq(syncModule.lastTopic(), topic);
        assertEq(syncModule.lastOldValue(), Countries.UNITED_STATES);
        assertEq(syncModule.lastNewValue(), Countries.SPAIN);
        assertEq(syncModule.lastPosition(), token.balanceOf(bob));
    }

    /// @notice The event carries the claim-derived value.
    function test_reconcile_Success_EmitsTheAttestedValue() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit ERC3643EventsLib.CountryUpdated(alice, Countries.FRANCE);

        token.reconcile(alice);
    }

    /// @notice Anyone may reconcile: every value is derived on-chain, so a caller can only make the
    ///         state correct at their own expense.
    function test_reconcile_Success_WhenCallerHoldsNoRole() public {
        vm.prank(another);
        token.reconcile(alice);

        assertEq(registry.investorCountry(alice), Countries.FRANCE);
    }

    // ============ Idempotence ============

    /// @notice A second call with nothing pending writes nothing and calls no module.
    function test_reconcile_Success_IsANoOpWhenNothingIsPending() public {
        token.reconcile(alice);
        uint256 afterFirst = syncModule.attributeSyncCalls();

        token.reconcile(alice);
        assertEq(syncModule.attributeSyncCalls(), afterFirst);
    }

    /// @notice A wallet with no identity is simply skipped.
    function test_reconcile_Success_WhenWalletHasNoIdentity() public {
        uint256 before = syncModule.attributeSyncCalls();
        token.reconcile(another);

        assertEq(syncModule.attributeSyncCalls(), before);
    }

    // ============ A moved claim ============

    /// @notice Reissuing the residence claim moves the cache and the module aggregates on the next sync.
    function test_reconcile_Success_MovesTheCacheWhenTheClaimMoves() public {
        token.reconcile(bob);

        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);
        assertEq(registry.attestedCountry(bob), Countries.SPAIN);
        assertEq(registry.investorCountry(bob), Countries.UNITED_STATES);

        token.reconcile(bob);

        assertEq(registry.investorCountry(bob), Countries.SPAIN);
        assertEq(syncModule.lastOldValue(), Countries.UNITED_STATES);
        assertEq(syncModule.lastNewValue(), Countries.SPAIN);
    }

    /// @notice Until the sync runs, the getter and the claim disagree. That divergence is the signal
    ///         that a reconcile is pending, not a defect.
    function test_reconcile_Success_DivergenceIsObservable() public {
        token.reconcile(bob);
        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);

        assertEq(registry.investorCountry(bob), Countries.UNITED_STATES);
        assertEq(registry.attestedCountry(bob), Countries.SPAIN);
    }

    /// @notice Every wallet linked to one identity reads the same country: the cache is keyed by
    ///         identity, so adding a wallet cannot give the investor a second jurisdiction.
    function test_reconcile_Success_WalletsOfOneIdentityShareTheCountry() public {
        token.reconcile(bob);

        vm.prank(agent);
        registry.registerIdentity(david, bobIdentity, 0);

        assertEq(registry.investorCountry(david), registry.investorCountry(bob));
    }

    // ============ A revoked claim ============

    /// @notice A claim that stops resolving leaves the investor counted where they are and flags the
    ///         identity: the aggregates must keep summing to the distribution.
    function test_reconcile_Success_KeepsTheLastKnownCountryWhenTheClaimIsGone() public {
        token.reconcile(bob);
        _removeCountryClaim(bobIdentity, bob);

        assertEq(registry.attestedCountry(bob), 0);

        token.reconcile(bob);

        assertEq(registry.investorCountry(bob), Countries.UNITED_STATES);
        assertTrue(registry.isAttributeFlagged(address(bobIdentity), topic));
        assertEq(syncModule.attributeSyncCalls(), 1);
    }

    /// @notice Restoring the claim clears the flag.
    function test_reconcile_Success_ClearsTheFlagWhenTheClaimReturns() public {
        token.reconcile(bob);
        _removeCountryClaim(bobIdentity, bob);
        token.reconcile(bob);
        assertTrue(registry.isAttributeFlagged(address(bobIdentity), topic));

        // A removed claim's EIP-712 digest stays revoked, so the replacement has to be a distinct
        // claim. Moving time changes `issuedAt` and with it the digest.
        vm.warp(block.timestamp + 1 days);
        _addCountryClaim(bobIdentity, Countries.UNITED_STATES, bob);
        token.reconcile(bob);

        assertFalse(registry.isAttributeFlagged(address(bobIdentity), topic));
        assertEq(registry.investorCountry(bob), Countries.UNITED_STATES);
    }

    /// @notice A wallet that never had a country is not flagged: there is nothing counted to protect.
    function test_reconcile_Success_DoesNotFlagAWalletThatNeverHadACountry() public {
        IIdentity davidIdentity = _deployIdentity(david, "david");
        vm.prank(agent);
        registry.registerIdentity(david, davidIdentity, 0);

        token.reconcile(david);

        assertFalse(registry.isAttributeFlagged(address(davidIdentity), topic));
    }

    // ============ updateCountry as the agent-gated entry point ============

    /// @notice The agent's country argument is dropped; the claim decides.
    function test_updateCountry_Success_ReconcilesAndIgnoresTheArgument() public {
        vm.prank(agent);
        registry.updateCountry(bob, Countries.SPAIN);

        assertEq(registry.investorCountry(bob), Countries.UNITED_STATES);
        assertEq(syncModule.attributeSyncCalls(), 1);
    }

    // ============ The cache writer ============

    /// @notice Only the bound token moves the cache: reconciling through the registry alone would
    ///         leave the compliance aggregates behind.
    function test_reconcileAttribute_RevertWhen_CallerIsNotTheBoundToken() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToRegistry.selector);
        registry.reconcileAttribute(bob);
    }

    /// @notice The registry reports the token it serves.
    function test_bindToken_Success_WhenDeployedByTheFactory() public view {
        assertEq(registry.tokenBound(), address(token));
    }

    /// @notice A registry already serving a token rejects a second one.
    function test_bindToken_RevertWhen_AlreadyServingAnotherToken() public {
        Token otherToken = _deployTokenWithClaimTopic("reconcile-2", "Other Token", "OTH");

        vm.prank(address(otherToken));
        vm.expectRevert(ErrorsLib.OnlyOwnerOrTokenCanCall.selector);
        registry.bindToken(address(otherToken));
    }

    /// @notice The owner can bind a registry directly, which is how a registry is re-pointed without
    ///         the token driving it.
    function test_bindToken_Success_WhenCallerIsOwner() public {
        vm.prank(deployer);
        registry.bindToken(address(token));

        assertEq(registry.tokenBound(), address(token));
    }

    /// @notice Binding the zero address would leave the cache with no writer at all.
    function test_bindToken_RevertWhen_TokenIsZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        registry.bindToken(address(0));
    }

    /// @notice The cache write is evented, so an indexer follows the operative value without replaying
    ///         the claims.
    function test_reconcile_Success_EmitsTheCacheSync() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit EventsLib.AttributeCacheSynced(address(aliceIdentity), topic, 0, Countries.FRANCE, false);

        token.reconcile(alice);
    }

    // ============ Automatic triggers ============

    /// @notice A transfer reconciles both parties, so a claim that moved between transfers is picked up
    ///         the moment a position actually moves.
    function test_transfer_Success_ReconcilesBothParties() public {
        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);
        assertEq(registry.investorCountry(bob), Countries.UNITED_STATES);
        assertEq(registry.investorCountry(alice), 0);

        vm.prank(bob);
        token.transfer(alice, 100);

        assertEq(registry.investorCountry(bob), Countries.SPAIN);
        assertEq(registry.investorCountry(alice), Countries.FRANCE);
    }

    /// @notice A mint reconciles the receiver.
    function test_mint_Success_ReconcilesTheReceiver() public {
        assertEq(registry.investorCountry(alice), 0);

        vm.prank(agent);
        token.mint(alice, 100);

        assertEq(registry.investorCountry(alice), Countries.FRANCE);
    }

    /// @notice A burn reconciles the holder.
    function test_burn_Success_ReconcilesTheHolder() public {
        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);

        vm.prank(agent);
        token.burn(bob, 100);

        assertEq(registry.investorCountry(bob), Countries.SPAIN);
    }

    /// @notice A forced transfer reconciles too, even though it bypasses the standard update path.
    function test_forcedTransfer_Success_ReconcilesBothParties() public {
        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);

        vm.prank(agent);
        token.forcedTransfer(bob, alice, 100);

        assertEq(registry.investorCountry(bob), Countries.SPAIN);
        assertEq(registry.investorCountry(alice), Countries.FRANCE);
    }

    /// @notice Recovery reconciles the new wallet, after the identity migration has pointed it at the
    ///         recovered identity.
    function test_recoveryAddress_Success_ReconcilesTheNewWallet() public {
        vm.prank(agent);
        token.recoveryAddress(bob, david, address(bobIdentity));

        assertEq(registry.investorCountry(david), Countries.UNITED_STATES);
    }

    /// @notice The module sees the position under the country the claim attests now, not the stale one.
    function test_transfer_Success_ModuleSeesTheReconciledCountry() public {
        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);

        vm.prank(bob);
        token.transfer(alice, 100);

        assertEq(syncModule.lastNewValue(), Countries.FRANCE);
        assertEq(syncModule.lastInvestor(), alice);
    }

    /// @notice The module is handed the position its aggregates were built on, before the transfer
    ///         moves it. Handing the post-move balance would leave the difference stranded under the
    ///         old country.
    function test_transfer_Success_HandsTheModuleThePreMovePosition() public {
        token.reconcile(alice);
        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);

        vm.prank(bob);
        token.transfer(alice, 100);

        assertEq(syncModule.lastInvestor(), bob);
        assertEq(syncModule.lastOldValue(), Countries.UNITED_STATES);
        assertEq(syncModule.lastNewValue(), Countries.SPAIN);
        assertEq(syncModule.lastPosition(), 500);
        assertEq(token.balanceOf(bob), 400);
    }

    /// @notice A first mint reconciles on an empty position: the mint hook, not the sync, adds the
    ///         minted amount to the aggregates.
    function test_mint_Success_HandsTheModuleThePositionBeforeTheMint() public {
        vm.prank(agent);
        token.mint(alice, 100);

        assertEq(syncModule.lastInvestor(), alice);
        assertEq(syncModule.lastPosition(), 0);
        assertEq(token.balanceOf(alice), 100);
    }

    /// @notice A module reverting inside the sync cannot stop a transfer settling. The auto-trigger
    ///         makes every balance move depend on the sync, so containment is what keeps tokens moving.
    function test_transfer_Success_WhenASyncModuleReverts() public {
        MockRevertingSyncModule reverting = MockRevertingSyncModule(
            address(
                new ModuleProxy(address(new MockRevertingSyncModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.prank(deployer);
        mc.addModule(address(reverting));

        _addCountryClaim(bobIdentity, Countries.SPAIN, bob);

        vm.prank(bob);
        token.transfer(alice, 100);

        assertEq(token.balanceOf(alice), 100);
        assertEq(registry.investorCountry(bob), Countries.SPAIN);
    }

    /// @notice Nothing pending means no sync call on the transfer path either.
    function test_transfer_Success_WhenNothingIsPending() public {
        vm.prank(bob);
        token.transfer(alice, 100);
        uint256 afterFirst = syncModule.attributeSyncCalls();

        vm.prank(bob);
        token.transfer(alice, 100);

        assertEq(syncModule.attributeSyncCalls(), afterFirst);
    }

    /// @dev Drops the residence claim the suite issuer signed for `_identity`.
    function _removeCountryClaim(IIdentity _identity, address _wallet) private {
        vm.prank(_wallet);
        _identity.removeClaim(keccak256(abi.encode(address(claimIssuer), COUNTRY_CLAIM_TOPIC)));
    }

}
