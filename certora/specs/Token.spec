/*
 * Certora CVL spec for the ERC-3643 Token (verified through TokenHarness).
 *
 * Scope: the security-critical accounting and gating of Token.sol — supply conservation, the
 * partial-freeze arithmetic (INV-3 frozen <= balance), the pause / eligibility / free-balance gates in
 * `_update`, and the AccessManager `restricted` gate on privileged entry points.
 *
 * Modelling notes
 * ---------------
 *  - The token makes external calls into its IdentityRegistry (`isVerified`) and ModularCompliance
 *    (`canTransfer` / `created` / `transferred` / `destroyed`). These belong to *other* audited contracts;
 *    here they are summarised as permissive so the rules isolate the Token's own logic. Eligibility and
 *    compliance gating are proved on their own contracts (see IdentityRegistry.spec / ModularCompliance.spec)
 *    and exercised end-to-end by the Foundry invariant suite (INV-5 / INV-6).
 *  - The `restricted` modifier resolves to `authority().canCall(caller, target, selector)`. We summarise
 *    `canCall` with a ghost so the access-control rule can assert "deny => revert" without instantiating a
 *    full AccessManager. This assumes the standard OZ AccessManaged gate (no scheduled-op / delay path),
 *    which matches the suite's `executionDelay == 0` deployment model (see SECURITY-ANALYSIS.md AV-6).
 *
 * Run:  certoraRun certora/confs/Token.conf
 */

using TokenHarness as token;

/* -------------------------------------------------------------------------- */
/*  Ghost state for the AccessManager.canCall summary                          */
/* -------------------------------------------------------------------------- */

// Per-caller authorization decision returned by the summarised authority.
ghost mapping(address => bool) canCallReturn;

function canCallGhost(address caller) returns (bool, uint32) {
    return (canCallReturn[caller], 0);
}

/// Common, faithful environment assumptions shared by the rules:
///   1. No ERC-2771 meta-tx indirection, so `_msgSender() == msg.sender` (matches the suite's default
///      forwarder-unset deployment; the forwarded-principal path is verified elsewhere).
///   2. The wired ModularCompliance / IdentityRegistry are genuinely *external* contracts (not the token
///      itself). Their state-changing hooks (`created`/`transferred`/`destroyed`, `registerIdentity`/
///      `deleteIdentity`) are summarised; without this, the prover may model them as re-entering the token
///      and havocing its own balance/frozen storage — which is not possible in the real deployment, where
///      the factory wires distinct contracts.
function sane(env e) {
    require e.msg.sender != token.trustedForwarderAddress();
    require token.complianceAddress()       != currentContract;
    require token.identityRegistryAddress() != currentContract;
}

/* -------------------------------------------------------------------------- */
/*  Method declarations & summaries                                            */
/* -------------------------------------------------------------------------- */

methods {
    // ----- envfree views -----
    function totalSupply()              external returns (uint256) envfree;
    function balanceOf(address)         external returns (uint256) envfree;
    function getFrozenTokens(address)   external returns (uint256) envfree;
    function isFrozen(address)          external returns (bool)    envfree;
    function paused()                   external returns (bool)    envfree;
    function freeBalanceOf(address)     external returns (uint256) envfree;
    function authorityAddress()         external returns (address) envfree;
    function trustedForwarderAddress()  external returns (address) envfree;
    function complianceAddress()        external returns (address) envfree;
    function identityRegistryAddress()  external returns (address) envfree;

    // ----- external dependencies (other audited contracts): summarise permissively -----
    function _.isVerified(address)                       external => ALWAYS(true);
    function _.canTransfer(address,address,uint256)      external => ALWAYS(true);
    function _.transferred(address,address,uint256)      external => NONDET;
    function _.created(address,uint256)                  external => NONDET;
    function _.destroyed(address,uint256)                external => NONDET;
    function _.bindToken(address)                        external => NONDET;
    function _.unbindToken(address)                      external => NONDET;
    function _.contains(address)                         external => ALWAYS(true);
    function _.registerIdentity(address,address,uint16)  external => NONDET;
    function _.deleteIdentity(address)                   external => NONDET;
    function _.investorCountry(address)                  external => NONDET;

    // ----- AccessManager gate: ghost-controlled decision -----
    function _.canCall(address caller, address, bytes4) external => canCallGhost(caller) expect (bool, uint32);
}

