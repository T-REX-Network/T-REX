// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { StdInvariant } from "@forge-std/StdInvariant.sol";
import { console } from "@forge-std/console.sol";
import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @title ComplianceLedgerInvariants
/// @notice Stateful check of the four numbers the compliance keeps, against the token's own buckets.
///
/// Three identities, each with a native wallet and two wallets on one satellite chain, so every issued
/// validation has a single leg and nothing waits in transit. The transitions are the ones the ledger is written
/// from: mint, burn, transfer, forced transfer, validation issuance (to another identity, to the same identity,
/// to a native wallet), settlement in time or late, the keeper's discard, and a wallet no registry names that an
/// agent tries to pay with eligibility checks disabled, links, and moves tokens out of. A cap is bound so
/// issuance is really narrowed by the ledger.
///
///   LEDGER-1  positionOf(identity) == native balance + bridged balances over the identity's wallets
///   LEDGER-2  sum of positions == totalSupply()
///   LEDGER-3  pendingInOf / pendingOutOf == sum of amountMax over stored-Pending validations of the identity,
///             relocations excluded
///   LEDGER-4  the token's reservedOf(wallet) == sum of amountMax over open validations out of that wallet
///   LEDGER-5  a wallet no registry names holds nothing, even with eligibility checks disabled; once linked, its
///             tokens are counted under the identity it was linked to, and never under the wallet itself
/// forge-config: default.invariant.fail-on-revert = true
contract ComplianceLedgerInvariants is StdInvariant, InteropSuiteTest {

    uint256 internal constant ACTORS = 3;
    uint256 internal constant WALLETS_PER_ACTOR = 2;
    uint256 internal constant MAX_AMOUNT = 500;
    uint256 internal constant CAP = 4000;

    address[] internal actors;
    IIdentity[] internal identities;
    bytes[][] internal satellites;
    bytes32[] internal issued;

    ERC7786GatewayMock internal gateway;
    IComplianceLedger internal ledger;

    uint256 public callsMint;
    uint256 public callsBurn;
    uint256 public callsTransfer;
    uint256 public callsForcedTransfer;
    uint256 public callsIssue;
    uint256 public callsSettle;
    uint256 public callsDiscard;
    uint256 public callsRevoke;
    uint256 public callsToStrangerRefused;
    uint256 public callsToStrangerLanded;
    uint256 public callsLinkStranger;
    uint256 public callsFromStranger;

    /// @dev A wallet no registry names until `linkStranger` links it.
    address internal stranger;
    /// @dev The identity `linkStranger` linked the stranger to; zero until then. Bindings are sticky, so it is
    ///      set at most once.
    address internal strangerIdentity;

    function setUp() public override {
        super.setUp();
        ledger = IComplianceLedger(address(boundCompliance));
        gateway = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(gateway));

        stranger = makeAddr("stranger");
        actors = [alice, bob, charlie];
        identities = [aliceIdentity, bobIdentity, charlieIdentity];
        satellites = new bytes[][](ACTORS);
        for (uint256 i = 0; i < ACTORS; i++) {
            satellites[i] = new bytes[](WALLETS_PER_ACTOR);
            for (uint256 j = 0; j < WALLETS_PER_ACTOR; j++) {
                string memory label = string.concat("sat", vm.toString(i), "-", vm.toString(j));
                satellites[i][j] = _fundSatelliteWallet(identities[i], actors[i], POLYGON, makeAccount(label), 1000);
            }
        }

        MaxBalancePerIdentityModule cap = MaxBalancePerIdentityModule(
            address(
                new ModuleProxy(
                    address(new MaxBalancePerIdentityModule()),
                    abi.encodeCall(MaxBalancePerIdentityModule.initialize, (address(suiteManager)))
                )
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(MaxBalancePerIdentityModule.setMaxBalance, (CAP));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(cap), settings);

        vm.prank(agent);
        token.unpause();

        targetContract(address(this));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = this.mint.selector;
        selectors[1] = this.burn.selector;
        selectors[2] = this.transfer.selector;
        selectors[3] = this.forcedTransfer.selector;
        selectors[4] = this.issue.selector;
        selectors[5] = this.settle.selector;
        selectors[6] = this.discard.selector;
        selectors[7] = this.revokeNativeWallet.selector;
        selectors[8] = this.forcedTransferToStranger.selector;
        selectors[9] = this.linkStranger.selector;
        selectors[10] = this.forcedTransferFromStranger.selector;
        targetSelector(FuzzSelector({ addr: address(this), selectors: selectors }));
    }

    /* ----- Transitions ----- */

    function mint(uint256 actorSeed, uint256 amount) external {
        callsMint++;
        address to = actors[actorSeed % ACTORS];
        amount = bound(amount, 1, MAX_AMOUNT);
        vm.prank(agent);
        try token.mint(to, amount) { } catch { }
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        callsBurn++;
        address from = actors[actorSeed % ACTORS];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(agent);
        token.burn(from, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        callsTransfer++;
        address from = actors[fromSeed % ACTORS];
        address to = actors[toSeed % ACTORS];
        uint256 free = token.freeBalanceOf(from);
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(from);
        try token.transfer(to, amount) { } catch { }
    }

    function forcedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        callsForcedTransfer++;
        address from = actors[fromSeed % ACTORS];
        address to = actors[toSeed % ACTORS];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(agent);
        try token.forcedTransfer(from, to, amount) { } catch { }
    }

    /// @dev Issues from one satellite wallet toward another satellite wallet or a native wallet. The
    ///      recipient is any actor, so the same identity comes up one time in three and exercises the
    ///      relocation path, where nothing is reserved against the identity.
    function issue(uint256 fromSeed, uint256 fromWallet, uint256 toSeed, uint256 toWallet, uint256 min, uint256 max)
        external
    {
        callsIssue++;
        uint256 fromActor = fromSeed % ACTORS;
        bytes memory from = satellites[fromActor][fromWallet % WALLETS_PER_ACTOR];
        uint256 toActor = toSeed % ACTORS;
        bytes memory to = toWallet % (WALLETS_PER_ACTOR + 1) == WALLETS_PER_ACTOR
            ? _nativeEnvelope(actors[toActor])
            : satellites[toActor][toWallet % WALLETS_PER_ACTOR];

        uint256 balance = token.bridgedBalanceOf(from);
        uint256 pending = token.reservedOf(from);
        if (balance <= pending) return;
        max = bound(max, 1, balance - pending);
        min = bound(min, 1, max);

        if (boundCompliance.isIssuancePaused(polygon)) {
            vm.prank(deployer);
            boundCompliance.setIssuancePaused(polygon, false);
        }

        vm.prank(address(identities[fromActor]));
        try boundCompliance.requestTransferValidation(from, to, min, max, "", _salt()) returns (bytes32 id) {
            issued.push(id);
        } catch { }
    }

    /// @dev Settles an issued validation that has not settled yet, in time or late, at any amount inside its
    ///      range. A late one after a discard is what the late-reconciliation path is for.
    function settle(uint256 idSeed, uint256 amountSeed) external {
        callsSettle++;
        if (issued.length == 0) return;
        bytes32 id = issued[idSeed % issued.length];
        ITransferValidation.Validation memory validation = boundCompliance.validationOf(id);
        if (_burnLegArrived(validation.status)) return;
        uint256 amount = bound(amountSeed, validation.amountMin, validation.amountMax);

        (bytes memory from, bytes memory to) = _walletsOf(validation);
        uint256 index = _liteSettles(gateway, token, _settlement(id, from, to, amount));
        try gateway.relay(index) { } catch { }
    }

    /// @dev The keeper discards a validation past its release time, or this handler, holding no role, past the
    ///      second window; the clock moves forward to get there.
    function discard(uint256 idSeed, bool asKeeper) external {
        callsDiscard++;
        if (issued.length == 0) return;
        bytes32 id = issued[idSeed % issued.length];
        ITransferValidation.Validation memory validation = boundCompliance.validationOf(id);
        if (validation.status != ITransferValidation.ValidationStatus.Pending) return;

        uint64 openAt =
            asKeeper ? validation.releaseAt : validation.releaseAt + (validation.releaseAt - validation.expiry);
        if (block.timestamp <= openAt) vm.warp(openAt + 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        if (asKeeper) vm.prank(keeper);
        boundCompliance.discardExpiredValidations(ids);
    }

    /// @dev An investor retires one of their own native wallets in ONCHAINID. It keeps whatever it holds and
    ///      keeps its owner, so every later movement out of it must still reach the right position; what it
    ///      loses is the right to act. Revocation is terminal, so a wallet is revoked at most once and the
    ///      sequence never walks back.
    function revokeNativeWallet(uint256 actorSeed) external {
        uint256 actor = actorSeed % ACTORS;
        bytes memory envelope = InteroperableAddress.formatEvmV1(block.chainid, actors[actor]);
        if (idFactory.getAccountStatus(envelope) != IIdentityFactory.AccountStatus.Active) return;

        callsRevoke++;
        // The local entry goes first: it is a plain mapping that knows nothing of revocation, so while it
        // stands the wallet resolves through it and the revocation would not reach the ledger at all.
        ITREXRegistry registry = ITREXRegistry(address(token.identityRegistry()));
        if (registry.isLocallyRegistered(actors[actor])) {
            vm.prank(agent);
            IERC3643IdentityRegistry(address(registry)).deleteIdentity(actors[actor]);
        }
        _revokeWallet(identities[actor], envelope);
    }

    /// @dev With eligibility checks off, an agent moves tokens to the stranger. Disabling the checks skips the
    ///      claims, not the identity, so this is refused until the stranger is linked, and lands under the linked
    ///      identity after.
    function forcedTransferToStranger(uint256 fromSeed, uint256 amount) external {
        address from = actors[fromSeed % ACTORS];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        bool linked = strangerIdentity != address(0);
        if (linked) callsToStrangerLanded++;
        else callsToStrangerRefused++;
        ITREXRegistry registry = ITREXRegistry(address(token.identityRegistry()));
        vm.prank(deployer);
        registry.disableEligibilityChecks();
        vm.prank(agent);
        if (!linked) vm.expectRevert(ERC3643ErrorsLib.UnverifiedIdentity.selector);
        token.forcedTransfer(from, stranger, amount);
        vm.prank(deployer);
        registry.enableEligibilityChecks();
    }

    /// @dev An agent links the stranger to an identity. Bindings are sticky, so this happens at most once.
    function linkStranger(uint256 actorSeed) external {
        if (strangerIdentity != address(0)) return;
        IIdentity identity = identities[actorSeed % ACTORS];
        IERC3643IdentityRegistry registry = token.identityRegistry();

        callsLinkStranger++;
        vm.prank(agent);
        registry.registerIdentity(stranger, identity, 0);
        strangerIdentity = address(identity);
    }

    /// @dev An agent moves tokens out of the stranger's wallet to an actor that can still receive.
    function forcedTransferFromStranger(uint256 toSeed, uint256 amount) external {
        address to = actors[toSeed % ACTORS];
        uint256 balance = token.balanceOf(stranger);
        if (balance == 0 || !token.identityRegistry().isVerified(to)) return;
        amount = bound(amount, 1, balance);

        callsFromStranger++;
        vm.prank(agent);
        token.forcedTransfer(stranger, to, amount);
    }

    /* ----- Invariants ----- */

    /// LEDGER-1: a position is exactly what the identity's wallets hold, native and bridged.
    function invariant_positionMatchesRecount() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            assertEq(
                ledger.positionOf(address(identities[i])),
                _recount(i),
                string.concat("LEDGER-1 position drifted from the wallets of actor ", vm.toString(i))
            );
        }
    }

    /// LEDGER-2: the positions sum to the supply. Every token has an owner, so nothing is left uncounted.
    function invariant_positionsSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < ACTORS; i++) {
            sum += ledger.positionOf(address(identities[i]));
        }
        assertEq(sum, token.totalSupply(), "LEDGER-2 positions != supply");
    }

    /// LEDGER-5: a wallet no registry names holds nothing, and a linked wallet is counted under its identity.
    function invariant_strangerHasAnOwnerOrNothing() public view {
        if (strangerIdentity == address(0)) {
            assertEq(token.balanceOf(stranger), 0, "LEDGER-5 tokens landed on a wallet nobody owns");
        }
        assertEq(ledger.positionOf(stranger), 0, "LEDGER-5 a wallet is counted under itself");
        if (token.balanceOf(stranger) != 0) {
            assertEq(ledger.ownerOf(stranger), strangerIdentity, "LEDGER-5 counted under another owner");
        }
    }

    /// LEDGER-3: the pending amounts of an identity are the open validations' maxima, relocations excluded.
    function invariant_pendingMatchesOpenValidations() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            (uint256 expectedIn, uint256 expectedOut) = _openPendingOf(address(identities[i]));
            assertEq(ledger.pendingInOf(address(identities[i])), expectedIn, "LEDGER-3 pendingIn drifted");
            assertEq(ledger.pendingOutOf(address(identities[i])), expectedOut, "LEDGER-3 pendingOut drifted");
        }
    }

    /// LEDGER-4: a wallet's pending amount is the open validations' maxima out of it, relocations included.
    function invariant_walletPendingMatchesOpenValidations() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            for (uint256 j = 0; j < WALLETS_PER_ACTOR; j++) {
                bytes memory wallet = satellites[i][j];
                assertEq(
                    token.reservedOf(wallet),
                    _openWalletPendingOf(WalletKeyLib.canonicalKey(wallet)),
                    "LEDGER-4 wallet reservation drifted"
                );
            }
        }
    }

    function invariant_callSummary() public view {
        console.log("mint          ", callsMint);
        console.log("burn          ", callsBurn);
        console.log("transfer      ", callsTransfer);
        console.log("forcedTransfer", callsForcedTransfer);
        console.log("issue         ", callsIssue);
        console.log("settle        ", callsSettle);
        console.log("discard       ", callsDiscard);
        console.log("revoke        ", callsRevoke);
        console.log("toStranger    ", callsToStrangerRefused, "refused before the link,", callsToStrangerLanded);
        console.log("              ", "landed after it");
        console.log("linkStranger  ", callsLinkStranger);
        console.log("fromStranger  ", callsFromStranger);
        console.log("validations   ", issued.length);
    }

    /* ----- Recounts ----- */

    function _recount(uint256 actor) private view returns (uint256 sum) {
        sum = token.balanceOf(actors[actor]);
        if (strangerIdentity == address(identities[actor])) sum += token.balanceOf(stranger);
        for (uint256 j = 0; j < WALLETS_PER_ACTOR; j++) {
            sum += token.bridgedBalanceOf(satellites[actor][j]);
        }
    }

    /// @dev The reservation rules, spelled out here rather than read back from the compliance. A harness that
    ///      asked the contract what it still reserves would agree with it by construction and prove nothing;
    ///      these are the rules the lifecycle is supposed to follow, written independently.
    function _burnLegArrived(ITransferValidation.ValidationStatus status) private pure returns (bool) {
        return status == ITransferValidation.ValidationStatus.AwaitingMint
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingMint
            || status == ITransferValidation.ValidationStatus.Settled
            || status == ITransferValidation.ValidationStatus.LateReconciled;
    }

    /// @dev The identities' pending amounts are outstanding while the movement is still expected, and never on
    ///      a relocation, where nothing was reserved against them in the first place.
    function _reservesIdentities(ITransferValidation.Validation memory v) private pure returns (bool) {
        if (v.relocation) return false;
        return v.status == ITransferValidation.ValidationStatus.Pending
            || v.status == ITransferValidation.ValidationStatus.AwaitingMint
            || v.status == ITransferValidation.ValidationStatus.AwaitingBurn;
    }

    /// @dev The sender wallet's share is outstanding until its burn leg arrives, which moves the amount into
    ///      transit on the token instead.
    function _reservesWallet(ITransferValidation.Validation memory v) private pure returns (bool) {
        return v.status == ITransferValidation.ValidationStatus.Pending
            || v.status == ITransferValidation.ValidationStatus.AwaitingBurn;
    }

    function _openPendingOf(address identity) private view returns (uint256 pendingIn, uint256 pendingOut) {
        for (uint256 i = 0; i < issued.length; i++) {
            ITransferValidation.Validation memory validation = boundCompliance.validationOf(issued[i]);
            if (!_reservesIdentities(validation)) continue;
            if (validation.toIdentity == identity) pendingIn += validation.amountMax;
            if (validation.fromIdentity == identity) pendingOut += validation.amountMax;
        }
    }

    function _openWalletPendingOf(bytes32 key) private view returns (uint256 pending) {
        for (uint256 i = 0; i < issued.length; i++) {
            ITransferValidation.Validation memory validation = boundCompliance.validationOf(issued[i]);
            if (_reservesWallet(validation) && validation.fromKey == key) pending += validation.amountMax;
        }
    }

    /// @dev The envelopes a validation was issued for, found again by their canonical keys.
    function _walletsOf(ITransferValidation.Validation memory validation)
        private
        view
        returns (bytes memory from, bytes memory to)
    {
        for (uint256 i = 0; i < ACTORS; i++) {
            if (validation.toKey == WalletKeyLib.canonicalKey(_nativeEnvelope(actors[i]))) {
                to = _nativeEnvelope(actors[i]);
            }
            for (uint256 j = 0; j < WALLETS_PER_ACTOR; j++) {
                bytes32 key = WalletKeyLib.canonicalKey(satellites[i][j]);
                if (key == validation.fromKey) from = satellites[i][j];
                if (key == validation.toKey) to = satellites[i][j];
            }
        }
    }

    function _nativeEnvelope(address wallet) private view returns (bytes memory) {
        return _satelliteEnvelope(block.chainid, wallet);
    }

}
