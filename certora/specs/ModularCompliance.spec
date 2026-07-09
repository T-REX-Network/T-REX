/*
 * Certora CVL spec for ModularCompliance (verified through ModularComplianceHarness).
 *
 * Properties:
 *   - the bound-module set is always capped at 25 (MC-1);
 *   - the transfer/mint/burn notification hooks are callable only by the bound token (MC-2);
 *   - the `restricted` administration surface requires AccessManager authorisation (MC-3, AV-1);
 *   - token (un)binding follows the owner / token-self-bind policy (MC-4).
 *
 * Module callbacks (IModule.*) and the AccessManager (`hasRole`, `canCall`) are summarised; the module set
 * itself is real state inside the EnumerableSet.
 *
 * Run:  certoraRun certora/confs/ModularCompliance.conf
 */

using ModularComplianceHarness as mc;

ghost mapping(address => bool) canCallReturn;
ghost mapping(address => bool) isOwnerReturn;

function canCallGhost(address caller) returns (bool, uint32) {
    return (canCallReturn[caller], 0);
}
function hasRoleGhost(address account) returns (bool, uint32) {
    return (isOwnerReturn[account], 0);
}

methods {
    function getTokenBound()        external returns (address) envfree;
    function isModuleBound(address) external returns (bool)    envfree;
    function isTokenBound(address)  external returns (bool)    envfree;
    function moduleCount()          external returns (uint256) envfree;

    // ----- IModule callbacks: opaque -----
    function _.moduleTransferAction(address,address,uint256) external => NONDET;
    function _.moduleMintAction(address,uint256)             external => NONDET;
    function _.moduleBurnAction(address,uint256)             external => NONDET;
    function _.moduleCheck(address,address,uint256,address)  external => ALWAYS(true);
    function _.bindCompliance(address)                       external => NONDET;
    function _.unbindCompliance(address)                     external => NONDET;
    function _.isPlugAndPlay()                               external => ALWAYS(true);
    function _.canComplianceBind(address)                    external => ALWAYS(true);

    // ----- AccessManager -----
    function _.canCall(address caller, address, bytes4)      external => canCallGhost(caller) expect (bool, uint32);
    function _.hasRole(uint64, address account)              external => hasRoleGhost(account) expect (bool, uint32);
}

/* MC-1: the module set never exceeds the hard cap of 25. */
invariant moduleSetBounded()
    moduleCount() <= 25
    { preserved { require moduleCount() <= 25; } }

/* MC-2: only the bound token may drive the compliance notification hooks. */
rule onlyBoundedTokenNotifiesTransfer(env e, address from, address to, uint256 value) {
    require e.msg.sender != getTokenBound();
    transferred@withrevert(e, from, to, value);
    assert lastReverted, "non-bound caller drove transferred()";
}
rule onlyBoundedTokenNotifiesCreated(env e, address to, uint256 value) {
    require e.msg.sender != getTokenBound();
    created@withrevert(e, to, value);
    assert lastReverted, "non-bound caller drove created()";
}
rule onlyBoundedTokenNotifiesDestroyed(env e, address from, uint256 value) {
    require e.msg.sender != getTokenBound();
    destroyed@withrevert(e, from, value);
    assert lastReverted, "non-bound caller drove destroyed()";
}

/* MC-3 (AV-1): the restricted admin surface requires AccessManager authorisation. */
rule restrictedAdminRequiresAuthorisation(method f, env e, calldataarg args)
    filtered { f -> isRestricted(f) }
{
    require !canCallReturn[e.msg.sender];
    f@withrevert(e, args);
    assert lastReverted, "restricted MC method ran without authorisation";
}

definition isRestricted(method f) returns bool =
       f.selector == sig:removeModule(address).selector
    || f.selector == sig:addAndSetModule(address,bytes[]).selector
    || f.selector == sig:addModule(address).selector
    || f.selector == sig:callModuleFunction(bytes,address).selector;

/* MC-4: bindToken is restricted to the owner, or a self-binding token while the slot is empty. */
rule bindTokenAccessControl(env e, address newToken) {
    address boundBefore = getTokenBound();
    require !isOwnerReturn[e.msg.sender];                  // caller is not the owner
    require !(boundBefore == 0 && e.msg.sender == newToken); // nor the self-bind-while-empty case
    bindToken@withrevert(e, newToken);
    assert lastReverted, "unauthorised bindToken succeeded";
}
