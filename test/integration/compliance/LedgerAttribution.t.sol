// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { LockedSenderModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";

/// @dev Who the ledger says owns a wallet, and what keeps that answer stable.
///
///      The ledger debits and credits the identity the registry names at hook time. Two things can move that
///      answer out from under it, and they are not the same kind of event:
///
///      - the investor revoking their own wallet, which must not change attribution at all. A revoked wallet
///        keeps its owner so a burn, a recovery or a forced transfer still lands on the right position; it
///        simply may not act any more. That separation is what this suite pins.
///      - a registry agent deleting or relinking a local entry, which genuinely does change the answer. That
///        one is a documented precondition of the ledger, not something the code prevents.
///
///      The wallets here are deliberately not locally registered: a local binding is a plain mapping that
///      knows nothing of revocation, so it would mask the lookup this suite is about.
contract LedgerAttributionTest is TREXSuiteTest {

    uint256 internal constant BALANCE = 1000;

    TREXRegistry internal registry;
    ModularCompliance internal compliance;

    function setUp() public override {
        super.setUp();

        registry = TREXRegistry(address(token.identityRegistry()));
        compliance = ModularCompliance(address(token.compliance()));

        vm.startPrank(agent);
        token.mint(alice, BALANCE);
        token.mint(bob, BALANCE);
        token.unpause();
        vm.stopPrank();

        // Drop the local entries so both wallets resolve through the global fallback, which is the lookup
        // that has to keep attributing a revoked wallet.
        vm.startPrank(agent);
        registry.deleteIdentity(alice);
        registry.deleteIdentity(bob);
        vm.stopPrank();
    }

    /* ----- A revoked wallet keeps its owner ----- */

    /// @notice The two reads part company on a revoked wallet: it still attributes to its identity, so the
    ///         ledger knows whose tokens these are, and it is no longer eligible, so it may not act.
    function test_revoke_Success_KeepsAttribution_AndDropsAdmission() public {
        _revokeAlice();

        assertEq(address(registry.identity(alice)), address(aliceIdentity), "attribution survives the revocation");
        assertFalse(registry.isVerified(alice), "admission does not");
    }

    /// @notice Burning a revoked wallet's tokens debits the identity that held them, so the position follows
    ///         the supply down instead of stranding an amount nobody can shed.
    function test_burn_Success_DebitsTheIdentity_WhenTheWalletWasRevoked() public {
        _revokeAlice();

        assertEq(_positionOf(aliceIdentity), BALANCE, "position before the burn");

        vm.prank(agent);
        token.burn(alice, BALANCE);

        assertEq(_positionOf(aliceIdentity), 0, "the burn debited the identity");
        assertEq(_positionsSum(), token.totalSupply(), "positions still recount to the supply");
    }

    /// @notice Recovering a revoked wallet moves the position with the tokens. Revoking the lost wallet is the
    ///         natural first move after losing a key, so recovery has to survive it: this is #70 through that
    ///         door.
    function test_recoveryAddress_Success_MovesThePosition_WhenTheLostWalletWasRevoked() public {
        _revokeAlice();

        vm.prank(agent);
        token.recoveryAddress(alice, another, address(aliceIdentity));

        assertEq(token.balanceOf(another), BALANCE, "the tokens moved");
        assertEq(_positionOf(aliceIdentity), BALANCE, "the identity keeps exactly what it held");
        assertEq(_positionsSum(), token.totalSupply(), "positions still recount to the supply");
    }

    /// @notice A rule keyed on the sender is still asked about the same identity after a revocation, so a
    ///         lockup cannot be stepped around by revoking the locked wallet. Sender-side rules are the class
    ///         that inherits this: lockups, holding floors, outflow limits.
    ///
    ///         The rule is asked, rather than the transfer merely being refused: with attribution lost, the
    ///         compliance's own guard would refuse this too, and a test that only checked the revert would
    ///         pass either way. What is asserted here is that the module saw the sender.
    function test_transfer_RevertWhen_TheSenderIsLockedAndTheWalletWasRevoked() public {
        LockedSenderModule lockup = _bindLockup(address(aliceIdentity));

        // Locked before the revocation.
        vm.prank(alice);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 1);

        _revokeAlice();

        // Still locked after it, and locked by the rule: the module answers zero for this very identity.
        assertEq(lockup.allowedAmount(_contextFrom(aliceIdentity)), 0, "the rule still refuses the sender");

        vm.prank(alice);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 1);
    }

    /// @notice Without stable attribution the same lockup answers "no limit", because the sender reaches it as
    ///         a zero identity, which the context defines as a mint. This is the bypass the two guards close
    ///         from opposite ends: the rule keeps seeing the identity, and the compliance refuses a sender it
    ///         cannot attribute at all.
    function test_allowedAmount_NoLimit_WhenTheSenderCannotBeAttributed() public {
        LockedSenderModule lockup = _bindLockup(address(aliceIdentity));

        assertEq(
            lockup.allowedAmount(_contextFrom(IIdentity(address(0)))), type(uint256).max, "a zero sender is a mint"
        );
    }

    /// @notice A sender the registry cannot attribute is refused outright while a rule is bound, as an
    ///         unattributable recipient already was.
    function test_transfer_RevertWhen_TheSenderCannotBeAttributed() public {
        _bindLockup(address(bobIdentity));

        // Alice keeps no binding anywhere: neither local, nor global.
        vm.mockCall(
            address(idFactory),
            abi.encodeCall(
                idFactory.getIdentityIncludingRevoked, (InteroperableAddress.formatEvmV1(block.chainid, alice))
            ),
            abi.encode(address(0), IIdentityFactory.AccountStatus.None)
        );
        assertEq(address(registry.identity(alice)), address(0), "alice attributes to nobody");

        vm.prank(alice);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 1);
    }

    /* ----- A circulating token keeps its wiring ----- */

    /// @notice The ledger has no seeding step, so a token that already has holders keeps the compliance that
    ///         counted them. The same door is shut from the compliance side and for the registry.
    function test_setCompliance_RevertWhen_TheTokenIsCirculating() public {
        ModularCompliance fresh = _newUnboundComplianceProxy(address(trexImplementationAuthority));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TokenCirculating.selector);
        token.setCompliance(address(fresh));
    }

    /// @notice `bindToken` called on the compliance directly is refused for the same reason, so the guard
    ///         cannot be walked around by skipping the token.
    function test_bindToken_RevertWhen_TheTokenIsCirculating() public {
        ModularCompliance fresh = _newUnboundComplianceProxy(address(trexImplementationAuthority));

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TokenCirculating.selector);
        fresh.bindToken(address(token));
    }

    /// @notice A registry swap would attribute wallets to identities that hold no position, so it is refused
    ///         while the token circulates. Bindings are changed in the registry the token has.
    function test_setIdentityRegistry_RevertWhen_TheTokenIsCirculating() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TokenCirculating.selector);
        token.setIdentityRegistry(address(registry));
    }

    /* ----- Helpers ----- */

    function _bindLockup(address lockedIdentity) private returns (LockedSenderModule lockup) {
        lockup = LockedSenderModule(
            address(new ModuleProxy(address(new LockedSenderModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );

        vm.startPrank(deployer);
        compliance.addModule(address(lockup));
        compliance.callModuleFunction(
            abi.encodeCall(LockedSenderModule.setLocked, (lockedIdentity, true)), address(lockup)
        );
        vm.stopPrank();
    }

    /// @dev The movement a rule is asked about, shaped as the compliance builds it: only the sender matters
    ///      to a lockup.
    function _contextFrom(IIdentity fromIdentity) private view returns (IModule.TransferContext memory ctx) {
        ctx.compliance = address(compliance);
        ctx.fromIdentity = address(fromIdentity);
        ctx.toIdentity = address(bobIdentity);
        ctx.amountMin = 1;
        ctx.amountMax = 1;
    }

    function _revokeAlice() private {
        _revokeWallet(aliceIdentity, InteroperableAddress.formatEvmV1(block.chainid, alice));
    }

    function _positionOf(IIdentity identity) private view returns (uint256) {
        return IComplianceLedger(address(compliance)).positionOf(address(identity));
    }

    function _positionsSum() private view returns (uint256) {
        return _positionOf(aliceIdentity) + _positionOf(bobIdentity);
    }

}
