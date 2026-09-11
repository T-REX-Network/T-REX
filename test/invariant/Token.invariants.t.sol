// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { StdInvariant } from "@forge-std/StdInvariant.sol";
import { console } from "@forge-std/console.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { Token } from "contracts/token/Token.sol";

import { TREXSuiteTest } from "../integration/helpers/TREXSuiteTest.sol";
import { TokenLedgerHarness } from "../integration/helpers/TokenLedgerHarness.sol";
import { TokenHandler } from "./handlers/TokenHandler.sol";

/// @title Token invariants
/// @notice Stateful fuzzing of the Token transfer/mint/burn/freeze surface and of the bridged ledger, reusing
///         the full wired suite from TREXSuiteTest with the ledger harness as token implementation. The handler
///         restricts all balance holders to {alice, bob, charlie} (all registered & verified), each with two
///         satellite wallets on two chain ids, so the invariant checker can enumerate every position.
///
/// Invariants:
///   INV-1  totalSupply() == ghostMinted - ghostBurned                 (supply only moves via mint/burn)
///   INV-2  sum(balanceOf(actor)) == totalSupply() - totalBridged()    (native balances are the native supply)
///   INV-3  frozenStatus[actor].amount <= balanceOf(actor)             (free balance never negative)
///   INV-4  compliance.getTokenBound() == address(token)               (binding is stable)
///   INV-5  no transfer ever succeeded while paused                    (pause gate holds)
///   INV-6  no successful transfer landed on an unverified recipient   (eligibility gate holds)
///   INV-7  totalSupply() == Σ free + Σ frozen + Σ bridged             (conservation across buckets)
///   INV-8  totalBridged() == ghostBridgedTotal == Σ bridgedBalanceOf  (bridged total tracks the positions)
contract TokenInvariants is StdInvariant, TREXSuiteTest {

    uint256 internal constant SATELLITE_CHAIN_A = 8453;
    uint256 internal constant SATELLITE_CHAIN_B = 137;

    TokenHandler internal handler;
    TokenLedgerHarness internal ledger;

    function _deployImplementations() internal override {
        super._deployImplementations();
        tokenImplementation = Token(address(new TokenLedgerHarness()));
    }

    function setUp() public override {
        super.setUp();

        // The proxy is the same as any token's: the implementation behind the beacon is the ledger harness.
        ledger = TokenLedgerHarness(address(token));

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = charlie;

        bytes[][] memory satellites = new bytes[][](3);
        for (uint256 i = 0; i < 3; i++) {
            satellites[i] = new bytes[](2);
            satellites[i][0] =
                InteroperableAddress.formatEvmV1(SATELLITE_CHAIN_A, makeAddr(string.concat("satA", vm.toString(i))));
            satellites[i][1] =
                InteroperableAddress.formatEvmV1(SATELLITE_CHAIN_B, makeAddr(string.concat("satB", vm.toString(i))));
        }

        handler = new TokenHandler(ledger, agent, actors, satellites);

        // Only fuzz the handler's transitions.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = TokenHandler.mint.selector;
        selectors[1] = TokenHandler.burn.selector;
        selectors[2] = TokenHandler.transfer.selector;
        selectors[3] = TokenHandler.forcedTransfer.selector;
        selectors[4] = TokenHandler.freezePartial.selector;
        selectors[5] = TokenHandler.unfreezePartial.selector;
        selectors[6] = TokenHandler.setAddressFrozen.selector;
        selectors[7] = TokenHandler.togglePause.selector;
        selectors[8] = TokenHandler.delegateOut.selector;
        selectors[9] = TokenHandler.recall.selector;
        selectors[10] = TokenHandler.bridgedTransfer.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));

        // The handler pranks `agent` for restricted calls; exclude the named privileged addresses as senders
        // so only the handler initiates calls. `address(this)` is the AccessManager admin in this harness.
        excludeSender(agent);
        excludeSender(deployer);
        excludeSender(address(this));
    }

    // ------------------------------------------------------------------
    // Sums over the enumerable position set
    // ------------------------------------------------------------------

    function _nativeSum() internal view returns (uint256 sum) {
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.actorAt(i));
        }
    }

    function _bucketSums() internal view returns (uint256 freeSum, uint256 frozenSum, uint256 bridgedSum) {
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            freeSum += token.freeBalanceOf(a);
            frozenSum += token.getFrozenTokens(a);
            bytes[] memory satellites = handler.satellitesOf(i);
            for (uint256 j = 0; j < satellites.length; j++) {
                bridgedSum += token.bridgedBalanceOf(satellites[j]);
            }
        }
    }

    // ------------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------------

    /// INV-1: supply equals the external mint/burn model.
    function invariant_supplyMatchesGhostModel() public view {
        assertEq(token.totalSupply(), handler.ghostMinted() - handler.ghostBurned(), "INV-1 supply drift");
    }

    /// INV-2: the native balances of the actor set are exactly the native supply.
    function invariant_balancesSumToNativeSupply() public view {
        assertEq(_nativeSum(), token.totalSupply() - token.totalBridged(), "INV-2 balance sum != native supply");
    }

    /// INV-3: frozen amount never exceeds balance (free balance >= 0).
    function invariant_frozenNeverExceedsBalance() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            assertLe(token.getFrozenTokens(a), token.balanceOf(a), "INV-3 frozen > balance");
        }
    }

    /// INV-4: the compliance stays bound to this token.
    function invariant_complianceBindingStable() public view {
        assertEq(token.compliance().getTokenBound(), address(token), "INV-4 compliance unbound");
    }

    /// INV-5: a transfer never succeeded while the token was paused.
    function invariant_pausedBlocksTransfers() public view {
        assertEq(handler.pausedTransferLeak(), false, "INV-5 transfer succeeded while paused");
    }

    /// INV-6: a successful transfer never landed on an unverified recipient.
    function invariant_recipientsAlwaysVerified() public view {
        assertEq(handler.unverifiedRecipientLeak(), false, "INV-6 unverified recipient received tokens");
    }

    /// INV-7: the supply is conserved across the free, frozen and bridged buckets.
    function invariant_supplyIsConservedAcrossBuckets() public view {
        (uint256 freeSum, uint256 frozenSum, uint256 bridgedSum) = _bucketSums();
        assertEq(freeSum + frozenSum + bridgedSum, token.totalSupply(), "INV-7 buckets do not sum to the supply");
        assertEq(token.balanceOf(address(token)), 0, "INV-7 the token holds no escrow");
    }

    /// INV-8: the bridged total is the sum of the bridged positions and matches the external model.
    function invariant_bridgedTotalMatchesPositions() public view {
        (,, uint256 bridgedSum) = _bucketSums();
        assertEq(token.totalBridged(), handler.ghostBridgedTotal(), "INV-8 bridged total drifted from the model");
        assertEq(token.totalBridged(), bridgedSum, "INV-8 bridged total != bridged sum");
    }

    /// @notice Prints how often each transition fired (visible with `forge test -vv`).
    function invariant_callSummary() public view {
        console.log("mint           ", handler.callsMint());
        console.log("burn           ", handler.callsBurn());
        console.log("transfer       ", handler.callsTransfer());
        console.log("forcedTransfer ", handler.callsForcedTransfer());
        console.log("freeze         ", handler.callsFreeze());
        console.log("unfreeze       ", handler.callsUnfreeze());
        console.log("pauseToggle    ", handler.callsPauseToggle());
        console.log("delegateOut    ", handler.callsDelegateOut());
        console.log("recall         ", handler.callsRecall());
        console.log("bridgedTransfer", handler.callsBridgedTransfer());
    }

}
