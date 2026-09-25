# Change Log
All notable changes to this project will be documented in this file.

## [Unreleased] - v5

### Added

- **Identity-type-aware claim requirements** (per-type claim topics with default fallback):
  - The `TREXRegistry` can hold an alternative set of required claim topics per ONCHAINID identity
    type (`IdentityTypes`: ASSET, INDIVIDUAL, CORPORATE, IOT, CLAIM_ISSUER, SMART_CONTRACT,
    PUBLIC_AUTHORITY, AI_AGENT), on top of the default ERC-3643 set managed by
    `addClaimTopic` / `removeClaimTopic` / `getClaimTopics`.
  - New OWNER-gated functions on `ITREXRegistry`: `addClaimTopicForIdentityType`,
    `removeClaimTopicForIdentityType`, and the view `getClaimTopicsForIdentityType`. Identity type 0
    is rejected, as it means "no type" and always resolves to the default topics. Each per-type set
    is capped at 15 topics, like the default set.
  - `isVerified()` resolves the investor's identity type and evaluates the topic set registered
    for that type. **Override semantics, not additive**: a
    non-empty set for a type fully replaces the default set for identities of that type; a type that
    should require the default topics plus extras must list the default topics in its set
    explicitly. Adding a topic to the default set later does not reach types holding an override.
  - The identity type is read from the ONCHAINID IdentityFactory's creation-time record
    (`identityTypeOf`), never from the identity contract itself: the record is written once at
    minting with no update path, so a hostile identity can neither lie about its type nor block
    resolution by reverting. The factory is a constructor immutable of the registry implementation
    (exposed via `identityFactory()`), so repointing it takes a new implementation published
    through the beacon rather than a runtime call.
  - Default fallback always applies: type 0 (including identities the factory did not mint) or a
    type without a configured set is evaluated against the default ERC-3643 claim topics. A
    deployment that never touches the new functions behaves exactly as before.
  - `UtilityChecker.getVerifiedDetails` resolves the same per-type topics, so its diagnostics match
    `isVerified`.
  - New events: `ClaimTopicAddedForIdentityType`, `ClaimTopicRemovedForIdentityType`. New custom
    error: `InvalidIdentityType`.
