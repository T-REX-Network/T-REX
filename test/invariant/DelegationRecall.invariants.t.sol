// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { StdInvariant } from "@forge-std/StdInvariant.sol";
import { console } from "@forge-std/console.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";
import { Utils } from "test/unit/helpers/Utils.sol";

/// @title DelegationRecallInvariants
/// @notice Stateful check of delegation-out and recall through the public entry points, with a mock Lite that
///  follows `docs/satellite-lite.md` in the loop.
///
/// Three identities, each with a native wallet and one linked wallet on one satellite chain. The fuzzer mints,
/// transfers natively, delegates, instructs recalls, resends either instruction, has the Lite resend a stored proof,
/// and relays or drops queued messages in any order, so instructions, resends, proofs and duplicates interleave.
///
///   DR-1  positionOf(identity) == native balance + bridged balance of its wallets
///   DR-2  sum of positions == totalSupply()
///   DR-3  totalBridged == Lite balances + mints instructed and not yet minted + burns done on the Lite whose
///         proof has not settled yet (the Lite no longer holds them, the token still counts them)
///   DR-4  the Lite minted exactly the delegations it received, once each
///   DR-5  every settled recall debited exactly what the Lite burned for it
///   DR-6  an honest Lite never makes the token halt
contract DelegationRecallInvariants is StdInvariant, InteropSuiteTest {

    uint256 internal constant ACTORS = 3;
    uint256 internal constant MAX_AMOUNT = 400;

    address[] internal actors;
    IIdentity[] internal identities;
    bytes[] internal satellites;

    ERC7786GatewayMock internal gateway;
    SatelliteLiteMock internal lite;
    IComplianceLedger internal ledger;

    uint256[] internal delegationAmount;
    uint256[] internal delegationActor;
    uint256[] internal recallActor;
    uint256 internal settledDebits;

    uint256 public callsDelegate;
    uint256 public callsInstruct;
    uint256 public callsResend;
    uint256 public callsRelay;

    function setUp() public override {
        super.setUp();
        ledger = IComplianceLedger(address(boundCompliance));
        gateway = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(gateway));
        lite = new SatelliteLiteMock(POLYGON, address(token), gateway);
        vm.prank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(lite)));

        actors = [alice, bob, charlie];
        identities = [aliceIdentity, bobIdentity, charlieIdentity];
        for (uint256 i = 0; i < ACTORS; i++) {
            satellites.push(
                _linkSatelliteWallet(identities[i], POLYGON, makeAccount(string.concat("sat", vm.toString(i))))
            );
        }
        delegationAmount.push(0);
        delegationActor.push(0);
        recallActor.push(0);

        vm.startPrank(agent);
        for (uint256 i = 0; i < ACTORS; i++) {
            token.mint(actors[i], 1000);
        }
        token.unpause();
        vm.stopPrank();

        targetContract(address(this));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = this.mint.selector;
        selectors[1] = this.transfer.selector;
        selectors[2] = this.delegate.selector;
        selectors[3] = this.instructRecall.selector;
        selectors[4] = this.resend.selector;
        selectors[5] = this.liteResendsProof.selector;
        selectors[6] = this.relay.selector;
        selectors[7] = this.drop.selector;
        targetSelector(FuzzSelector({ addr: address(this), selectors: selectors }));
    }

    /* ----- Transitions ----- */

    function mint(uint256 actorSeed, uint256 amount) external {
        vm.prank(agent);
        token.mint(actors[actorSeed % ACTORS], bound(amount, 1, MAX_AMOUNT));
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % ACTORS];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        try token.transfer(actors[toSeed % ACTORS], amount) { } catch { }
    }

    function delegate(uint256 actorSeed, uint256 amount) external {
        callsDelegate++;
        uint256 actor = actorSeed % ACTORS;
        amount = bound(amount, 1, MAX_AMOUNT);
        vm.prank(actors[actor]);
        try token.delegateOut(actors[actor], satellites[actor], amount) {
            delegationAmount.push(amount);
            delegationActor.push(actor);
        } catch { }
    }

    function instructRecall(uint256 actorSeed, uint256 amount) external {
        callsInstruct++;
        uint256 actor = actorSeed % ACTORS;
        amount = bound(amount, 1, MAX_AMOUNT);
        vm.prank(agent);
        try token.instructRecall(satellites[actor], amount, actors[actor]) {
            recallActor.push(actor);
        } catch { }
    }

    function resend(uint256 idSeed, bool recall) external {
        callsResend++;
        if (recall) {
            if (recallActor.length == 1) return;
            uint256 id = 1 + idSeed % (recallActor.length - 1);
            bytes memory wallet = abi.encode(satellites[recallActor[id]]);
            vm.prank(agent);
            try token.resend(1, id, wallet) { } catch { }
        } else {
            if (delegationAmount.length == 1) return;
            uint256 id = 1 + idSeed % (delegationAmount.length - 1);
            uint256 actor = delegationActor[id];
            bytes memory fields =
                abi.encode(satellites[actor], delegationAmount[id], actors[actor], token.peerFor(polygon));
            vm.prank(agent);
            try token.resend(0, id, fields) { } catch { }
        }
    }

    function liteResendsProof(uint256 idSeed) external {
        if (recallActor.length == 1) return;
        try lite.resendProof(1 + idSeed % (recallActor.length - 1)) { } catch { }
    }

    function relay(uint256 indexSeed) external {
        callsRelay++;
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        uint256 index = indexSeed % length;
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(index);
        if (message.deliveries != 0 || message.dropped) return;
        try gateway.relay(index) { } catch { }
    }

    function drop(uint256 indexSeed) external {
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        uint256 index = indexSeed % length;
        if (gateway.queuedMessage(index).deliveries == 0) gateway.drop(index);
    }

    /* ----- Invariants ----- */

    function invariant_DR1_positionsFollowTheWallets() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            assertEq(
                ledger.positionOf(address(identities[i])),
                token.balanceOf(actors[i]) + token.bridgedBalanceOf(satellites[i]),
                "DR-1"
            );
        }
    }

    function invariant_DR2_positionsSumToTheSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < ACTORS; i++) {
            sum += ledger.positionOf(address(identities[i]));
        }
        assertEq(sum, token.totalSupply(), "DR-2");
        assertEq(ledger.positionGap(), 0, "DR-2 gap");
    }

    function invariant_DR3_bridgedMatchesTheLitePlusWhatIsInFlight() public view {
        uint256 liteBalances;
        for (uint256 i = 0; i < ACTORS; i++) {
            liteBalances += lite.balanceOf(satellites[i]);
        }
        uint256 pendingMints;
        for (uint256 id = 1; id < delegationAmount.length; id++) {
            if (lite.delegationSeen(id) == 0) pendingMints += delegationAmount[id];
        }
        uint256 pendingBurns;
        for (uint256 id = 1; id < recallActor.length; id++) {
            if (token.pendingRecall(id).amount != 0) pendingBurns += lite.burnedFor(id);
        }
        assertEq(token.totalBridged(), liteBalances + pendingMints + pendingBurns, "DR-3");
        assertEq(token.totalInTransit(), 0, "DR-3 transit");
    }

    function invariant_DR4_theLiteMintedEachDelegationOnce() public view {
        uint256 received;
        for (uint256 id = 1; id < delegationAmount.length; id++) {
            if (lite.delegationSeen(id) != 0) received += delegationAmount[id];
        }
        assertEq(lite.mints(), received, "DR-4");
    }

    function invariant_DR5_settledRecallsDebitedWhatWasBurned() public view {
        uint256 settledBurns;
        for (uint256 id = 1; id < recallActor.length; id++) {
            if (token.pendingRecall(id).amount == 0) settledBurns += lite.burnedFor(id);
        }
        uint256 delegated;
        for (uint256 id = 1; id < delegationAmount.length; id++) {
            delegated += delegationAmount[id];
        }
        assertEq(token.totalBridged(), delegated - settledBurns, "DR-5");
    }

    function invariant_DR6_anHonestLiteNeverHaltsTheToken() public view {
        assertFalse(token.paused(), "DR-6");
    }

    function invariant_callSummary() public view {
        uint256 settled;
        for (uint256 id = 1; id < recallActor.length; id++) {
            if (token.pendingRecall(id).amount == 0 && lite.recallSeen(id) != 0) settled++;
        }
        console.log("delegate calls / landed:", callsDelegate, delegationAmount.length - 1);
        console.log("recall calls / landed / settled:", callsInstruct, recallActor.length - 1, settled);
        console.log("resends, relays:", callsResend, callsRelay);
    }

}
