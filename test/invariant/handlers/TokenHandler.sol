// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";

import { Token } from "contracts/token/Token.sol";

/// @title TokenHandler
/// @notice Bounded action driver for the Token invariant suite. Every public function here is a "transition"
///         the invariant fuzzer may call in any order. All token holders are restricted to a fixed actor set
///         (passed in at construction) so the invariant checker can enumerate every balance holder.
///
///         Ghost variables track supply movements (mint/burn) independently of the token so the invariants can
///         assert the token's own accounting matches an external model.
contract TokenHandler is Test {

    Token public immutable token;
    address public immutable agent;

    address[] public actors;

    // ----- ghost state -----
    uint256 public ghostMinted; // total ever minted via this handler
    uint256 public ghostBurned; // total ever burned via this handler
    bool public pausedTransferLeak; // set true if a transfer ever succeeded while paused (must stay false)
    bool public unverifiedRecipientLeak; // set true if a successful transfer landed on an unverified recipient

    // ----- call counters (for the invariant summary) -----
    uint256 public callsMint;
    uint256 public callsBurn;
    uint256 public callsTransfer;
    uint256 public callsForcedTransfer;
    uint256 public callsFreeze;
    uint256 public callsUnfreeze;
    uint256 public callsPauseToggle;

    constructor(Token token_, address agent_, address[] memory actors_) {
        token = token_;
        agent = agent_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ------------------------------------------------------------------
    // Transitions
    // ------------------------------------------------------------------

    function mint(uint256 actorSeed, uint256 amount) external {
        callsMint++;
        address to = _actor(actorSeed);
        amount = bound(amount, 0, 1e24);
        vm.prank(agent);
        try token.mint(to, amount) {
            ghostMinted += amount;
        } catch { }
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        callsBurn++;
        address from = _actor(actorSeed);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal);
        vm.prank(agent);
        try token.burn(from, amount) {
            ghostBurned += amount;
        } catch { }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        callsTransfer++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal);
        bool wasPaused = token.paused();
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (ok) {
                if (wasPaused && from != to && amount > 0) pausedTransferLeak = true;
                if (!token.identityRegistry().isVerified(to)) unverifiedRecipientLeak = true;
            }
        } catch { }
    }

    function forcedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        callsForcedTransfer++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal);
        vm.prank(agent);
        try token.forcedTransfer(from, to, amount) { } catch { }
    }

    function freezePartial(uint256 actorSeed, uint256 amount) external {
        callsFreeze++;
        address user = _actor(actorSeed);
        amount = bound(amount, 0, 1e24);
        vm.prank(agent);
        try token.freezePartialTokens(user, amount) { } catch { }
    }

    function unfreezePartial(uint256 actorSeed, uint256 amount) external {
        callsUnfreeze++;
        address user = _actor(actorSeed);
        amount = bound(amount, 0, 1e24);
        vm.prank(agent);
        try token.unfreezePartialTokens(user, amount) { } catch { }
    }

    function setAddressFrozen(uint256 actorSeed, bool freeze) external {
        address user = _actor(actorSeed);
        vm.prank(agent);
        try token.setAddressFrozen(user, freeze) { } catch { }
    }

    function togglePause(uint256 seed) external {
        callsPauseToggle++;
        vm.startPrank(agent);
        if (seed % 2 == 0) {
            try token.pause() { } catch { }
        } else {
            try token.unpause() { } catch { }
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Views used by the invariant contract
    // ------------------------------------------------------------------

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

}