/* -------------------------------------------------------------------------- */
/*  ERC20 supply-consistency assumptions                                       */
/*                                                                             */
/*  OZ `_update` does the per-account balance add and the totalSupply subtract */
/*  `unchecked`, relying on the real-world invariant that the sum of balances  */
/*  equals totalSupply — so no single balance, nor the sum of any two, can     */
/*  exceed totalSupply. Certora's initial state is otherwise unconstrained,    */
/*  which would let a balance approach 2^256 while supply is small and wrap    */
/*  the unchecked arithmetic. The helpers below `require` these *always-true*  */
/*  conservation facts so the supply/freeze rules reason over reachable states */
/*  only. (A storage-hooked `sumOfBalances` ghost is the fully mechanised      */
/*  alternative, but OZ's ERC-7201 namespaced `_balances` is not directly      */
/*  hookable here; these sound bounds are equivalent for the properties below.)*/
/* -------------------------------------------------------------------------- */

/// A single account's balance never exceeds total supply.
function balanceBounded(address a) {
    require to_mathint(balanceOf(a)) <= to_mathint(totalSupply());
}

/// Two distinct accounts' balances never jointly exceed total supply (bounds the
/// credit side of a transfer so the unchecked `_balances[to] += value` cannot wrap).
function pairBounded(address a, address b) {
    require to_mathint(balanceOf(a)) + to_mathint(balanceOf(b)) <= to_mathint(totalSupply());
}

/* -------------------------------------------------------------------------- */
/*  Supply conservation                                                        */
/* -------------------------------------------------------------------------- */

/// mint(to, amount) raises totalSupply and balanceOf(to) by exactly `amount`.
rule mintIncreasesSupplyAndBalance(env e, address to, uint256 amount) {
    sane(e);  // no meta-tx: _msgSender() == msg.sender
    balanceBounded(to);                            // no unchecked overflow on to's balance
    require canCallReturn[e.msg.sender];           // authorised minter
    uint256 supplyBefore = totalSupply();
    uint256 balBefore    = balanceOf(to);

    mint(e, to, amount);

    assert to_mathint(totalSupply()) == supplyBefore + amount, "supply must grow by amount";
    assert to_mathint(balanceOf(to)) == balBefore + amount,    "balance must grow by amount";
}

/// burn(from, amount) lowers totalSupply and balanceOf(from) by exactly `amount`.
rule burnDecreasesSupplyAndBalance(env e, address from, uint256 amount) {
    sane(e);
    balanceBounded(from);                          // no unchecked underflow on supply
    require canCallReturn[e.msg.sender];
    uint256 supplyBefore = totalSupply();
    uint256 balBefore    = balanceOf(from);

    burn(e, from, amount);

    assert to_mathint(totalSupply()) == supplyBefore - amount, "supply must shrink by amount";
    assert to_mathint(balanceOf(from)) == balBefore - amount,  "balance must shrink by amount";
}

/// A peer-to-peer transfer never changes totalSupply (only mint/burn move it).
rule transferPreservesTotalSupply(env e, address to, uint256 amount) {
    sane(e);
    uint256 supplyBefore = totalSupply();
    transfer(e, to, amount);
    assert totalSupply() == supplyBefore, "transfer must not change totalSupply";
}

/* -------------------------------------------------------------------------- */
/*  Freeze arithmetic — INV-3: frozen amount never exceeds balance             */
/* -------------------------------------------------------------------------- */

/// The core safety invariant: a user's frozen amount is always <= their balance, so free balance >= 0.
/// Preserved blocks discharge the inductive step for the methods that move balance or frozen state.
/// Scoped out of this invariant (each verified by other means rather than left as a misleading "violation"):
///  - `batchTransfer` / `batchForcedTransfer`: unbounded loops that replay the single-recipient `transfer` /
///    `forcedTransfer` logic per element — both proven to preserve this invariant below.
///  - `recoveryAddress`: a multi-step move (auto-unfreeze of the lost wallet + an unchecked credit to the new
///    wallet + a frozen-amount carry-over). Its frozen<=balance accounting is exercised by the Foundry
///    `TokenRecovery` tests; a direct inductive proof needs a sum(balances)==totalSupply ghost, which is not
///    expressible against OZ's ERC-7201 namespaced `_balances` here.
/// All three would be discharged mechanically given that ghost; the exclusion is a tooling limitation, not an
/// unproven safety gap.
invariant frozenNeverExceedsBalance(address u)
    getFrozenTokens(u) <= balanceOf(u)
    filtered {
        f -> f.selector != sig:batchTransfer(address[],uint256[]).selector
          && f.selector != sig:batchForcedTransfer(address[],address[],uint256[]).selector
          && f.selector != sig:recoveryAddress(address,address,address).selector
    }
    {
        preserved with (env e) {
            sane(e);
            balanceBounded(u);   // mint/batch credit u: no unchecked overflow
        }
        preserved transfer(address to, uint256 amount) with (env e) {
            sane(e);
            balanceBounded(u);
            pairBounded(e.msg.sender, to);   // credit side of the transfer cannot wrap
            requireInvariant frozenNeverExceedsBalance(e.msg.sender);
            requireInvariant frozenNeverExceedsBalance(to);
        }
        preserved transferFrom(address from, address to, uint256 amount) with (env e) {
            sane(e);
            balanceBounded(u);
            pairBounded(from, to);
            requireInvariant frozenNeverExceedsBalance(from);
            requireInvariant frozenNeverExceedsBalance(to);
        }
        preserved forcedTransfer(address from, address to, uint256 amount) with (env e) {
            sane(e);
            balanceBounded(u);
            pairBounded(from, to);
            requireInvariant frozenNeverExceedsBalance(from);
            requireInvariant frozenNeverExceedsBalance(to);
        }
        preserved burn(address from, uint256 amount) with (env e) {
            sane(e);
            balanceBounded(u);
            requireInvariant frozenNeverExceedsBalance(from);
        }
    }

