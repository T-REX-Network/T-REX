/*
 * Certora CVL spec for IdentityRegistry (verified through IdentityRegistryHarness).
 *
 * Properties:
 *   - when eligibility checks are disabled, isVerified is unconditionally true (IR-1, AV-5);
 *   - the enable/disable toggle is well-formed: disable requires enabled, enable requires disabled (IR-2);
 *   - the `restricted` administration surface requires AccessManager authorisation (IR-3, AV-1).
 *
 * The downstream registries (claim topics, trusted issuers, identity storage) and the AccessManager are
 * summarised; `checksDisabled` is real state read through the harness.
 *
 * Run:  certoraRun certora/confs/IdentityRegistry.conf
 */

using IdentityRegistryHarness as ir;

ghost mapping(address => bool) canCallReturn;

function canCallGhost(address caller) returns (bool, uint32) {
    return (canCallReturn[caller], 0);
}

methods {
    function checksDisabled()      external returns (bool) envfree;
    function contains(address)     external returns (bool) envfree;

    // ----- downstream registries / identity storage: opaque -----
    function _.getClaimTopics()                            external => NONDET;
    function _.getTrustedIssuersForClaimTopic(uint256)     external => NONDET;
    function _.storedIdentity(address)                     external => NONDET;
    function _.storedInvestorCountry(address)              external => NONDET;
    function _.addIdentityToStorage(address,address,uint16) external => NONDET;
    function _.modifyStoredIdentity(address,address)       external => NONDET;
    function _.modifyStoredInvestorCountry(address,uint16) external => NONDET;
    function _.removeIdentityFromStorage(address)          external => NONDET;

    // ----- AccessManager -----
    function _.canCall(address caller, address, bytes4) external => canCallGhost(caller) expect (bool, uint32);
}

/* IR-1 (AV-5): disabling eligibility checks makes every address verified. */
rule disabledChecksImplyVerified(env e, address user) {
    require checksDisabled();
    bool verified = isVerified(e, user);
    assert verified, "isVerified must be true when checks are disabled";
}

/* IR-2: the eligibility toggle is monotone-correct — no double-disable / double-enable. */
rule disableRequiresEnabled(env e) {
    bool before = checksDisabled();
    disableEligibilityChecks@withrevert(e);
    assert (!lastReverted) => (!before), "disabled while already disabled";
    assert (!lastReverted) => checksDisabled(), "disable did not set the flag";
}
rule enableRequiresDisabled(env e) {
    bool before = checksDisabled();
    enableEligibilityChecks@withrevert(e);
    assert (!lastReverted) => before, "enabled while already enabled";
    assert (!lastReverted) => !checksDisabled(), "enable did not clear the flag";
}

/* IR-3 (AV-1): the restricted admin surface requires AccessManager authorisation. */
rule restrictedAdminRequiresAuthorisation(method f, env e, calldataarg args)
    filtered { f -> isRestricted(f) }
{
    require !canCallReturn[e.msg.sender];
    f@withrevert(e, args);
    assert lastReverted, "restricted IR method ran without authorisation";
}

definition isRestricted(method f) returns bool =
       f.selector == sig:registerIdentity(address,address,uint16).selector
    || f.selector == sig:updateIdentity(address,address).selector
    || f.selector == sig:updateCountry(address,uint16).selector
    || f.selector == sig:deleteIdentity(address).selector
    || f.selector == sig:setIdentityRegistryStorage(address).selector
    || f.selector == sig:setClaimTopicsRegistry(address).selector
    || f.selector == sig:setTrustedIssuersRegistry(address).selector
    || f.selector == sig:disableEligibilityChecks().selector
    || f.selector == sig:enableEligibilityChecks().selector;