- **Compliance ledger and typed modules** (#81, PR #83): the compliance keeps the numbers every
  distribution rule needs, once, and a module is one of three kinds.
  - `IComplianceLedger` on `ModularCompliance`: `positionOf(identity)` (free, frozen and bridged over
    every linked wallet), `pendingInOf(identity)` and `pendingOutOf(identity)` (what open validations
    promise to and from it, at `amountMax`), `pendingOutOfWallet(walletKey)` (what open validations may
    still draw from one satellite wallet). Written from the hooks the token already calls and from the
    issuance, settlement and discard paths; nothing outside the compliance writes them. A movement
    between two wallets of one identity changes none of them. Own ERC-7201 namespace
    `erc3643.storage.ComplianceLedger`.
  - The compliance follows its token from the first mint. Moving a token that already has holders onto
    a new compliance is not supported: the new compliance would start every position at zero. A
    circulating token's compliance is upgraded in place, never replaced.
  - `PositionUnresolved(wallet, amount)` and `PositionUnderflow(identity, missing)` report a movement
    whose wallet resolves to no identity, or a debit past what the identity held; neither reverts.
  - `IModule.moduleTypes()` returns the `ModuleType`s a module is (`RULE`, `SPENDER`, `TRACKER`),
    read once at binding. `ModularCompliance` keeps one list per type and dispatches to it only:
    `RULE` answers `allowedAmount(ctx)`, the largest amount it allows, and the compliance keeps the
    smallest answer (`type(uint256).max` is no limit, 0 is refused; the rule must be monotonic);
    `SPENDER` answers `moduleCheckSpender`, all must agree; `TRACKER` is told `afterTransfer(ctx)` after
    the positions moved. One action, not three: a mint is a movement with a zero sender side and a burn one
    with a zero recipient side, the convention `allowedAmount` already used, so the tracker sorts them
    itself and the compliance keeps one dispatch loop.
  - `IModule.TransferContext`: the compliance asking, both identities resolved once, both wallet keys,
    `amountMin` / `amountMax`, `isIssuance` and `spender`. Every rule, spender policy and tracker receives
    it, built in one place, so a module never resolves a wallet itself. On an action `amountMax` is the
    exact amount that moved, so there is no second amount beside it.
  - A recipient that resolves to no identity is refused while a `RULE` is bound: a distribution rule keys
    on the identity and would read a zero one as a burn, letting tokens land beyond every cap. Only a
    registry with eligibility checks disabled reaches that path.
  - `resyncModuleTypes(address)` re-reads a bound module's declaration after an implementation
    upgrade, OWNER. `getModulesByType(ModuleType)` lists the modules of one kind.
    `ModuleTypesRecorded(module, moduleTypes)` on bind and resync. `ModuleHasNoType` and
    `DuplicateModuleType` refuse a declaration the compliance cannot route.
  - `MaxBalancePerIdentityModule`: the first rule over the ledger, a cap per identity over every
    wallet and every chain, plug and play, one function for a native transfer, an issuance, two
    validations racing for the same cap and a late reconciliation.
  - `UtilityChecker.getTransferDetails` reports each `RULE` module's `allowedAmount` next to the
    pass verdict (`ComplianceCheckDetails.allowedAmount`).
  - `docs/compliance-modules.md` is the one-page guide to writing a module.
- **Spender compliance check**: `IModule.moduleCheckSpender(ctx)` and
  `IModularCompliance.canSpenderCall(...)`, with AND semantics across the modules naming
  `SPENDER`. The spender travels in `TransferContext.spender` as an ERC-7930 envelope, so one policy
  covers the caller of `transferFrom` and the operator a validation names on a satellite.
  `SpenderVerificationModule` asks `isWalletVerified` on it; `SpenderWhitelistModule` lists wallets by
  canonical key (`allowSpender(bytes)`, `disallowSpender(bytes)`, `isSpenderAllowed(compliance, bytes)`,
  `SpenderAllowed` / `SpenderDisallowed` carry the key and the envelope, `SpenderAlreadyAllowed` and
  `SpenderNotListed` take the envelope). The context is only built, and the wallets resolved, when a
  `SPENDER` module is bound.
  - `Token.transferFrom` consults it before spending the allowance and reverts
    `SpenderNotAllowed(address spender, address from, address to, uint256 value)` when a module
    refuses the caller — the whole call is reported, since a module may accept a spender in general
    and still refuse the specific transfer. A refused call leaves the allowance and the balances
    untouched.
  - Only `transferFrom` is concerned. A direct `transfer` has no spender to vet and pays nothing for
    the check; `mint`, `burn` and `forcedTransfer` stay gated by roles alone, since agent
    permissioning is not investor-facing compliance.
  - A deployment binding no `SPENDER` module is unaffected: the check returns true across an
    empty set.
- **Role domains** (OZ H-02, #55): role ids on a shared AccessManager were one set for every
  suite, so an `AGENT_MINTER` of token A satisfied token B's `mint` as well.
  - A role id is a domain id in the upper 32 bits and a role number below:
    `RolesLib.forDomain(domainId, role)`. The standard roles are the `RolesLib.Role` enum; the
    plain `uint64` constants are gone and an enum value cannot be passed to `grantRole` by accident, so
    no unscoped role is reachable by omission. `forDomain(domainId, bytes32 customName)` derives
    a custom role by hashing the name into the upper half of the role number, so `RolesLib.decode`
    tells standard from custom without a lookup. Role numbers start at `ROLE_NUMBER_OFFSET` (1).
    Domain 0 is rejected (`InvalidDomain`) and the platform domain holds three roles only,
    so neither OpenZeppelin sentinel is reachable. Ids are reversible: tooling reads `domainId = id >> 32` off
    `RoleGranted` events, no labels pass needed.
  - The interop roles from the ERC-7786 work map onto the same scheme: `COMPLIANCE_MANAGER` (under
    `SUITE_ADMIN`) and `VALIDATION_KEEPER` (under `AGENT_ADMIN`) are suite roles in `RolesLib.Role`,
    `INTEROP_MANAGER` is a platform role, and `setupTrustedGatewayRegistryRoles` takes no domain.
  - Platform roles, the factory `OWNER`, `VERSION_MANAGER`, `ASSET_DEPLOYER` and `INTEROP_MANAGER`, are
    the `RolesLib.PlatformRole` enum in the reserved `PLATFORM_DOMAIN` (`type(uint32).max`),
    derived with `RolesLib.platform(role)`. `forDomain` rejects that domain, so no suite role
    can land on a platform id. They are governance roles, not issuer roles, so
    `setupTREXFactoryRoles`, `setupTREXImplementationAuthorityRoles` and `setupIdentityFactoryPolicy`
    take no domain.
  - A domain is an issuer, or a fund: one team across every token in it. Two tokens in one
    domain share their agents; two domains are isolated from each other.
  - Storage writes (`addIdentityToStorage`, `modifyStoredIdentity`, `removeIdentityFromStorage`) are
    gated by `IRS_WRITER`, which only registries hold. `IRS_WRITER` stays under `ADMIN_ROLE`, no
    domain administrator can hand it out, so this holds by construction. Agents edit investor
    records through a registry, never directly, and a storage shared across domains gives the other
    domain's agents nothing.
    Binding stays `IRS_BINDER` and unbinding `OWNER`, both in the storage's domain: whoever owns the
    storage's domain owns its bindings.
  - `TREXAccessManager` keeps the registry, in its own ERC-7201 slot: `createDomain(name)` returns
    the next id, `assign(domainId, target)` records the domain of a token or a storage,
    `domainOf(target)`, `domainName(id)` and `domainCount()` read it back. Both writers use
    OpenZeppelin's `onlyAuthorized`: on the manager itself an unmapped selector resolves to
    `ADMIN_ROLE`, so they are admin-only by default, honour the admin's execution delay, compose with
    `schedule` and `execute`, show up in `getTargetFunctionRole(manager, selector)`, and can be
    delegated to another role with `setTargetFunctionRole` on the manager itself. No OpenZeppelin
    internal is overridden. Events `DomainCreated` and
    `DomainAssigned`. `IdentityRegistryStorage.isIdentityRegistryBound(registry)` is a new O(1) view
    on the T-REX storage, used by commissioning to skip an already bound registry.
     `domainOf` is a registry, not the authorization boundary: authorization is the
    role id on each selector and the grants behind it, and the manager never consults `domainOf`.
    Commissioning and migration keep the two in step; `assign` alone records the domain, rewrites no
    selector mapping and revokes nothing. Moving commissioned tokens to other domains is
    `moveSuitesToDomains(TREXAccessManager, …)`, which assigns the tokens and then runs
    `migrateSuitesToDomains`: remap the suites, grant the new domains' roles, revoke the old domain's
    `AGENT`, all in one call. The `IAccessManager` form does the same without the assignment. Re-running `commissionSuite` after a bare reassignment
    remaps but leaves the old grant in place.
  - Two tiers. `AccessManagerSetupLib.commissionSuite(manager, token)` reads `domainOf(token)` and
    needs a `TREXAccessManager` (`NotAssigned` if the token is not assigned); it assigns the storage to
    the token's domain on first use and keeps a storage already assigned where it is, so a storage
    reused across domains keeps one owner and every registry bound to it writes with that
    domain's `IRS_WRITER`. `commissionSuite(manager, token, domainId, storageDomainId)` is
    the pure form and works on any `IAccessManager`: the storage's domain is explicit, so a storage
    already shared with another domain is passed with the domain it lives in and is not
    remapped. Every other suite `setup*` function takes a `domainId` and is pure. Commissioning is
    idempotent: re-running re-applies the standard tables. Commissioning needs `ADMIN_ROLE`: it maps
    selectors and grants `IRS_WRITER` to the registry, and attaching a registry to a storage is a
    governance act. A second suite into a domain already administered also needs `AGENT_ADMIN` there
    for the token's `AGENT` grant; binding to a mapped storage needs `IRS_BINDER` in the storage's
    domain.
  - The library keeps no state of its own and validates no preconditions: no markers, no
    "already configured" checks, no migration preflight. Which suites were configured alike is the
    operator's record.
  - `migrateSuitesToDomains(manager, tokens, fromDomainId, toDomainIds, assignments,
    revocations)` moves suites from one domain into others in one call: grant the new roles, map
    the domains, revoke the old ones. `RoleAssignment(account, role, domainId)` grants the role
    in the new domain to an account that holds it in the source one, same execution delay
    (`RoleNotHeld`, `PendingRoleGrant`, `PendingDelayChange` otherwise); `RoleRevocation(account,
    role)` revokes it in the source domain, administrative roles last. Storages are not touched. On
    a `TREXAccessManager`, `assign` the tokens to their new domains as well. Atomicity is the
    caller's: run it from one transaction, a script broadcasts it as many.
- **Upgradeable suite AccessManager** (OZ M-10): `TREXAccessManager` is OpenZeppelin's
  `AccessManagerUpgradeable` behind a beacon proxy, published and upgraded through
  `TREXImplementationAuthority` like the four suite contracts. The manager's address never changes,
  so the token identity's MANAGEMENT key, every `authority()` and all role state survive an upgrade.
  Key rotation is role rotation inside the manager. Replacing the manager is not supported; the
  ERC-173 `transferOwnership` shim forwards to `setAuthority` and does not move the identity key.
  - `deployTREXSuite` with `TokenDetails.accessManager == address(0)` deploys a manager under the
    suite salt, creates a domain named after the token, assigns the token and its storage to it,
    commissions the suite, grants `ADMIN_ROLE` to `TokenDetails.accessManagerAdmin` and renounces its
    own. The admin must be a real external account (`InvalidAccessManagerAdmin`); a
    supplied manager must have code (`AccessManagerNotAContract`); a reused storage must already
    report the suite manager as its authority (`StorageAuthorityMismatch`).
  - `deployTREXSuiteIsolated` clones the manager beacon too, owned by `accessManagerAdmin` so a broken
    manager can be repaired from outside. Rotating that administrator is two steps: `ADMIN_ROLE` in
    the manager and `transferOwnership` on the beacon.
  - Trust statement: the shared manager beacon is owned by `TREXImplementationAuthority`, so
    `VERSION_MANAGER` can replace the code behind every factory-deployed manager on it. Issuers who do
    not accept that use `deployTREXSuiteIsolated` or supply their own manager.
  - Breaking: `TokenDetails` gains `accessManagerAdmin`, `SuiteImplementations` and `SuiteBeacons`
    gain a fifth entry, `TREXImplementationAuthority` requires a manager implementation. ABI changes
    on `deployTREXSuite`, `deployTREXSuiteIsolated`, `publish`, `publishAndUpgrade`, `beacons`,
    `implementations`, `implementationsFor` and the `BeaconsDeployed`, `VersionPublished`,
    `SuiteUpgraded`, `IsolatedSuiteDeployed` events.
- **The factory no longer writes into a supplied AccessManager** (OZ Critical, #77; closes M-05):
  `TokenDetails.irAgents` and `tokenAgents` are gone, a deploy against a supplied manager makes no
  call into it, and a reused storage is no longer bound by the factory. Before, any factory `OWNER`
  could name another issuer's manager and receive `AGENT` there through the factory's `AGENT_ADMIN`
  grant. Now the issuer commissions the suite on their own manager with `commissionSuite` and grants
  agent roles themselves. A deploy naming a foreign manager is not rejected: it changes nothing on that
  manager. `MaxAgentsReached` is removed.
  - Rollout: this stops new grants. It does not revoke `AGENT_ADMIN` that issuers granted to earlier
    factories on their managers; revoke it on every manager that holds it.
- **Module removal never depends on the module** (OZ M-11, L-13): a module upgraded to revert
  everywhere can no longer hold the token hostage.
  - `removeModule` is unchanged and strict: it deletes the entry, then calls `unbindCompliance` and
    reverts if that call fails for any reason, a module revert or a caller who starved the subcall of
    gas alike. A best-effort call was considered and rejected: with the 63/64 gas rule any caller can
    make the subcall fail while the outer call succeeds, so a tolerant path would let anyone skip a
    healthy module's unbind at will.
  - `forceRemoveModule(address)`, restricted to OWNER, deletes the entry without any call to the
    module and emits `ModuleForceRemoved(address indexed module)` and no `ModuleRemoved`, so an indexer
    can tell a forced removal from a regular one. The module keeps its own binding record, so the same
    proxy address cannot be re-added afterwards; a fresh deployment can.
  - `AbstractModuleUpgradeable.unbindCompliance` reverts `ModuleStillBound` while the calling
    compliance still lists the module, so an unbind forwarded through `callModuleFunction`, directly
    or nested in `multicall`, cannot leave the compliance routing to a module that considers itself
    unbound. Only the two removal paths unbind.
  - Deployments upgrading an existing `ModularCompliance` must register the `forceRemoveModule`
    selector for OWNER on their AccessManager; `AccessManagerSetupLib` does it for new deployments.
- **Forced transfers and recovery respect the pause** (OZ M-09): `forcedTransfer`, `batchForcedTransfer`
  and `recoveryAddress` reached `_forceUpdate` without a pause check, so a forced-transfer agent could
  move balances during an incident halt and pausing alone could not contain that agent. `_forcedTransfer`
  and `_recoveryAddress` now use `whenNotPaused`, in the ERC-3643 base and in the T-REX override, so
  single and batch forms revert with `EnforcedPause` while paused and work again after
  `unpause`. Recovery is not an exception: it moves a balance like any transfer and waits for the halt to
  be lifted.
  - Pause policy, written down: the pause halts every balance movement between wallets, native or
    satellite. Paths through `_update` (transfers) check it there; paths that bypass `_update` check it
    at their entry: `_forcedTransfer`, `_recoveryAddress`, `_handleSettlement`, and now the two ledger
    entries the compliance calls back, `settleValidation` and `holdInTransit`, so the halt holds at the
    token boundary whatever routed the settlement. Mints and burns stay allowed while paused, unchanged.
    The `_delegateOut` and `_recall` transitions have no entry point yet; the flow that lands them must
    check the pause first, and the ledger section says so.
  verified identity in the token's registry — the rule an issuer would otherwise have to hardcode.
  It declares `CHECK_SPENDER` alone, keeps no state and resolves the registry through the compliance
  on every call, so it is plug and play and binds in any order. Investors are unaffected: a direct
  `transfer` never consults it.
- **`SpenderWhitelistModule`**: per-compliance allowlist of the operators an issuer trusts to call
  `transferFrom` — marketplaces, settlement contracts, custodians, none of which eligibility can
  describe. `allowSpender` / `disallowSpender` run through `callModuleFunction` and revert
  `SpenderAlreadyAllowed` / `SpenderNotListed` on a redundant call. **Default closed**: a freshly
  bound module blocks every `transferFrom` until an operator is listed, so bind it with
  `addAndSetModule` to list several at once. Entries are scoped by the bind nonce, so an unbind
  discards the list rather than resurrecting it on rebind.
- **ERC-7786 messaging endpoint**: the T-REX side of the interop boundary, developed and tested
  against a mocked gateway so production adapters plug in later behind the same interface.
  - `TrustedGatewayRegistry`: the network's vetted gateway set, a non-upgradeable singleton gated by
    the new `INTEROP_MANAGER` role. Tokens re-read it on every send and receive, so
    `setTrustedGateway(gateway, false)` severs every route through that gateway with no further call.
  - `TREXMessaging`, inherited by `Token`: issuer-managed routes and peers, in their own ERC-7201
    namespace. `setRoute(chainType, chainReference, gateway)` opens a chain through a registry-trusted
    gateway (zero closes it) and records the ERC-7930 prefix behind `chainKey`, which is what lets
    the peer default to the token's own address on an EVM chain; `setPeer(chainKey, peer)` registers a
    Lite elsewhere, refusing a padded envelope or one on another chain. Both sit with the
    `IDENTITY_MANAGER` role. `isChainOpen`, `routeFor`, `peerFor`, `chainOf` and `pinnedRouteFor`
    expose the state.
  - **Single author per side.** The bound compliance dispatches validations through
    `Token.dispatchComplianceValidation(chainKey, validationId, body)` with no role of its own;
    `dispatchMintInstruction` is the agent's fire-and-forget delegation-out. Inbound, the token proves
    the gateway is trusted, is the one it expects for that message, and that the ERC-7930 author is its
    peer on the origin chain, then forwards a settlement to `ISettlementHandler.handleSettlement` on
    the compliance and a burn proof to its own recall path. `ModularCompliance` implements the handler,
    callable by the bound token only; classifying the notification is the slot lifecycle's work.
  - **Routes are snapshot at dispatch.** Each validation leg pins the gateway it went out through,
    per `(validationId, chainKey)`, announced by `ValidationRoutePinned`. Its settlements from that
    chain are accepted from the pinned gateway and no other, so a route switch affects new validations
    only; a re-dispatch through the pinned gateway is allowed, through another one refused with
    `ValidationAlreadyRouted`. An id the token never dispatched, and every burn proof, follows the
    current route. Removing a pinned gateway from the registry orphans its legs, which the lifecycle
    will then expire and discard.
  - `MessageTypesLib`: the four message types as the enum `Message` (`COMPLIANCE_VALIDATION`,
    `MINT_INSTRUCTION`, `SETTLEMENT_NOTIFICATION`, `BURN_PROOF`) in a versioned
    `abi.encode(type, version, body)` envelope, plus the typed `SettlementNotification` and
    `BurnProof` bodies with their codecs and the `chainKey` derivation. A `chainKey` is
    `keccak256` of ERC-7930's canonical chain identifier, the interoperable address of that chain
    with a zero-length address, so a counterpart derives the same key from the standard alone.
    - **The ABI decoder enforces the range.** `decode` reads the type slot as a `Message`, so a value
      above the last member is refused before the body is looked at, and `encode` cannot be handed an
      undefined type at all. There is no `isKnownType` helper and no `UnknownMessageType` error: an
      undefined type now reverts without data, the range being the compiler's to state. A valid but
      outbound-only type arriving inbound is a different matter and still reverts
      `MessageTypeNotInbound`, which names it.
    - **Wire codes are `0..3`**, the member positions, rather than the `1..4` of the constants they
      replace. Appending a member is the only backward-compatible way to grow the surface: reordering
      or inserting one reassigns a code. Event topics and the `MessageTypeNotInbound` selector are
      unchanged, an enum canonicalising to `uint8` in the ABI.
  - Transport-level replay protection per `(gateway, receiveId)`, distinct from the semantic replay the
    slot lifecycle detects: a fresh id carrying consumed content is passed through untouched.
  - Events: `TrustedGatewaySet`, `TrustedGatewayRegistrySet`, `ChainRegistered`, `RouteSet`, `PeerSet`,
    `ValidationRoutePinned`, `ProtocolMessageSent` and `ProtocolMessageReceived` carrying the type,
    the chain key and the gateway's id, `SettlementNotified` on the compliance and `BurnProofReceived`
    on the token.
  - `ERC7786GatewayMock`, a test asset: a same-chain loopback that queues on send and delivers on an
    explicit `relay`, so ordering, duplication and loss are controllable, presenting every delivery as
    coming from its configured origin chain.
- **Balance model: free / frozen / bridged ledger.** A holder's position has three buckets. Free and
  frozen are native and `balanceOf` keeps its exact ERC-20 meaning over them; bridged is the part
  delegated to satellites, accounted per ERC-7930 wallet in a ledger of its own inside the token's
  ERC-7201 namespace, the native mapping untouched.
  - Accessors: `freeBalanceOf(wallet)`, `bridgedBalanceOf(envelope)` and `totalBridged()` on `IToken`.
    `totalSupply()` counts the whole issuance, native supply plus `totalBridged`, so a delegation or a
    recall never moves it; only a mint or a burn does.
  - **`totalSupply` reports the issuance, not the native float.** A delegation-out, a recall or a
    native-side settlement leg leaves it unmoved while emitting a native `Transfer` to or from `0x0`, which
    is what makes `balanceOf` drop visibly and keeps every ERC-20 balance indexer correct. The price: a
    consumer deriving supply by summing `Transfer` events under-reports by `totalBridged`, and reconciles on
    `DelegatedOut`, `Recalled` and `SettledToNative`. The native figure is
    `totalSupply() - totalBridged()`. An escrow address holding the delegated float would have kept
    Transfer-summing whole and was rejected: it would show the token holding its own supply. `INV-7` asserts
    the balance at the token's own address is always zero, and sums the three buckets to `totalSupply()`.
  - `WalletKeyLib`: canonical ERC-7930 parsing with the strict-length rule from the ONCHAINID M-08
    finding, refusing as well a zero-led EVM chain reference (which decodes to the same chain id);
    `canonicalKey` and `satelliteKey`, the latter refusing a wallet on this chain, which holds a native
    balance and never a bridged one.
  - Internal transitions, one per movement type, applied when the movement is final on the register:
    `_delegateOut(holder, toWallet, amount)` burns natively (`Transfer(holder, 0x0)`) and credits the
    satellite wallet; `_recall(fromWallet, holder, amount)` is its mirror; `_bridgedTransfer(from, to,
    amount, validationId)` applies a settled satellite movement, same-chain or cross-chain, in one
    atomic touch. They check buckets and envelopes only and fire no compliance hook: the calling flows
    (delegation-out, recall on burn proof, settlement) own pause, freeze, eligibility, compliance and
    the identity link, and arrive with the movement-type and settlement work.
  - Events with the full envelopes: `DelegatedOut`, `Recalled`, `BridgedTransfer` (with the
    `validationId`). Errors: `NotASatelliteWallet`, `InsufficientBridgedBalance`.
  - Invariants `INV-7` (conservation across buckets) and `INV-8` (bridged total tracks the positions)
    join the stateful suite, with `TokenLedgerHarness` exposing the transitions to tests.
- **Compliance validation object and its issuance.** A satellite executes a transfer only against a
  `ComplianceValidation` the reference chain issued for that exact transfer; `ModularCompliance` now
  issues them.
  - `MessageTypesLib.ComplianceValidation`: single-use `validationId`, ERC-7930 `from` / `to` (equal
    chains mean a same-chain transfer, different chains a burn on `from`'s and a mint on `to`'s),
    `spender` (empty means only `from` executes), inclusive `amountMin` / `amountMax`, the
    reference-chain `token` address as canonical identifier, `expiry` (the satellite's hard deadline)
    and `reconciliationWindow` (how long T-REX keeps the slot past `expiry`). With its EIP-712
    `COMPLIANCE_VALIDATION_TYPEHASH`, `hashValidation` and the `encodeValidation` / `decodeValidation`
    codec.
  - `ITransferValidation.requestTransferValidation(from, to, requestedMin, requestedMax, spender)`.
    Callable by the identity `from` is linked to, or by an `AGENT`. `from` must be a satellite wallet
    (`SenderNotOnSatellite`): the Lite executing a validation has to physically hold the position it
    moves, where a native balance stays free to leave between issuance and settlement; a native
    position reaches a satellite through delegation-out, which burns before it instructs. `from` must
    resolve to an identity (revoked included), `to` must pass `isWalletVerified`, every envelope must
    be canonical. The range is capped at `from`'s bridged position less what is already pending out of
    it, then at the smallest `allowedAmount` any `RULE` module answers (skipped when both wallets belong
    to one identity); an empty range reverts with `EmptyValidationRange`, a zero maximum with
    `ZeroValue`, and nothing is written. The record (`validationOf`) is stored for the lifecycle,
    `TransferValidationIssued` carries the full envelopes, and one leg per involved satellite chain
    leaves through `Token.dispatchComplianceValidation` under the same id. The spender is parsed and
    carried on the wire for the satellite to enforce; no rule here reads it.
  - `TREXRegistry.resolveIdentity(bytes)` and `isWalletVerified(bytes)`, backed by the registry's
    IdentityFactory: the first attributes (revoked bindings included), the second admits (active
    binding, then the same claim check as `isVerified`).
  - `COMPLIANCE_MANAGER`, administered by `SUITE_ADMIN`, over `setDefaultValidityWindow`,
    `setReconciliationWindow(chainKey, duration)` and `setIssuancePaused(chainKey, paused)`. Windows are
    snapshot at issuance; a cross-chain validation takes the larger of its two chains' windows;
    issuance refuses to run without them (`ValidityWindowNotSet`, `ReconciliationWindowNotSet`).
  - Late-reconciliation surface: `LateReconciliation(validationId, chainKey)` on every late leg, and
    an automatic pause of that chain only when the recorded state breaches a rule, lifted by the
    manager only. Recording the late settlement and judging the breach belong to the slot lifecycle.
  - Storage in `ERC3643.storage.TransferValidation`, a namespace of its own on the compliance. Events:
    `TransferValidationIssued`, `DefaultValidityWindowSet`, `ReconciliationWindowSet`,
    `ValidationClampSet`, `ValidationIssuancePaused`, `ValidationIssuanceUnpaused`,
    `LateReconciliation`. Errors: `ZeroDuration`, `ValidationIssuancePaused`,
    `ValidationIssuanceNotPaused`, `ValidityWindowNotSet`, `ReconciliationWindowNotSet`,
    `InvalidRequestedRange`, `EmptyValidationRange`, `NotAuthorizedForWallet`, `UnverifiedWallet`,
    `SenderNotOnSatellite`.
  - Test assets: `BoundsModule`, `TransferValidationHarness`, `ModularComplianceBaseUnitTest`, and
    the satellite-wallet fixtures on `TREXSuiteTest`.
- **Pending reservation, settlement and discard lifecycle.** Once a validation is issued the compliance
  counts it as executed at `amountMax` for every distribution rule, so concurrent validations cannot
  jointly breach a cap; ownership hard-commits only when the settlement comes back.
  - The reservation is two writes into the ledger, `pendingIn` / `pendingOut` of the identities and
    `pendingOutOfWallet` of the sender, and involves no module. Settlement releases it and moves the
    positions at the executed amount; a discard releases it. Relocating between two wallets of one
    identity reserves nothing against the identity, only against the wallet. A rule bound after
    issuance sees the settlement through the ledger, since the position belongs to the compliance.
  - `ITransferValidation.ValidationStatus` (`Pending`, `LegConfirmed`, `Settled`, `Expired`,
    `Discarded`, `LateReconciled`) and `ValidationState` (status, the two per-leg consumption flags,
    the executed amount, the wallet the first of two legs carried), read through `statusOf` and
    `stateOf`. `Expired` is derived, never written: a stored `Pending` past `releaseAt`. Records and
    states are kept forever, since classifying an incoming notification depends on them.
    `ValidationRecord` gained `fromKey`, `toKey` and `twoLegs`.
  - Settlement classification in `handleSettlement`: the token and the wallets must be the issued ones,
    the leg must come from the chain recorded for its side, and the amount must sit inside the issued
    bounds; any mismatch reverts (`SettlementTokenMismatch`, `SettlementLegMismatch`,
    `SettlementOutOfBounds`) and leaves the message deliverable. A same-chain movement, or one with a
    native side, settles on one leg carrying both wallets. A cross-chain movement takes two legs under
    one id, the burn leg with `to` empty from the sender's chain and the mint leg with `from` empty from
    the recipient's chain: the first to arrive, whichever it is, pins the validation as `LegConfirmed`
    (`ValidationLegConfirmed`), the second must repeat its amount (`SettlementAmountMismatch`) and
    settles the pair. A first burn leg also takes the burned amount out of the sender's position into
    transit on the token (`IToken.holdInTransit`, `HeldInTransit`), timely or late, so nothing can be
    issued or recalled against tokens the satellite already burned; a first mint leg moves nothing and
    the pair is applied atomically when the burn leg lands. A leg for a `Pending` validation settles
    whatever the clock says.
  - `IToken.settleValidation(from, to, amount, validationId)`: the ledger entry, callable by the bound
    compliance only (`OnlyBoundCompliance`), routing by wallet shape to a native credit (native
    recipient, `SettledToNative`) or a bridged transfer. Both debit a satellite position, `from` never
    being a native wallet, and both carry the `validationId`, where `DelegatedOut` and `Recalled` move
    one identity's own position between two locations. A bridged transfer under an id that holds an
    amount in transit credits the recipient from the hold, which must be the settled amount exactly
    (`TransitAmountMismatch`), instead of debiting the sender again.
  - `IToken.holdInTransit(from, amount, validationId)`, `inTransitOf(validationId)` and
    `totalInTransit()`: the in-transit bucket inside the bridged one. A hold debits the sender's
    position, leaves `totalBridged` and `totalSupply` untouched, and is taken once per validation
    (`TransitAlreadyHeld`). The sender named by the validation still owns the amount.
  - `VALIDATION_KEEPER`, administered by `AGENT_ADMIN`, over
    `discardExpiredValidations(uint256[])`: each id must be stored `Pending` and past `releaseAt`
    (`UnknownValidation`, `ValidationNotDiscardable`, `ValidationNotReleasable`); the batch is atomic.
    A discard releases the slots and emits `ValidationDiscarded`; `LegConfirmed` is never discardable.
    The role is restricted by design: `RolesLib` names the discard front-running vector a permissionless
    keeper would open, against the liveness dependency a restricted one carries.
  - Late reconciliation: a leg for a `Discarded` validation is applied anyway, the status becomes
    `LateReconciled` and `LateReconciliation` fires. Issuance for that chain pauses only when the
    executed amount is above the smallest `allowedAmount` the rules answer once the reservation is
    released, forcing a late delivery being cheap enough that pausing on every one would be a denial
    of service. A late first leg of two consults no rule, so it stays `Discarded` with its flag set and
    only warns for its own chain.
  - Emergencies: a leg already consumed, or an id never issued, applies nothing, emits
    `ReplayedSettlement` and halts the whole token through its pause (`handleSettlement` returns
    `haltToken`); only `AGENT_PAUSER` lifts it through `unpause`. While the token is paused every
    settlement delivery reverts with `EnforcedPause` and stays deliverable.
  - Events: `ValidationLegConfirmed`, `ValidationSettled`, `ValidationDiscarded`, `ReplayedSettlement`,
    `HeldInTransit`. Errors: `OnlyBoundCompliance`, `UnknownValidation`, `ValidationNotDiscardable`,
    `ValidationNotReleasable`, `SettlementTokenMismatch`, `SettlementLegMismatch`,
    `SettlementOutOfBounds`, `SettlementAmountMismatch`, `TransitAlreadyHeld`, `TransitAmountMismatch`.
  - Test assets: `CappedRecipientModule` (a cap over the ledger), the settlement-leg builders on
    `InteropSuiteTest`, and `ComplianceLedger.invariants.t.sol`, which holds the four ledger numbers
    to a recount of the token's buckets under fuzzed mints, burns, transfers, issuances, settlements
    and discards.
- **`TREXRegistry`**: one eligibility registry replacing `IdentityRegistry`, `TrustedIssuersRegistry`
  and `ClaimTopicsRegistry`. Registered identities, trusted issuers and required claim topics share a
  single namespaced storage, so `isVerified` resolves the rule set without a cross-contract hop.
  - `ITREXRegistry` inherits `IERC3643IdentityRegistry`, `IERC3643TrustedIssuersRegistry` and
    `IERC3643ClaimTopicsRegistry`; `supportsInterface` answers for all four ids. An integration
    holding an `IERC3643IdentityRegistry` reference keeps working against the merged address.
  - `issuersRegistry()` and `topicsRegistry()` return `address(this)`, so code that hops from the
    identity registry to the other two lands back on the same contract.
  - A suite deploys one registry proxy instead of three. Claim topics and trusted issuers are seeded
    through the initializer called atomically at deployment, so the factory never needs an OWNER role
    on the registry it just deployed.
- Per-token opt-out is deploy-time only, via `TREXFactory.deployTREXSuiteIsolated(...)`, which clones
  the four beacons under the issuer's own AccessManager so later `publish` / `upgrade` calls on the
  shared authority never reach that suite.
- **Indexer events**: two events in `EventsLib` and one extra emit, so the graph can read state that
  was in no log. A value another log of the same transaction already carries is not repeated.
  - `InvestorIdentityChanged(address indexed investor)`, emitted by
    `IdentityRegistryStorage.modifyStoredIdentity` right after the standard
    `IdentityModified(oldIdentity, newIdentity)`, which names the identities but not the wallet.
  - `ForcedTransfer(address indexed agent)`, emitted as the very next log after the standard
    `Transfer` of every `forcedTransfer` / `batchForcedTransfer` item, before the compliance hook so
    no module log can land between the two. A forced transfer was indistinguishable from a regular
    one in the logs and the agent (`_msgSender()`) appeared nowhere.
  - `IdentityRegistryStorage.addIdentityToStorage` now emits the standard
    `CountryModified(investor, country)` after `IdentityStored`; before, only
    `modifyStoredInvestorCountry` did, so the country given at registration was in no log.

### Changed

- **A revoked wallet is no longer verified when registered locally** (#69). `isVerified` (and the
  same-chain path of `isWalletVerified`) returned true for a wallet the ONCHAINID IdentityFactory had
  revoked whenever that wallet held a local entry in the `IdentityRegistryStorage`, while the same
  wallet resolved through the factory fallback returned false: the fallback asks `getIdentity`, which
  only answers active bindings, but a local entry is a plain mapping and knew nothing of revocation.
  `ERC3643IdentityRegistry` now reads the identity behind `isVerified` through a new
  `_activeIdentityOf` hook, which defaults to `_identityOf`; `TREXRegistry` overrides it to return the
  zero identity when the factory reports the wallet as `Revoked`. The attribution reads are untouched:
  `storedIdentity`, `contains`, `identity` and `resolveIdentity` keep answering for a revoked wallet,
  so recovery (which relies on `contains(lostWallet)`) and position attribution still work. A locally
  registered wallet the factory never linked is unaffected; only the `Revoked` status denies.
- **`recoveryAddress` now notifies compliance**: recovery moves the balance through `_forceUpdate`,
  which skips `_update` and therefore its compliance hooks, so `Token.recoveryAddress` now calls
  `compliance.transferred(lostWallet, newWallet, investorTokens)` after the balance / frozen /
  address-frozen migrations and before `RecoverySuccess`, the same way `forcedTransfer` does. The
  identity migration is split around that hook: the new wallet is registered before the move and the
  lost wallet's entry is deleted only after compliance has been notified, so that during the hook both
  wallets still resolve to the identities that hold and receive the tokens. A module keying its state by
  identity can therefore debit and credit through the registry; had the lost wallet been deleted first,
  it would have resolved to the zero identity (or to a shadowed global one) and the debit would have
  been lost (#70). In `ERC3643Token`, `_migrateIdentity` is replaced by `_registerRecoveredWallet`,
  which performs the registration and returns whether the lost wallet must be deleted. Previously
  (v4 behaviour) a recovery was invisible to bound modules: a module tracking balances through the
  `transferred` / `created` / `destroyed` callbacks kept crediting the lost wallet, and since the lost
  wallet is removed from the identity registry by the same call, the drift could not be corrected
  afterwards. Modules that count transfer operations rather than track balances now see a recovery as
  one transfer.
- **ONCHAINID dependency synced** to the latest develop (audit fixes and the factory identity-type
  record). Breaking ripples absorbed here: `Structs.ClaimData` gained `metadataHash` (binds scheme
  and uri to the claim signature), `createIdentityFor` no longer takes a module bundle (modules are
  registered per identity type on the IdentityFactory via `setIdentityTypeModules`), and
  `setIdentityTypePolicy` gained a `singleBinding` flag (ASSET registers as single-binding).
- **`TREXFactory` module plumbing removed**: identity module configuration now belongs to the
  ONCHAINID IdentityFactory, so `setIdentityModules` / `getIdentityModules`, the constructor's
  module parameters, the `IdentityModulesSet` event and the `IdentityModulesLib` library are gone.
  Token OIDs mint with the per-type bundle the IdentityFactory holds for ASSET.

- **Breaking, registries merged**: `IdentityRegistry`, `TrustedIssuersRegistry` and
  `ClaimTopicsRegistry` are gone, together with `IIdentityRegistry`, `ITrustedIssuersRegistry`,
  `IClaimTopicsRegistry` and their proxies.
- **Breaking, `ITREXImplementationAuthority`**: `SuiteImplementations` replaces `ctrImplementation`,
  `irImplementation` and `tirImplementation` with a single `trexRegistryImplementation`. A version is
  complete with four implementations instead of six.
- **Breaking, `TREXSuiteDeployed`**: now `(address indexed token, address registry, address irs,
  address mc, string salt)`. The `tir` and `ctr` addresses are gone and `registry` is the merged
  registry.
- Suite contracts are now stock OZ `BeaconProxy` instances pointing at four per-type
  `UpgradeableBeacon`s: Token, TREXRegistry, IdentityRegistryStorage and ModularCompliance. The beacon
  address lives at the standard ERC-1967 beacon slot.
- `TREXImplementationAuthority` owns the four beacons and is the single upgrade entry point.
  `publish(version, implementations)` archives a version without touching a beacon; `upgrade(version)`
  rotates all four in one transaction; `publishAndUpgrade(...)` does both. All three are gated by the
  new `VERSION_MANAGER` role rather than `OWNER`.
- A version is a packed `uint24` (`major << 16 | minor << 8 | patch`) rather than a
  `(uint8, uint8, uint8)` tuple, exposed as the `Version` user-defined value type in
  `contracts/libraries/VersionLib.sol`. This changes the selectors of `publish`, `upgrade`,
  `publishAndUpgrade`, `implementationsFor` and `currentVersion`, and the payloads of
  the `VersionPublished` and `SuiteUpgraded` events.
- `upgrade(version)` only moves forward: the target must rank above the active version, comparing major
  then minor then patch, and otherwise reverts with `VersionNotNewer()`. Rolling a beacon back onto an
  older implementation is no longer possible; recovery is a forward publish.
- `setClaimTopicsRegistry` and `setTrustedIssuersRegistry` stay for ERC-3643 conformance but revert
  `Deprecated()`: the registry is its own topics and issuers registry and cannot point elsewhere.
- `getTrustedIssuerClaimTopics` returns an empty array for an unregistered issuer instead of
  reverting, and `TrustedIssuerDoesNotExist` is removed. `updateIssuerClaimTopics` still rejects an
  empty set, so stripping an issuer of every topic means `removeTrustedIssuer`.
- `batchRegisterIdentity` is `restricted` and bound to AGENT. No role was bound to its selector
  before, so the AccessManager fell back to admin-only on a function meant for agents.
- **Breaking, `IModule`**: `moduleTypes()` replaces `moduleCapabilities()`, `allowedAmount(ctx)`
  replaces `moduleCheck` and `validationBounds`, and one `afterTransfer(ctx)` replaces
  `moduleTransferAction`, `moduleMintAction` and `moduleBurnAction`.
  `reserveSlot`, `commitSlot` and `releaseSlot` are gone: the reservation lives in the ledger.
  `AbstractModuleUpgradeable` ships the neutral default for every question, so a module implements
  only what it enforces. What a module names is read at binding; an upgrade that changes it needs
  `resyncModuleTypes` on every bound compliance.
- **Breaking, `ITransferValidation`**: `Validation` replaces `ValidationRecord` and `ValidationState`,
  read through `validationOf` alone (`stateOf` is gone); it carries the identities resolved at
  issuance and the two reservation flags. `setIssuancePaused(chainKey, paused)`, idempotent, replaces
  `pauseValidationIssuance` / `unpauseValidationIssuance` (`ValidationIssuanceNotPaused` is gone).
  `setValidationClamp` and `validationClamp` are gone: a ceiling on what may be issued is a rule, not
  a setting. A validation that names a spender is refused when a `SPENDER` module objects
  (`ValidationSpenderRefused`): no module runs on the satellite, so issuance is the only place that
  spender can be judged, as `validationBounds` allowed before.
- **Breaking, interface ids**: `type(IModule).interfaceId`, `type(IModularCompliance).interfaceId`,
  `type(ITransferValidation).interfaceId`, `type(IUtilityChecker).interfaceId` and
  `type(IComplianceLedger).interfaceId` change with the above.
- `ModularCompliance` holds its bound modules in one `EnumerableSet.AddressSet` plus one per type, so
  a dispatch is a loop over exactly the modules that answer it. Ordering follows binding order within a
  type. Binding validates fully before writing state, so `canComplianceBind` sees the module as not
  yet bound.
- Every hook now resolves both identities through the registry and writes the position, whether or
  not a rule is bound. Measured warm with no module bound: a transfer costs about 26k gas more than
  before, a burn about 37k, a mint about 14k. A rule that used to keep its own position no longer
  resolves anything, which is where the cost comes back with an identity-aware rule bound.
- **Breaking, `ModuleInteraction`**: now `(address indexed target, bytes data)` instead of
  `(address indexed target, bytes4 selector)`. `data` is the full calldata sent to the module
  through `callModuleFunction`; its first 4 bytes are the former `selector`. Only the selector was
  logged, so a module's configuration could not be rebuilt from logs. The event topic changes.

### Removed

- `ModuleCapabilitiesLib` and the capability bitmask, `refreshModuleCapabilities`,
  `getModuleCapabilities`, `getModulesByCapability`, `ModuleCapabilitiesRecorded`,
  `InvalidModuleCapabilities`, `ModuleHasNoCapabilities`; `IModule.moduleCheck`, `validationBounds`,
  `reserveSlot`, `commitSlot`, `releaseSlot`; `ITransferValidation.stateOf`, `setValidationClamp`,
  `validationClamp`, `pauseValidationIssuance`, `unpauseValidationIssuance`, `ValidationClampSet`,
  `ValidationIssuanceNotPaused`. Test fixtures `SlotsModule`, `SlotsOnlyModule`, `BoundsModule`.

- Custom `AbstractProxy` / `IProxy`-based `TREXImplementationAuthority` / `IAFactory` stack removed.
  The per-type wrapper proxies (`TokenProxy`, `IdentityRegistryStorageProxy`, `TREXRegistryProxy`,
  `ModularComplianceProxy`) and the `IProxy` / `IIAFactory` interfaces are deleted.
- Public ABI break: `setImplementationAuthority(address)` and `getImplementationAuthority()` selectors
  are removed from every suite proxy, and `changeImplementationAuthority(...)` /
  `changeImplementationAuthorityOfToken(...)` are removed from the upgrade path.

## [4.2.0]

### Added

- Introduced **Token Listing Restrictions Module**: Investors can determine which tokens they can receive by whitelisting or blacklisting them
  Token issuers can choose the listing type they prefer for their tokens:
  WHITELISTING: investors must whitelist/allow the token address in order to receive it.
  BLACKLISTING: investors can receive the token by default. If they do not want to receive it, they need to blacklist/disallow it.

- Introduced **Investor Country Cap Module**: to limit the number of identities per country.
  - The module allows the token owner to set a maximum number of identities per country.

- **Default Allowance Mechanism**:
  - Introduced a new feature allowing the contract owner to set certain addresses as trusted external smart contracts, enabling them to use `transferFrom` without requiring an explicit allowance from users. By default, users are opted in, allowing these contracts to have an "infinite allowance". Users can opt-out if they prefer to control allowances manually.
  - Added custom errors and events to provide better feedback and traceability:
    - Custom errors: `DefaultAllowanceAlreadyEnabled`, `DefaultAllowanceAlreadyDisabled`, `DefaultAllowanceAlreadySet`.
    - Events: `DefaultAllowance`, `DefaultAllowanceDisabled`, `DefaultAllowanceEnabled`.
  - Enhanced the `allowance` function to return `type(uint256).max` for addresses with default allowance enabled, unless the user has opted out.

- **Eligibility Checks Toggle**:
  - Added the ability for the token owner to enable or disable eligibility checks on the `IdentityRegistry` contract.
  - **`disableEligibilityChecks`**: Allows the token owner to disable eligibility checks, making all addresses automatically verified by the `isVerified` function.
  - **`enableEligibilityChecks`**: Allows the token owner to re-enable eligibility checks, restoring the full verification process.
  - Introduced custom errors and events:
    - Custom errors: `EligibilityChecksDisabledAlready`, `EligibilityChecksEnabledAlready`.
    - Events: `EligibilityChecksDisabled`, `EligibilityChecksEnabled`.
  - This feature provides flexibility for issuers to launch tokens with or without eligibility checks, based on their needs.

- **ERC-165 Interface Implementation**:
  - Implemented ERC-165 support across all major contracts in the suite, allowing them to explicitly declare the interfaces they support. This enhancement improves interoperability and makes it easier for external contracts and tools to interact with T-REX contracts.
  - Each contract now implements the `supportsInterface` function to identify the supported interfaces, ensuring compliance with ERC-165 standards.
  - In addition to implementing ERC-165, the ERC-3643 interfaces were organized into a new directory, with each interface inheriting from the original ERC-3643 standard interface. This setup allows for future expansion and maintains uniformity across the suite:
    - `IERC3643`, `IERC3643IdentityRegistry`, `IERC3643Compliance`, `IERC3643ClaimTopicsRegistry`, `IERC3643TrustedIssuersRegistry`, `IERC3643IdentityRegistryStorage`
  - For contracts that extend the ERC-3643 standard with new functions, `supportsInterface` now checks for both the new interface ID and the original ERC-3643 interface ID.
  - For interfaces that did not change, `supportsInterface` checks for the ERC-3643 interface ID directly, omitting the empty version-specific interface to avoid redundancy.

- **Add and Set Module in a Single Transaction**:
  - Introduced the `addAndSetModule` function in the `ModularCompliance` contract, allowing the contract owner to add a new compliance module and interact with it in a single transaction.
  - This function supports adding a module and performing up to 5 interactions with the module in one call, streamlining the setup process for compliance modules.

- **Granular Agent Permissioning**:
  - Introduced a new system to provide more granular control over agent roles on the token contract.
  - **Default Behavior**: By default, agents can perform all actions (mint, burn, freeze tokens, freeze wallets, recover tokens, pause, unpause).
  - **Restricting Permissions**: Token owners can now restrict specific roles for agents using the `setAgentRestrictions` function.
    - Permissions can be restricted on actions like minting, burning, freezing, recovering, etc.
    - Custom restrictions are stored in the `TokenRoles` struct.
    - The `AgentRestrictionsSet` event is emitted whenever restrictions are updated for an agent.
  - All agent-scoped functions (e.g., mint, burn) now check the agent’s permissions before executing the transaction, ensuring proper enforcement of these restrictions.

- **Ethers.js Version Upgrade**:
  - The project was upgraded from **Ethers v5** to **Ethers v6**, introducing several changes to the API and syntax.
  - **Key Changes**:
    - Adjusted syntax for contract deployments, interactions, and function calls to comply with Ethers v6.
    - Replaced deprecated features from v5 with the new Ethers v6 equivalents, ensuring compatibility and future-proofing the project.
    - Updated test suites and helper functions to use the Ethers v6 `Interface` and `Contract` classes, ensuring smooth testing of the updated code.
  - This upgrade ensures better performance, enhanced security, and improved developer experience moving forward.

- **Solidity Version Upgrade to 0.8.27**:
  - Upgraded Solidity version from **0.8.17** to **0.8.27** across all contracts, bringing in multiple new features and improvements:
    - **File-Level Event Declaration**: Events are now declared at the file level, simplifying code structure and improving readability.
    - **Custom Errors for Require Statements**: All `require` clauses that previously returned a string reason for failure have been updated to use **custom errors**, making debugging easier and more efficient.
  - This upgrade provides a cleaner, more efficient error handling process and improves overall code structure without affecting backward compatibility.

- **Utility checker**:
  - Add a new utility contract to check for freeze status, eligibility and compliance of an address for a token:
    - Test if the transfer of tokens will fail
    - Test the eligibility of an address for a token
    - Test the compliance of an address for a token
    - Test the freeze status of an address for a token

### Updated

- **Token Recovery Function**:
  - The `recoveryAddress` function was significantly improved to handle more complex scenarios and prevent potential bugs:
    - Removed the requirement for the `newWallet` to be a key on the `onchainID`, simplifying the process and reducing potential errors.
    - Enhanced compatibility with shared identity registry storage, ensuring the function works correctly even when multiple tokens share the same identity registry storage.
    - Added logic to handle recovery to an existing wallet that is already linked to the investor's identity, addressing scenarios where the `newWallet` is an existing wallet.
    - The function now accurately updates the identity registry, preventing errors related to attempting to add or remove identities that are already present or absent.
    - Improved overall logic to ensure smooth and error-free recovery operations, with events (`RecoverySuccess`, `TokensFrozen`, `TokensUnfrozen`, etc.) emitted to provide detailed feedback.

- **Ownership Transfer**:
  - Implemented a two-step ownership transfer process across all relevant contracts in the suite, using OpenZeppelin's implementation `Ownable2StepUpgradeable`.
  - This change enhances security by requiring the new owner to accept ownership explicitly, preventing accidental transfers to incorrect or inaccessible addresses.
  - Added new functions:
    - `transferOwnership(address newOwner)`: Initiates the ownership transfer process.
    - `acceptOwnership()`: Allows the pending owner to accept and finalize the ownership transfer.
  - Introduced a `_pendingOwner` state variable to track the address of the pending new owner.
  - Updated relevant events to reflect the two-step process:
    - `OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)`
    - `OwnershipTransferred(address indexed previousOwner, address indexed newOwner)`
  - This change affects all contracts that previously used a single-step ownership transfer, ensuring consistent and secure ownership management across the entire suite.

## [4.1.5]

### Update
- DvA Transfer Manager contract proxified
- The DvA manager contract freezes the tokens to be transferred instead of being a vault (so it must be a token agent)
- Only the token owner (rather than agents) can call setApprovalCriteria, as it is part of the main token settings.

## [4.1.4]

### Added

- Introduced **AbstractModuleUpgradeable**: Enables compliance modules to be compatible with ERC-1967 and ERC-1822 standards.
- Introduced **ModuleProxy**: ERC-1967 compliant proxy contract for Upgradeable compliance modules.

### Update
- Upgraded all compliance modules to inherit from `AbstractModuleUpgradeable` and made them Upgradeable.

## [4.1.3]

### Update

- **AbstractProxy**: updated the storage slot for `TREXImplementationAuthority` from 
  `0xc5f16f0fcc639fa48a6947836d9850f504798523bf8c9a3a87d5876cf622bcf7` to 
  `0x821f3e4d3d679f19eacc940c87acf846ea6eae24a63058ea750304437a62aafc` to avoid issues with blockchain explorers 
  confusing the proxy pattern of T-REX for an ERC-1822 proxy (old storage slot was the slot used by ERC-1822) which 
  caused errors in displaying the right ABIs for proxies using this implementation.  

## [4.1.2]
- **Compliance Modules**:
  - Removed `_compliance` parameter from `setSupplyLimit` function of the `SupplyLimitModule`

## [4.1.1]

No changes, republishing package.

## [4.1.0]

### Breaking Changes

- **TREXFactory Constructor**: Now requires the address of the Identity Factory.
  - Reason: The Identity Factory is used to deploy ONCHAINIDs for tokens.

### Added

- **Compliance Modules**:
  - Introduced `Supply Limit Module`: Restricts minting tokens beyond a specified limit.
  - Introduced `Time Transfers Limits`: Prevents holders from transferring tokens beyond a set limit within a specified timeframe.
  - Introduced `Max Balance Module`: Ensures an individual holder doesn't exceed a certain percentage of the total supply.
  - Added two exchange-specific modules:
    - `Time Exchange Limits`: Limits token transfers on trusted exchanges within a set timeframe.
    - `Monthly Exchange Limits`: Restricts the amount of tokens that can be transferred on trusted exchanges each month.
  - Introduced `Transfer Fees` : Collects fees from transfers (issuers determine fee rates).

- **IModule Enhancement**:
  - Added a new function: `function name() external pure returns (string memory _name);`. This mandates all compliance modules to declare a constant variable, e.g., `function name() public pure returns (string memory _name) { return "CountryRestrictModule"; }`.
  - New function `isPlugAndPlay`: Added to the `IModule` interface. This function, `function isPlugAndPlay() external pure returns (bool)`, indicates whether a compliance module can be bound without presetting. It is now mandatory for all compliance modules to declare this function.
  - New function `canComplianceBind`: Also added to the `IModule` interface. Compliance modules must implement `function canComplianceBind(address _compliance) external view returns (bool)`, which checks if presetting is required before binding a compliance module.

- **TREXFactory Enhancements**:
  - New function `setIdFactory`: Sets the Identity Factory responsible for deploying token ONCHAINIDs.
  - New function `getIdFactory`: Retrieves the address of the associated Identity Factory.

- **TREXGateway Contract**:
  - Deployed as a central interface for the TREX ecosystem, facilitating various crucial operations:
    - **Factory Management**: Manages the Factory contract address, enabling updates and ownership transfers.
    - **Public Deployment Control**: Toggles the ability for public entities to deploy TREX contracts, enhancing security and flexibility.
    - **Fee Management**: Sets and adjusts deployment fee details, including amount, token type, and collector address, and enables or disables fee requirements.
    - **Deployer Management**: Adds or removes approved deployers and applies fee discounts, including batch operations for efficiency. Ensures streamlined deployment processes for TREX contracts.
    - **Suite Deployment**: Directly deploys TREX suites of contracts using provided token and claim details, with support for batch deployments. Incorporates fee collection and deployment status checks for each deployment, emphasizing security and compliance.
    - **Status and Fee Queries**: Provides functions to retrieve current public deployment status, Factory contract address, deployment fee details, and deployment fee status.
    - **Fee Calculation**: Dynamically calculates deployment fees for deployers, considering applicable discounts.

- **DvATransferManager Contract**:
  - Introduced the `DvATransferManager` contract to streamline the process of internal fund transfers needing multi-party intermediate approvals.
    - Token owners define the transfer authorization criteria, including recipient approval, agent approval, and potential additional approvers.
    - Investors submit transfer requests.
    - Approvers are empowered to either sanction or reject these requests.
    - Transfers are executed only upon receiving unanimous approval from all designated approvers.

### Updates

#### Smart Contract Enhancements
- **TREXFactory**:
  - Modified the `deployTREXSuite` function to now auto-deploy a Token ONCHAINID if it's not already available (i.e., if the onchainid address in _tokenDetails is the zero address).

- **ModularCompliance**:
  - Updated the `addModule` function to invoke the new `isPlugAndPlay` and `canComplianceBind` functions, ensuring compatibility checks before binding any compliance module.

#### Code Quality Improvements
- Enhanced the GitHub Actions workflow by adding TypeScript linting (`lint:ts`) for test files, ensuring higher code quality and adherence to coding standards.
- Executed a comprehensive linting pass on all test files, addressing and resolving any linting issues. This ensures a consistent code style and improved readability across the test suite.
- Updated the `push_checking.yml` GitHub Actions workflow to include automatic TypeScript linting checks on pull requests. This addition enforces coding standards and helps maintain high-quality code submissions from all contributors.

## [4.0.1]

### Update

- Compliance module view methods no longer require the modifier `onlyComplianceBound`.

### Added

- script for flattening contracts with hardhat 

## [4.0.0]

Version 4.0.0 of TREX has been successfully audited by Hacken [more details here](https://tokeny.com/hacken-grants-tokenization-protocol-erc3643-a-10-10-security-audit-score/)

### Breaking changes
 
- Token Interface :
  - transferOwnershipOnTokenContract() function was removed and cannot be called anymore, call transferOwnership() instead, the function was a duplicate of transferOwnership() and was removed to simplify the interface and increase coherence.
  - addAgentOnTokenContract() function was removed and cannot be called anymore, call addAgent() instead, the function was a duplicate of addAgent() and was removed to simplify the interface and increase coherence.
  - removeAgentOnTokenContract()  function was removed and cannot be called anymore, call removeAgent() instead, the function was a duplicate of removeAgent() and was removed to simplify the interface and increase coherence.
- Identity Registry Interface :
  - transferOwnershipOnIdentityRegistryContract() function was removed and cannot be called anymore, call transferOwnership() instead, the function was a duplicate of transferOwnership() and was removed to simplify the interface and increase coherence.
  - addAgentOnIdentityRegistryContract() function was removed and cannot be called anymore, call addAgent() instead, the function was a duplicate of addAgent() and was removed to simplify the interface and increase coherence.
  - removeAgentOnIdentityRegistryContract()  function was removed and cannot be called anymore, call removeAgent() instead, the function was a duplicate of removeAgent() and was removed to simplify the interface and increase coherence.
- Identity Registry Storage Interface :
  - transferOwnershipOnIdentityRegistryStorage() function was removed and cannot be called anymore, call transferOwnership() instead, the function was a duplicate of transferOwnership() and was removed to simplify the interface and increase coherence.
- Trusted Issuers Registry Interface : 
  - transferOwnershipOnIssuersRegistryContract() function was removed and cannot be called anymore, call transferOwnership() instead, the function was a duplicate of transferOwnership() and was removed to simplify the interface and increase coherence.
- Claim Topics Registry Interface : 
  - transferOwnershipOnClaimTopicsRegistryContract() function was removed and cannot be called anymore, call transferOwnership() instead, the function was a duplicate of transferOwnership() and was removed to simplify the interface and increase coherence.
- Compliance Interface :
  - Compliance contract becomes Modular Compliance, the features used by legacy compliance contracts have to be translated under the form of modules. 
  - TokenAgentAdded event was removed from the interface, as there is no more need to add the Token agent list on the compliance contract, the new compliance, in v4, is capable to fetch directly the list of Token agents from the Token smart contract, without any need to store that list in its own memory. 
  - TokenAgentRemoved event was removed from the interface, for the same reason as TokenAgentAdded.
  - transferOwnershipOnComplianceContract() function was removed and cannot be called anymore, call transferOwnership() instead, the function was a duplicate of transferOwnership() and was removed to simplify the interface and increase coherence.
  - addTokenAgent()  function was removed and cannot be called anymore, the new compliance, in v4, is capable of fetching directly the list of Token agents from the Token smart contract, without any need to store that list in its own memory.
  - removeTokenAgent() function was removed and cannot be called anymore, the new compliance, in v4, is capable of fetching directly the list of Token agents from the Token smart contract, without any need to store that list in its own memory.
  - isTokenBound() function was removed from the interface, as there is only one token bound to a compliance contract, the existence of a function such as isTokenBound() was not necessary, the preferred option was to provide a getter, getTokenBound(), for the token address bound to the compliance instead. 
  - tokenBound is no longer a public variable and has to be accessed by its getter, getTokenBound()
  - 

### Update
- TREXImplementationAuthority has been modified to allow token issuers to change the ImplementationAuthority to 
  manage it by themselves, the interfaces and implementation of the contract changed, but the functions used by the 
  proxies to fetch the implementation contracts addresses remain the same. 
- The change of TREXImplementationAuthority has to follow rules to ensure safety of the migration, these rules are 
  enforced by smart contracts directly onchain. Tokeny's IA contract is the reference contract, other IA contracts 
  are considered as auxiliary contracts and can only update implementations to the versions of implementation 
  contracts listed on the reference IA by Tokeny, this is done to ensure security of the deployed tokens and prevent 
  any malicious use of the upgradeability functions. 
- a factory contract has been added, to deploy new TREXImplementationAuthority smart contracts, only the IA 
  contracts deployed by that factory or the reference IA are allowed to be used by TREX contracts, it is not 
  possible to come with your own implementation of the TREXImplementationAuthority contract and use it for contracts 
  already deployed by the TREX factory. 
- TREX Factory Contract has been added to the repository, this contract allows to deploy and set TREX tokens in 1 single transaction (deploys all contracts, initialize them and complete settings of contracts) 
- Trusted Issuers Registry Storage now maintains a mapping of truster issuers addresses allowed for a given claim topic.
  - This means adding/removing/updating a trusted issuer now cost more gas (especially removing and updating when removing topics).
- Trusted Issuers Registry now implements a `getTrustedIssuersForClaimTopic(uint256 claimTopic)` method to query trusted issuers allowed for a given claim topic.
- Identity Registry `isVerified` method now takes advantage of the new `getTrustedIssuersForClaimTopic`.
  - Verifying an identity should now cost less gas, as the registry now only attempts to fetch claims that would be allowed.
  - Identity can therefore no longer be blocked because it contains too many claims of a given topic.
- update solhint and adapt all contracts to the standards 
- Modular Compliance, new functions and events :
  - ModuleAdded event was added to the interface, as the compliance contract becomes modular, this event is used to track the list of Modules added to a Modular compliance contract. 
  - ModuleRemoved event was added to the interface, as the compliance contract becomes modular, this event is used to track the list of Modules removed from a Modular compliance contract.
  - ModuleInteraction event was added to the interface, this event is used to track all interactions done with bound modules and is emitted by the callModuleFunction() function.
  - getTokenBound() function was added to the interface, to help standardize the contract, the previously public variable tokenBound was set as private and this getter was added to retrieve the bound token address. 
  - addModule() function was added to the interface, as part of the modularization of the compliance contract. This function allows you to add/bind a new module to the compliance. 
  - removeModule() function was added to the interface, as part of the modularization of the compliance contract. This function allows you to remove/unbind a module previously added to the compliance. 
  - callModuleFunction() function was added to the interface, as part of the modularization of the compliance contract. This function allows you to interact with any bound module.
  - getModules() function was added to the interface, as part of the modularization of the compliance contract. This function allows you to fetch the list of Modules currently bound to the Modular Compliance Contract
  - isModuleBound() function was added to the interface, as part of the modularization of the compliance contract. This function allows you to check if a module is bound or not to the Compliance Contract. 
- updated licenses from 2021 to 2022 
- All contracts proxification 
- Lint all contracts following best practices for smart contract development, update of solhint file to automate checks regarding this 
- Complete NatSpec for all functions and events 

### Fix
- Update storage slot for ImplementationAuthority address on proxy contract to avoid storage collision 

## [3.5.1]

### Update 
- updated licenses from 2019 to 2021

### Fix 
- fix bug on the try/catch of `isVerified` function to return false if the verification of the claim returns an 
  error on the last claim checked on the ONCHAINID


## [3.5.0]

### Update
- Updated solidity to version 0.8.0
- Update comments in contracts code
- Update ONCHAINID imports with the proxified version (version 1.4.0)
- Update all dependencies to the latest stable version



### Added
- **DVDTransferManager** contract
- Tests for DVDTransferManager functions (100% test coverage)
- **callComplianceFunction** on OwnerManager to interact with any custom compliance function
- complianceManager role on OwnerManager
- exports for all contracts to be used in SDK
- flat contract for DVDTransferManager
- ONCHAINID proxified contract deployer for tests


### Fix

- flat contracts script : fix typo in token flattener command

### Changed

- Release & pre release flows (yarn -> npm)
- removed useless lines on `removeClaimTopics` function
- add try/catch in `isVerified` function to avoid errors with incompatible claims
- removed useless lines on `removeTrustedIssuer` function
- changed required key for roles on AgentManager contract (MANAGEMENT key -> EXECUTION key)
- changed required key for roles on OwnerManager contract (MANAGEMENT key -> EXECUTION key)
- import interfaces from openzeppelin instead of local copy
- contract name : **Storage** -> **TokenStorage**