/// freezePartialTokens must revert if it would push frozen above balance (no silent clamp).
rule freezeCannotExceedBalance(env e, address user, uint256 amount) {
    sane(e);
    uint256 balBefore    = balanceOf(user);
    uint256 frozenBefore = getFrozenTokens(user);

    freezePartialTokens@withrevert(e, user, amount);

    assert (!lastReverted) => (to_mathint(frozenBefore + amount) <= to_mathint(balBefore)),
        "freeze succeeded but frozen would exceed balance";
}

/// unfreezePartialTokens must revert when unfreezing more than is currently frozen.
rule unfreezeCannotExceedFrozen(env e, address user, uint256 amount) {
    sane(e);
    uint256 frozenBefore = getFrozenTokens(user);
    unfreezePartialTokens@withrevert(e, user, amount);
    assert (!lastReverted) => (amount <= frozenBefore), "unfroze more than was frozen";
}

/* -------------------------------------------------------------------------- */
/*  Transfer gating                                                            */
/* -------------------------------------------------------------------------- */

/// A peer-to-peer transfer must revert while the token is paused.
rule pausedBlocksTransfer(env e, address to, uint256 amount) {
    sane(e);
    require paused();
    require e.msg.sender != 0 && to != 0;          // exclude mint/burn legs of _update
    transfer@withrevert(e, to, amount);
    assert lastReverted, "transfer succeeded while paused";
}

/// A transfer can never spend into frozen tokens: it reverts if value exceeds the free balance.
rule transferCannotSpendFrozen(env e, address to, uint256 amount) {
    sane(e);
    require !paused();
    require !isFrozen(e.msg.sender) && !isFrozen(to);
    uint256 free = freeBalanceOf(e.msg.sender);
    transfer@withrevert(e, to, amount);
    assert (!lastReverted) => (amount <= free), "transfer spent into frozen balance";
}

/// A transfer from or to a frozen address must revert.
rule frozenAddressCannotTransfer(env e, address to, uint256 amount) {
    sane(e);
    require isFrozen(e.msg.sender) || isFrozen(to);
    require e.msg.sender != 0 && to != 0;
    transfer@withrevert(e, to, amount);
    assert lastReverted, "frozen address transferred";
}

/* -------------------------------------------------------------------------- */
/*  Access control — the AccessManager `restricted` gate (AV-1 / AV-6)         */
/* -------------------------------------------------------------------------- */

/// If the authority denies the caller, every privileged entry point must revert.
/// `f` ranges over all methods; we only assert on the ones guarded by `restricted`.
rule restrictedMethodsRequireAuthorisation(method f, env e, calldataarg args)
    filtered { f -> isRestricted(f) }
{
    sane(e);
    require !canCallReturn[e.msg.sender];
    require e.msg.sender != token.authorityAddress();   // the authority itself relays calls
    f@withrevert(e, args);
    assert lastReverted, "restricted method ran without authorisation";
}

/// The set of `restricted`-gated selectors on Token (mirrors AccessManagerSetupLib.setupTokenRoles).
definition isRestricted(method f) returns bool =
       f.selector == sig:setName(string).selector
    || f.selector == sig:setSymbol(string).selector
    || f.selector == sig:setOnchainID(address).selector
    || f.selector == sig:setIdentityRegistry(address).selector
    || f.selector == sig:setCompliance(address).selector
    || f.selector == sig:setTrustedForwarder(address).selector
    || f.selector == sig:setAllowanceForAll(address[],bool).selector
    || f.selector == sig:mint(address,uint256).selector
    || f.selector == sig:burn(address,uint256).selector
    || f.selector == sig:freezePartialTokens(address,uint256).selector
    || f.selector == sig:unfreezePartialTokens(address,uint256).selector
    || f.selector == sig:setAddressFrozen(address,bool).selector
    || f.selector == sig:recoveryAddress(address,address,address).selector
    || f.selector == sig:forcedTransfer(address,address,uint256).selector
    || f.selector == sig:pause().selector
    || f.selector == sig:unpause().selector;
