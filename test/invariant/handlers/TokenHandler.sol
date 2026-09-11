// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";

/// @title TokenHandler
/// @notice Bounded action driver for the Token invariant suite. Every public function here is a "transition"
///         the invariant fuzzer may call in any order. All token holders are restricted to a fixed actor set
///         (passed in at construction) so the invariant checker can enumerate every balance holder; each actor
///         also owns a fixed set of satellite wallets that hold its bridged positions.
///
///         Ghost variables track supply movements (mint/burn) and the bridged total independently of the token
///         so the invariants can assert the token's own accounting matches an external model.
contract TokenHandler is Test {

    TokenLedgerHarness public immutable token;
    address public immutable agent;

    address[] public actors;
    bytes[][] internal satellites;

    // ----- ghost state -----
    uint256 public ghostMinted; // total ever minted via this handler
    uint256 public ghostBurned; // total ever burned via this handler
    uint256 public ghostBridgedTotal; // delegated minus recalled
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
    uint256 public callsDelegateOut;
    uint256 public callsRecall;
    uint256 public callsBridgedTransfer;

    constructor(TokenLedgerHarness token_, address agent_, address[] memory actors_, bytes[][] memory satellites_) {
        token = token_;
        agent = agent_;
        actors = actors_;
        satellites = satellites_;
    }

    function _actor(uint256 seed) internal view returns (uint256) {
        return seed % actors.length;
    }

    function _satellite(uint256 actor, uint256 seed) internal view returns (bytes memory) {
        return satellites[actor][seed % satellites[actor].length];
    }

    // ------------------------------------------------------------------
    // Native transitions
    // ------------------------------------------------------------------

    function mint(uint256 actorSeed, uint256 amount) external {
        callsMint++;
        address to = actors[_actor(actorSeed)];
        amount = bound(amount, 0, 1e24);
        vm.prank(agent);
        try token.mint(to, amount) {
            ghostMinted += amount;
        } catch { }
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        callsBurn++;
        address from = actors[_actor(actorSeed)];
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal);
        vm.prank(agent);
        try token.burn(from, amount) {
            ghostBurned += amount;
        } catch { }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        callsTransfer++;
        address from = actors[_actor(fromSeed)];
        address to = actors[_actor(toSeed)];
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
        address from = actors[_actor(fromSeed)];
        address to = actors[_actor(toSeed)];
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal);
        vm.prank(agent);
        try token.forcedTransfer(from, to, amount) { } catch { }
    }

    function freezePartial(uint256 actorSeed, uint256 amount) external {
        callsFreeze++;
        address user = actors[_actor(actorSeed)];
        amount = bound(amount, 0, 1e24);
        vm.prank(agent);
        try token.freezePartialTokens(user, amount) { } catch { }
    }

    function unfreezePartial(uint256 actorSeed, uint256 amount) external {
        callsUnfreeze++;
        address user = actors[_actor(actorSeed)];
        amount = bound(amount, 0, 1e24);
        vm.prank(agent);
        try token.unfreezePartialTokens(user, amount) { } catch { }
    }

    function setAddressFrozen(uint256 actorSeed, bool freeze) external {
        address user = actors[_actor(actorSeed)];
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
    // Bridged transitions
    // ------------------------------------------------------------------

    function delegateOut(uint256 actorSeed, uint256 walletSeed, uint256 amount) external {
        callsDelegateOut++;
        uint256 actor = _actor(actorSeed);
        address holder = actors[actor];
        bytes memory to = _satellite(actor, walletSeed);
        amount = bound(amount, 0, token.freeBalanceOf(holder));
        vm.prank(agent);
        try token.delegateOut(holder, to, amount) {
            ghostBridgedTotal += amount;
        } catch { }
    }

    function recall(uint256 actorSeed, uint256 walletSeed, uint256 amount) external {
        callsRecall++;
        uint256 actor = _actor(actorSeed);
        address holder = actors[actor];
        bytes memory from = _satellite(actor, walletSeed);
        amount = bound(amount, 0, token.bridgedBalanceOf(from));
        vm.prank(agent);
        try token.recall(from, holder, amount) {
            ghostBridgedTotal -= amount;
        } catch { }
    }

    /// @dev Same-chain and cross-chain settlements alike: the wallets carry the chains.
    function bridgedTransfer(
        uint256 fromActorSeed,
        uint256 fromWalletSeed,
        uint256 toActorSeed,
        uint256 toWalletSeed,
        uint256 amount,
        uint256 validationId
    ) external {
        callsBridgedTransfer++;
        bytes memory from = _satellite(_actor(fromActorSeed), fromWalletSeed);
        bytes memory to = _satellite(_actor(toActorSeed), toWalletSeed);
        amount = bound(amount, 0, token.bridgedBalanceOf(from));
        vm.prank(agent);
        try token.bridgedTransfer(from, to, amount, validationId) { } catch { }
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

    function satellitesOf(uint256 i) external view returns (bytes[] memory) {
        return satellites[i];
    }

}
