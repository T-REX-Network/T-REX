// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { StdInvariant } from "@forge-std/StdInvariant.sol";
import { console2 } from "@forge-std/console2.sol";

import { TREXSuiteTest } from "../integration/helpers/TREXSuiteTest.sol";
import { TokenHandler } from "./handlers/TokenHandler.sol";

/// @title Token invariants
/// @notice Stateful fuzzing of the Token transfer/mint/burn/freeze surface, reusing the full wired suite from
///         TREXSuiteTest. The handler restricts all balance holders to {alice, bob, charlie} (all registered &
///         verified) so the invariant checker can enumerate every holder.
///
/// Invariants:
///   INV-1  totalSupply() == ghostMinted - ghostBurned                 (supply only moves via mint/burn)
///   INV-2  sum(balanceOf(actor)) == totalSupply()                     (no tokens escape the actor set)
///   INV-3  frozenStatus[actor].amount <= balanceOf(actor)             (free balance never negative)
///   INV-4  compliance.getTokenBound() == address(token)               (binding is stable)
///   INV-5  no transfer ever succeeded while paused                    (pause gate holds)
///   INV-6  no successful transfer landed on an unverified recipient   (eligibility gate holds)
contract TokenInvariants is StdInvariant, TREXSuiteTest {

    TokenHandler internal handler;

    function setUp() public override {
        super.setUp();

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = charlie;

        handler = new TokenHandler(token, agent, actors);

        // Only fuzz the handler's transitions.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = TokenHandler.mint.selector;
        selectors[1] = TokenHandler.burn.selector;
        selectors[2] = TokenHandler.transfer.selector;
        selectors[3] = TokenHandler.forcedTransfer.selector;
        selectors[4] = TokenHandler.freezePartial.selector;
        selectors[5] = TokenHandler.unfreezePartial.selector;
        selectors[6] = TokenHandler.setAddressFrozen.selector;
        selectors[7] = TokenHandler.togglePause.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));

        // The handler pranks `agent` for restricted calls; exclude the named EOAs as senders so only the
        // handler initiates calls.
        excludeSender(agent);
        excludeSender(deployer);
        excludeSender(accessManagerAdmin);
    }

    /// INV-1: supply equals the external mint/burn model.
    function invariant_supplyMatchesGhostModel() public view {
        assertEq(token.totalSupply(), handler.ghostMinted() - handler.ghostBurned(), "INV-1 supply drift");
    }

    /// INV-2: all tokens are held by the known actor set.
    function invariant_balancesSumToTotalSupply() public view {
        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, token.totalSupply(), "INV-2 balance sum != totalSupply");
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

    /// @notice Prints how often each transition fired (visible with `forge test -vv`).
    function invariant_callSummary() public view {
        console2.log("mint           ", handler.callsMint());
        console2.log("burn           ", handler.callsBurn());
        console2.log("transfer       ", handler.callsTransfer());
        console2.log("forcedTransfer ", handler.callsForcedTransfer());
        console2.log("freeze         ", handler.callsFreeze());
        console2.log("unfreeze       ", handler.callsUnfreeze());
        console2.log("pauseToggle    ", handler.callsPauseToggle());
    }
}
