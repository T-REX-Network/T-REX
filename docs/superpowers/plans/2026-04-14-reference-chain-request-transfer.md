# Reference-Chain `requestTransfer` & Hook System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `requestTransfer` to the reference-chain ERC3643 `Token`, build the reference-side cross-chain hook system, and refactor the bridged-chain `erc3643-cc-light` hook + token to consume the new authorization payload.

**Architecture:** Reference chain is the compliance source of truth. `Token.requestTransfer(dstChainId, from, to, value)` evaluates compliance, allocates a per-`from` nonce, computes a hash committing to `(dstChainId, from, to, value, nonce, expiry)`, and ships an authorization message via a Chainlink CCIP hook to the bridged chain. The bridged-chain hook stores authorizations in a per-`(from, to, value)` FIFO queue, indexed by hash. `Erc3643Light.transfer()` calls `hook.consumeAuthorization(from, to, value)` which pops the oldest non-expired authorization, marks it consumed, and ships a settlement notification back to the reference chain. The reference-side hook receives the notification and clears the pending state on the token.

**Tech Stack:** Solidity 0.8.30, Foundry, OpenZeppelin Contracts (Upgradeable for ref chain, non-upgradeable for cc-light), Chainlink CCIP, AccessManager.

**Spec:** `docs/superpowers/specs/2026-04-14-reference-chain-request-transfer-design.md`

**Repos touched:**
- `erc3643-cc-light` (bridged chain) — `/Users/pgonday/ws/erc3643-cc-light`
- `erc3643` reference chain (this worktree) — `/Users/pgonday/wt/erc3643/access-manager-develop`

**Execution order:** cc-light Phase 1–2 first (so the new payload format and queue behavior are locked in), then the reference-chain phases. The two repos can be developed and tested independently up to Phase 6 (cross-repo wire-up).

---

## Phase 1 — cc-light: HashLib

### Task 1.1: New HashLib signature

**Files:**
- Modify: `erc3643-cc-light/contracts/libraries/HashLib.sol`
- Test: `erc3643-cc-light/test/unit/HashLibUnitTest.t.sol` (new)

- [ ] **Step 1: Write the failing test**

Create `erc3643-cc-light/test/unit/HashLibUnitTest.t.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/src/Test.sol";

import { HashLib } from "contracts/libraries/HashLib.sol";

contract HashLibUnitTest is Test {

    function test_hash_isDeterministic() public pure {
        bytes32 a = HashLib.hash(11_155_111, address(0x1111), address(0x2222), 100, 0, 1_700_000_300);
        bytes32 b = HashLib.hash(11_155_111, address(0x1111), address(0x2222), 100, 0, 1_700_000_300);
        assertEq(a, b);
    }

    function test_hash_changesWithChainId() public pure {
        bytes32 a = HashLib.hash(11_155_111, address(0x1111), address(0x2222), 100, 0, 1_700_000_300);
        bytes32 b = HashLib.hash(80_002, address(0x1111), address(0x2222), 100, 0, 1_700_000_300);
        assertTrue(a != b);
    }

    function test_hash_changesWithNonce() public pure {
        bytes32 a = HashLib.hash(11_155_111, address(0x1111), address(0x2222), 100, 0, 1_700_000_300);
        bytes32 b = HashLib.hash(11_155_111, address(0x1111), address(0x2222), 100, 1, 1_700_000_300);
        assertTrue(a != b);
    }

    function test_hash_changesWithExpiry() public pure {
        bytes32 a = HashLib.hash(11_155_111, address(0x1111), address(0x2222), 100, 0, 1_700_000_300);
        bytes32 b = HashLib.hash(11_155_111, address(0x1111), address(0x2222), 100, 0, 1_700_000_900);
        assertTrue(a != b);
    }

    function test_hash_referenceVector() public pure {
        // Locked vector — must match the reference-chain HashLib output for the same inputs.
        bytes32 expected = keccak256(
            abi.encode(uint64(11_155_111), address(0xAa00000000000000000000000000000000000001), address(0xbB00000000000000000000000000000000000002), uint256(123), uint256(7), uint64(1_700_000_300))
        );
        bytes32 actual = HashLib.hash(11_155_111, address(0xAa00000000000000000000000000000000000001), address(0xbB00000000000000000000000000000000000002), 123, 7, 1_700_000_300);
        assertEq(actual, expected);
    }

}
```

- [ ] **Step 2: Run test to verify it fails to compile**

Run: `forge test --match-path test/unit/HashLibUnitTest.t.sol`
Expected: COMPILE FAIL — `HashLib.hash` signature mismatch.

- [ ] **Step 3: Replace HashLib implementation**

Overwrite `erc3643-cc-light/contracts/libraries/HashLib.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

library HashLib {

    function hash(
        uint64 dstChainId,
        address from,
        address to,
        uint256 value,
        uint256 nonce,
        uint64 expiry
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(dstChainId, from, to, value, nonce, expiry));
    }

}
```

- [ ] **Step 4: Run the new test**

Run: `forge test --match-path test/unit/HashLibUnitTest.t.sol -vv`
Expected: PASS for all four `test_hash_*` cases.

- [ ] **Step 5: Build only — do not run the rest of the suite yet**

Run: `forge build`
Expected: COMPILE FAIL — `Erc3643Light.sol` and `TransferUnitTest.t.sol` reference the old `HashLib.hash(from, to, value)` signature. This is expected and will be fixed in subsequent tasks.

- [ ] **Step 6: Commit**

```bash
cd /Users/pgonday/ws/erc3643-cc-light
git add contracts/libraries/HashLib.sol test/unit/HashLibUnitTest.t.sol
git commit -m "♻️ Extend HashLib with chainId, nonce, and expiry"
```

---

## Phase 2 — cc-light: Hook interface, queue, and Token wiring

### Task 2.1: Replace `ICrossChainHook`

**Files:**
- Modify: `erc3643-cc-light/contracts/interfaces/ICrossChainHook.sol`

- [ ] **Step 1: Replace the interface body**

Overwrite `erc3643-cc-light/contracts/interfaces/ICrossChainHook.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

/// @title ICrossChainHook
/// @notice Bridged-chain hook interface. The reference chain is the source of truth for compliance
/// and pushes pre-authorizations here. The token consumes one authorization per transfer; the hook
/// is responsible for finding the matching authorization, marking it consumed, and notifying the
/// reference chain.
interface ICrossChainHook {

    /// @notice Consumes the oldest non-expired authorization matching (from, to, value).
    /// @dev Reverts if no such authorization exists. Triggers the outbound settlement
    /// notification before returning.
    /// @return hash The hash of the consumed authorization.
    function consumeAuthorization(address from, address to, uint256 value) external returns (bytes32 hash);

}
```

- [ ] **Step 2: Build to confirm compile failures cascade**

Run: `forge build`
Expected: COMPILE FAIL in `Erc3643Light.sol`, `AbstractCrossChainHook.sol`, `ChainlinkCrossChainHook.sol`, `CrossChainHookMock.sol`, `TransferUnitTest.t.sol`. Do not commit yet.

### Task 2.2: New ErrorsLib entries for the hook

**Files:**
- Modify: `erc3643-cc-light/contracts/libraries/ErrorsLib.sol`

- [ ] **Step 1: Add error declarations**

Edit `erc3643-cc-light/contracts/libraries/ErrorsLib.sol` so the body becomes:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

library ErrorsLib {

    error ZeroAddress();

    error AuthorizationNotReceived();
    error TransferNotAuthorized();
    error AuthorizationAlreadyExists(bytes32 hash);

    error UnauthorizedAccess();

}
```

(`AuthorizationNotReceived` is kept temporarily; it is removed after the test refactor in Task 2.6.)

### Task 2.3: Refactor `AbstractCrossChainHook` to a queue model

**Files:**
- Modify: `erc3643-cc-light/contracts/hooks/AbstractCrossChainHook.sol`

- [ ] **Step 1: Replace the contract body**

Overwrite `erc3643-cc-light/contracts/hooks/AbstractCrossChainHook.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import { ICrossChainHook } from "../interfaces/ICrossChainHook.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";

/// @title AbstractCrossChainHook
/// @notice Bridged-chain hook base. Stores authorizations in a FIFO queue keyed by
/// (from, to, value) and exposes a single `consumeAuthorization` entry point used by the token.
/// Subclasses implement the cross-chain transport for receiving authorizations and sending
/// settlement notifications back to the reference chain.
abstract contract AbstractCrossChainHook is ICrossChainHook, AccessManaged {

    struct Authorization {
        uint64 expiry;
        bool consumed;
        bool exists;
    }

    /// @dev key = keccak256(abi.encode(from, to, value)) → FIFO of pending hashes.
    mapping(bytes32 key => bytes32[] hashes) private _queue;

    /// @dev Position of the next un-popped entry in the queue.
    mapping(bytes32 key => uint256 head) private _queueHead;

    mapping(bytes32 hash => Authorization) private _authorizations;

    constructor(address accessManager) AccessManaged(accessManager) { }

    // ----- ICrossChainHook -----

    /// @inheritdoc ICrossChainHook
    function consumeAuthorization(address from, address to, uint256 value)
        external
        restricted
        returns (bytes32 hash)
    {
        bytes32 key = _key(from, to, value);
        bytes32[] storage queue = _queue[key];
        uint256 head = _queueHead[key];

        while (head < queue.length) {
            bytes32 candidate = queue[head];
            Authorization storage auth = _authorizations[candidate];

            if (!auth.consumed && auth.expiry >= block.timestamp) {
                auth.consumed = true;
                _queueHead[key] = head + 1;
                _onTransfer(candidate);
                return candidate;
            }

            // Skip expired/already-consumed entries.
            head += 1;
        }

        _queueHead[key] = head;
        revert ErrorsLib.TransferNotAuthorized();
    }

    // ----- View helpers -----

    /// @notice Returns the authorization metadata for a hash.
    function authorizationOf(bytes32 hash) external view returns (Authorization memory) {
        return _authorizations[hash];
    }

    /// @notice Returns the next non-expired non-consumed hash in the queue, or `bytes32(0)`
    /// if none. Useful for tests; also used by tooling to inspect pending state.
    function peekAuthorization(address from, address to, uint256 value) external view returns (bytes32) {
        bytes32 key = _key(from, to, value);
        bytes32[] storage queue = _queue[key];
        uint256 head = _queueHead[key];

        while (head < queue.length) {
            bytes32 candidate = queue[head];
            Authorization storage auth = _authorizations[candidate];
            if (!auth.consumed && auth.expiry >= block.timestamp) {
                return candidate;
            }
            head += 1;
        }
        return bytes32(0);
    }

    // ----- Internal -----

    /// @dev Records an authorization received from the reference chain. Reverts if the same hash
    /// has already been recorded.
    function _recordAuthorization(
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) internal {
        Authorization storage existing = _authorizations[hash];
        require(!existing.exists, ErrorsLib.AuthorizationAlreadyExists(hash));

        _authorizations[hash] = Authorization({ expiry: expiry, consumed: false, exists: true });
        _queue[_key(from, to, value)].push(hash);
    }

    /// @dev Must be overridden to send the settlement notification back to the reference chain.
    function _onTransfer(bytes32 hash) internal virtual;

    function _key(address from, address to, uint256 value) private pure returns (bytes32) {
        return keccak256(abi.encode(from, to, value));
    }

}
```

- [ ] **Step 2: Build (still expect downstream failures)**

Run: `forge build`
Expected: COMPILE FAIL still in `Erc3643Light.sol`, `ChainlinkCrossChainHook.sol`, `CrossChainHookMock.sol`, tests.

### Task 2.4: Update `ChainlinkCrossChainHook` payload

**Files:**
- Modify: `erc3643-cc-light/contracts/hooks/ChainlinkCrossChainHook.sol`

- [ ] **Step 1: Update receive and rename**

Overwrite the two cross-chain methods in `ChainlinkCrossChainHook.sol` so the file becomes:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { CCIPReceiver } from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

import { AbstractCrossChainHook } from "./AbstractCrossChainHook.sol";

/// @title ChainlinkCrossChainHook
/// @notice Bridged-chain hook using Chainlink CCIP. Receives transfer authorizations from the
/// reference chain and notifies it once the corresponding ERC20 transfer has been executed.
contract ChainlinkCrossChainHook is AbstractCrossChainHook, CCIPReceiver {

    event MessageSent(bytes32 indexed messageId);

    LinkTokenInterface internal immutable _linkToken;
    address internal _refChainReceiver;
    uint64 internal immutable _referenceChainSelector;
    uint200 internal _gasLimit;

    error InvalidSourceChain();
    error InvalidSender();

    constructor(
        address router,
        address link,
        uint64 referenceChainSelector,
        address refChainReceiver,
        uint200 gasLimit,
        address accessManager
    ) AbstractCrossChainHook(accessManager) CCIPReceiver(router) {
        _linkToken = LinkTokenInterface(link);
        _referenceChainSelector = referenceChainSelector;
        _refChainReceiver = refChainReceiver;
        _gasLimit = gasLimit;
    }

    // ----- Admin -----

    function setRefChainReceiver(address refChainReceiver) external restricted {
        _refChainReceiver = refChainReceiver;
    }

    function setGasLimit(uint200 gasLimit) external restricted {
        _gasLimit = gasLimit;
    }

    // ----- Cross-chain implementation -----

    /// @dev Receives an authorization from the reference chain. Payload layout:
    /// `(bytes32 hash, uint64 expiry, address from, address to, uint256 value)`.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        require(message.sourceChainSelector == _referenceChainSelector, InvalidSourceChain());
        require(abi.decode(message.sender, (address)) == _refChainReceiver, InvalidSender());

        (bytes32 hash, uint64 expiry, address from, address to, uint256 value) =
            abi.decode(message.data, (bytes32, uint64, address, address, uint256));

        _recordAuthorization(hash, expiry, from, to, value);
    }

    /// @dev Notifies the reference chain that an authorized transfer has executed.
    function _onTransfer(bytes32 hash) internal override {
        _sendMessage(abi.encode(hash));
    }

    // ----- Helpers -----

    function _sendMessage(bytes memory data) internal returns (bytes32) {
        Client.EVM2AnyMessage memory request = Client.EVM2AnyMessage({
            receiver: abi.encode(_refChainReceiver),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({ gasLimit: _gasLimit, allowOutOfOrderExecution: true })
            ),
            feeToken: address(_linkToken)
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fees = router.getFee(_referenceChainSelector, request);
        _linkToken.approve(address(router), fees);

        bytes32 messageId = router.ccipSend(_referenceChainSelector, request);
        emit MessageSent(messageId);

        return messageId;
    }

}
```

- [ ] **Step 2: Build**

Run: `forge build`
Expected: still failing on `Erc3643Light.sol`, `CrossChainHookMock.sol`, tests.

### Task 2.5: Simplify `Erc3643Light._update`

**Files:**
- Modify: `erc3643-cc-light/contracts/Erc3643Light.sol`

- [ ] **Step 1: Replace `_update` and remove `isTransferAuthorized`**

Overwrite `erc3643-cc-light/contracts/Erc3643Light.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ERC20, ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import { ICrossChainHook } from "./interfaces/ICrossChainHook.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";

/// @title Erc3643Light
/// @notice ERC20 token with cross-chain transfer authorization via a hook system.
/// @dev Mint/burn paths are unrestricted by the hook (used by bridge contracts). Every other
/// transfer asks the hook to consume a matching authorization issued by the reference chain.
contract Erc3643Light is ERC20Permit, AccessManaged, Ownable {

    ICrossChainHook private _hook;

    constructor(string memory name, string memory symbol, address accessManager, address hook)
        ERC20(name, symbol)
        ERC20Permit(name)
        AccessManaged(accessManager)
        Ownable(accessManager)
    {
        require(hook != address(0), ErrorsLib.ZeroAddress());
        _hook = ICrossChainHook(hook);
    }

    // ----- Hook Management -----

    function setHook(address hook) external restricted {
        require(hook != address(0), ErrorsLib.ZeroAddress());
        _hook = ICrossChainHook(hook);
    }

    function hook() external view returns (address) {
        return address(_hook);
    }

    // ----- Mintable -----

    function mint(address account, uint256 value) external restricted {
        _mint(account, value);
    }

    // ----- Burnable -----

    function burn(uint256 value) external {
        _burn(_msgSender(), value);
    }

    function burn(address account, uint256 amount) external restricted {
        _burn(account, amount);
    }

    function burnFrom(address account, uint256 value) public restricted {
        _burn(account, value);
    }

    // ----- Internal -----

    /// @dev Overrides ERC20 _update to require an authorization for every non-mint/burn transfer.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        _hook.consumeAuthorization(from, to, value);
        super._update(from, to, value);
    }

}
```

- [ ] **Step 2: Update `CrossChainHookMock`**

Overwrite `erc3643-cc-light/test/unit/mocks/CrossChainHookMock.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { AbstractCrossChainHook } from "contracts/hooks/AbstractCrossChainHook.sol";

contract CrossChainHookMock is AbstractCrossChainHook {

    event MockSettlementEmitted(bytes32 indexed hash);

    constructor(address accessManager) AbstractCrossChainHook(accessManager) { }

    function _onTransfer(bytes32 hash) internal override {
        emit MockSettlementEmitted(hash);
    }

    /// @dev Test helper: simulate an inbound authorization from the reference chain.
    function simulateAuthorization(
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) external {
        _recordAuthorization(hash, expiry, from, to, value);
    }

}
```

- [ ] **Step 3: Build (still failing tests)**

Run: `forge build`
Expected: COMPILES (no more contract errors). Test files `TransferUnitTest.t.sol`, `TransferFromUnitTest.t.sol`, `HookUnitTest.t.sol`, `ChainlinkCrossChainHookUnitTest.t.sol` still reference old APIs and will be fixed in Task 2.6.

### Task 2.6: Update existing tests for the new flow

**Files:**
- Modify: `erc3643-cc-light/test/unit/TransferUnitTest.t.sol`
- Modify: `erc3643-cc-light/test/unit/TransferFromUnitTest.t.sol`
- Modify: `erc3643-cc-light/test/unit/HookUnitTest.t.sol`
- Modify: `erc3643-cc-light/test/unit/ChainlinkCrossChainHookUnitTest.t.sol`

- [ ] **Step 1: Add a test helper for hash construction**

Edit `erc3643-cc-light/test/unit/helpers/BaseUnitTest.sol` and append before the closing brace:

```solidity
    uint64 internal constant TEST_EXPIRY_OFFSET = 5 minutes;

    function _futureExpiry() internal view returns (uint64) {
        return uint64(block.timestamp) + TEST_EXPIRY_OFFSET;
    }

    function _authorize(address from, address to, uint256 value, uint256 nonce) internal returns (bytes32) {
        return _authorize(from, to, value, nonce, _futureExpiry());
    }

    function _authorize(address from, address to, uint256 value, uint256 nonce, uint64 expiry) internal returns (bytes32) {
        bytes32 h = HashLib.hash(uint64(block.chainid), from, to, value, nonce, expiry);
        hook.simulateAuthorization(h, expiry, from, to, value);
        return h;
    }
```

…and add the matching import at the top of `BaseUnitTest.sol`:

```solidity
import { HashLib } from "contracts/libraries/HashLib.sol";
```

- [ ] **Step 2: Rewrite `TransferUnitTest.t.sol`**

Overwrite the file:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseUnitTest } from "./helpers/BaseUnitTest.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { HashLib } from "contracts/libraries/HashLib.sol";

contract TransferUnitTest is BaseUnitTest {

    function setUp() public override {
        super.setUp();

        vm.prank(minter);
        token.mint(alice, 1000);
    }

    // ----- Success -----

    function test_transfer_succeedsWhenAuthorized() public {
        _authorize(alice, bob, 100, 0);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));

        assertEq(token.balanceOf(alice), 900);
        assertEq(token.balanceOf(bob), 100);
    }

    function test_transfer_succeedsWithFuzzedAmount(uint256 amount) public {
        amount = bound(amount, 1, 1000);
        _authorize(alice, bob, amount, 0);

        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));

        assertEq(token.balanceOf(alice), 1000 - amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function test_transfer_emitsTransferEvent() public {
        _authorize(alice, bob, 100, 0);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 100);
        assertTrue(token.transfer(bob, 100));
    }

    function test_transfer_consumesQueuedAuthorization() public {
        bytes32 h = _authorize(alice, bob, 100, 0);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));

        // The same hash should now be consumed; the next transfer for the same triple must fail.
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.TransferNotAuthorized.selector);
        token.transfer(bob, 100);

        assertTrue(hook.authorizationOf(h).consumed);
    }

    function test_transfer_consumesInFifoOrder() public {
        bytes32 first = _authorize(alice, bob, 100, 0);
        bytes32 second = _authorize(alice, bob, 100, 1);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));
        assertTrue(hook.authorizationOf(first).consumed);
        assertFalse(hook.authorizationOf(second).consumed);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));
        assertTrue(hook.authorizationOf(second).consumed);
    }

    function test_transfer_skipsExpiredAuthorization() public {
        uint64 expired = uint64(block.timestamp) + 10;
        bytes32 stale = HashLib.hash(uint64(block.chainid), alice, bob, 100, 0, expired);
        hook.simulateAuthorization(stale, expired, alice, bob, 100);

        vm.warp(uint256(expired) + 1);

        // Issue a fresh one (warp invalidated the first).
        _authorize(alice, bob, 100, 1);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));
    }

    // ----- Revert -----

    function test_transfer_revertsWhenNoAuthorization() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.TransferNotAuthorized.selector);
        token.transfer(bob, 100);
    }

    function test_transfer_revertsWhenAuthorizationExpired() public {
        uint64 expiry = uint64(block.timestamp) + 10;
        _authorize(alice, bob, 100, 0, expiry);

        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        vm.expectRevert(ErrorsLib.TransferNotAuthorized.selector);
        token.transfer(bob, 100);
    }

    function test_transfer_revertsWhenInsufficientBalance() public {
        _authorize(alice, bob, 1001, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000, 1001));
        token.transfer(bob, 1001);
    }

}
```

- [ ] **Step 3: Rewrite `TransferFromUnitTest.t.sol`**

Open `erc3643-cc-light/test/unit/TransferFromUnitTest.t.sol` and apply the same pattern: replace every call to `hook.simulateCrossChainResponse(...)` and the manual `HashLib.hash(from, to, value)` constructions with `_authorize(from, to, value, 0)`. Replace every `vm.expectRevert(ErrorsLib.AuthorizationNotReceived.selector)` with `vm.expectRevert(ErrorsLib.TransferNotAuthorized.selector)`. Run the file in isolation after each edit.

- [ ] **Step 4: Rewrite `HookUnitTest.t.sol` for the new queue API**

The existing `HookUnitTest.t.sol` tests `isTransferAuthorized` / `onTransfer`. Replace it with tests against the new API. Overwrite the file:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/src/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { CrossChainHookMock } from "./mocks/CrossChainHookMock.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { HashLib } from "contracts/libraries/HashLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

contract HookUnitTest is Test {

    AccessManager internal accessManager;
    CrossChainHookMock internal hook;

    address internal admin = makeAddr("admin");
    address internal tokenLike = makeAddr("token");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        accessManager = new AccessManager(admin);
        hook = new CrossChainHookMock(address(accessManager));

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = CrossChainHookMock.consumeAuthorization.selector;
        accessManager.setTargetFunctionRole(address(hook), selectors, RolesLib.TOKEN);
        accessManager.grantRole(RolesLib.TOKEN, tokenLike, 0);
        vm.stopPrank();
    }

    function _record(uint256 nonce, uint64 expiry) internal returns (bytes32) {
        bytes32 h = HashLib.hash(uint64(block.chainid), alice, bob, 100, nonce, expiry);
        hook.simulateAuthorization(h, expiry, alice, bob, 100);
        return h;
    }

    function test_consumeAuthorization_returnsHashAndMarksConsumed() public {
        bytes32 h = _record(0, uint64(block.timestamp + 5 minutes));

        vm.prank(tokenLike);
        bytes32 returned = hook.consumeAuthorization(alice, bob, 100);

        assertEq(returned, h);
        assertTrue(hook.authorizationOf(h).consumed);
    }

    function test_consumeAuthorization_revertsWhenQueueEmpty() public {
        vm.prank(tokenLike);
        vm.expectRevert(ErrorsLib.TransferNotAuthorized.selector);
        hook.consumeAuthorization(alice, bob, 100);
    }

    function test_consumeAuthorization_revertsWhenAllExpired() public {
        uint64 expiry = uint64(block.timestamp) + 10;
        _record(0, expiry);
        vm.warp(uint256(expiry) + 1);

        vm.prank(tokenLike);
        vm.expectRevert(ErrorsLib.TransferNotAuthorized.selector);
        hook.consumeAuthorization(alice, bob, 100);
    }

    function test_consumeAuthorization_skipsExpiredEntriesFromHead() public {
        uint64 shortExpiry = uint64(block.timestamp) + 10;
        _record(0, shortExpiry);
        bytes32 keep = _record(1, uint64(block.timestamp + 1 hours));

        vm.warp(uint256(shortExpiry) + 1);

        vm.prank(tokenLike);
        bytes32 returned = hook.consumeAuthorization(alice, bob, 100);
        assertEq(returned, keep);
    }

    function test_consumeAuthorization_revertsWithoutTokenRole() public {
        _record(0, uint64(block.timestamp + 5 minutes));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        hook.consumeAuthorization(alice, bob, 100);
    }

    function test_recordAuthorization_revertsOnDuplicateHash() public {
        uint64 expiry = uint64(block.timestamp + 5 minutes);
        bytes32 h = HashLib.hash(uint64(block.chainid), alice, bob, 100, 0, expiry);
        hook.simulateAuthorization(h, expiry, alice, bob, 100);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AuthorizationAlreadyExists.selector, h));
        hook.simulateAuthorization(h, expiry, alice, bob, 100);
    }

    function test_consumeAuthorization_emitsSettlement() public {
        bytes32 h = _record(0, uint64(block.timestamp + 5 minutes));

        vm.expectEmit(true, false, false, true, address(hook));
        emit CrossChainHookMock.MockSettlementEmitted(h);

        vm.prank(tokenLike);
        hook.consumeAuthorization(alice, bob, 100);
    }

}
```

- [ ] **Step 5: Update `ChainlinkCrossChainHookUnitTest.t.sol`**

Open the file and update each test that constructs CCIP messages to use the new payload layout:

```solidity
bytes memory payload = abi.encode(
    /* hash    */ HashLib.hash(uint64(block.chainid), alice, bob, 100, 0, expiry),
    /* expiry  */ uint64(expiry),
    /* from    */ alice,
    /* to      */ bob,
    /* value   */ uint256(100)
);
```

Update assertions that previously called `hook.isTransferAuthorized(hash)` to instead call `hook.peekAuthorization(alice, bob, 100)` or `hook.authorizationOf(hash)`.

- [ ] **Step 6: Run the cc-light unit suite**

Run: `forge test --match-path "test/unit/**" -vv`
Expected: ALL PASS.

- [ ] **Step 7: Remove the now-unused error**

Edit `erc3643-cc-light/contracts/libraries/ErrorsLib.sol` and remove the line `error AuthorizationNotReceived();`.
Run: `forge build` — Expected: PASS.

- [ ] **Step 8: Commit**

```bash
cd /Users/pgonday/ws/erc3643-cc-light
git add -A contracts test
git commit -m "♻️ Replace authorization gate with FIFO queue and single consume entry point"
```

---

## Phase 3 — cc-light: AccessManager wiring + integration test update

### Task 3.1: Update `AccessManagerSetupLib`

**Files:**
- Modify: `erc3643-cc-light/contracts/libraries/AccessManagerSetupLib.sol`

- [ ] **Step 1: Replace the hook role binding**

Edit `setupHookRoles` so it now wires `consumeAuthorization` instead of `onTransfer`:

```solidity
function setupHookRoles(IAccessManager accessManager, address hook) internal {
    bytes4[] memory functions = new bytes4[](1);
    functions[0] = ICrossChainHook.consumeAuthorization.selector;
    accessManager.setTargetFunctionRole(hook, functions, RolesLib.TOKEN);
}
```

- [ ] **Step 2: Run the AccessManager setup test**

Run: `forge test --match-path test/unit/AccessManagerSetupUnitTest.t.sol -vv`
Expected: PASS (the test asserts the role binding for `consumeAuthorization`). If the existing test still asserts the old selector, update its expectation in the same step.

### Task 3.2: Update Chainlink integration test

**Files:**
- Modify: `erc3643-cc-light/test/integration/chainlink/ClCrossChainComplianceTest.t.sol`
- Modify: `erc3643-cc-light/test/integration/chainlink/ClReferenceChainCompliance.sol`

- [ ] **Step 1: Update the mock reference chain to send the new payload**

Open `ClReferenceChainCompliance.sol` and change the body of the function that sends the authorization message. The new payload layout is:

```solidity
bytes memory data = abi.encode(
    HashLib.hash(uint64(bridgedChainSelectorAsChainId), from, to, value, nonce, expiry),
    expiry,
    from,
    to,
    value
);
```

Track a per-`from` nonce locally (a `mapping(address => uint256) nextNonce`) and an expiry of `block.timestamp + 5 minutes`. Make sure the `bridgedChainSelectorAsChainId` parameter is passed in from the test setup so the test stays in sync with what the bridged-side `Erc3643Light` will eventually compute (after Phase 6 wires the reference chain in for real, the test is replaced anyway).

- [ ] **Step 2: Update the cross-chain compliance test**

Open `ClCrossChainComplianceTest.t.sol`. Anywhere it asserts authorization state, replace with calls to `hook.peekAuthorization(from, to, value)` or `hook.authorizationOf(hash)`. Anywhere it called `token.transfer(...)` and expected the gate to fire, the test still works — the only change is the underlying payload.

- [ ] **Step 3: Run the integration test**

Run: `forge test --match-path "test/integration/**" -vv`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/pgonday/ws/erc3643-cc-light
git add -A
git commit -m "♻️ Update AccessManager wiring and integration test for new hook API"
```

---

## Phase 4 — Reference chain: HashLib, errors, events, roles

### Task 4.1: Create `HashLib`

**Files:**
- Create: `erc3643/contracts/libraries/HashLib.sol`
- Test: `erc3643/test/unit/libraries/HashLibUnitTest.t.sol` (new)

- [ ] **Step 1: Write the failing test**

Create `erc3643/test/unit/libraries/HashLibUnitTest.t.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";

import { HashLib } from "contracts/libraries/HashLib.sol";

contract HashLibUnitTest is Test {

    function test_hash_referenceVector() public pure {
        // Locked vector — must match the cc-light HashLib output for the same inputs.
        bytes32 expected = keccak256(
            abi.encode(uint64(11_155_111), address(0xAa00000000000000000000000000000000000001), address(0xbB00000000000000000000000000000000000002), uint256(123), uint256(7), uint64(1_700_000_300))
        );
        bytes32 actual = HashLib.hash(11_155_111, address(0xAa00000000000000000000000000000000000001), address(0xbB00000000000000000000000000000000000002), 123, 7, 1_700_000_300);
        assertEq(actual, expected);
    }

    function test_hash_isDeterministic() public pure {
        bytes32 a = HashLib.hash(1, address(0x1), address(0x2), 100, 0, 1_700_000_000);
        bytes32 b = HashLib.hash(1, address(0x1), address(0x2), 100, 0, 1_700_000_000);
        assertEq(a, b);
    }

}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/unit/libraries/HashLibUnitTest.t.sol`
Expected: COMPILE FAIL.

- [ ] **Step 3: Create the library**

Create `erc3643/contracts/libraries/HashLib.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

library HashLib {

    function hash(
        uint64 dstChainId,
        address from,
        address to,
        uint256 value,
        uint256 nonce,
        uint64 expiry
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(dstChainId, from, to, value, nonce, expiry));
    }

}
```

- [ ] **Step 4: Run the test**

Run: `forge test --match-path test/unit/libraries/HashLibUnitTest.t.sol -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/pgonday/wt/erc3643/access-manager-develop
git add contracts/libraries/HashLib.sol test/unit/libraries/HashLibUnitTest.t.sol
git commit -m "✨ Add HashLib for cross-chain transfer authorization hashes"
```

### Task 4.2: Add errors, events, and roles

**Files:**
- Modify: `erc3643/contracts/libraries/ErrorsLib.sol`
- Modify: `erc3643/contracts/libraries/EventsLib.sol`
- Modify: `erc3643/contracts/libraries/RolesLib.sol`

- [ ] **Step 1: Add the new errors**

In `ErrorsLib.sol`, append inside the library body (under the `// Token Errors` group):

```solidity
    // Cross-chain hook errors
    error HookNotSet();
    error RequestAlreadyPending(bytes32 hash);
    error UnauthorizedHookCaller();
    error DestinationChainNotConfigured(uint64 dstChainId);
```

- [ ] **Step 2: Add the new events**

In `EventsLib.sol`, append under the `// Token Events` group:

```solidity
    event TransferRequested(
        bytes32 indexed hash,
        uint64 dstChainId,
        address indexed from,
        address indexed to,
        uint256 value,
        uint256 nonce,
        uint64 expiry
    );
    event TransferSettled(bytes32 indexed hash);
    event HookSet(address indexed hook);
    event BridgedHookConfigured(uint64 indexed dstChainId, bytes32 bridgedHookAddress);
```

- [ ] **Step 3: Add the new roles**

In `RolesLib.sol`, append after `SPENDING_ADMIN`:

```solidity
    uint64 constant HOOK_MANAGER = ROLE_PREFIX + 14;
    uint64 constant HOOK = ROLE_PREFIX + 15;
    uint64 constant TOKEN = ROLE_PREFIX + 16;
```

- [ ] **Step 4: Build**

Run: `forge build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/libraries/ErrorsLib.sol contracts/libraries/EventsLib.sol contracts/libraries/RolesLib.sol
git commit -m "✨ Add cross-chain hook errors, events, and roles"
```

---

## Phase 5 — Reference chain: Token additions

### Task 5.1: Extend `IToken`

**Files:**
- Modify: `erc3643/contracts/token/IToken.sol`

- [ ] **Step 1: Add the new function declarations**

Append inside the `IToken` interface body:

```solidity
    /// @notice Requests a cross-chain transfer authorization.
    /// @dev Anyone can call. Performs the same compliance/identity checks as `transfer`,
    /// allocates a per-`from` nonce, computes a 5-minute-TTL expiry, and ships the
    /// authorization to the bridged chain via the configured hook.
    /// @param dstChainId The bridged chain id on which the transfer will execute.
    /// @return hash The authorization hash.
    function requestTransfer(uint64 dstChainId, address from, address to, uint256 value)
        external
        returns (bytes32 hash);

    /// @notice Called by the configured hook when a settlement notification is received.
    function onTransferSettled(bytes32 hash) external;

    /// @notice Updates the cross-chain hook address.
    function setHook(address hook) external;

    /// @notice Returns the configured cross-chain hook.
    function hook() external view returns (address);

    /// @notice Returns the next nonce that will be allocated for `from`.
    function nextNonce(address from) external view returns (uint256);

    /// @notice Returns true if `hash` corresponds to an outstanding transfer request.
    function isPending(bytes32 hash) external view returns (bool);
```

- [ ] **Step 2: Build**

Run: `forge build`
Expected: COMPILE FAIL — `Token` does not implement the new methods. Continue to Task 5.2.

### Task 5.2: Implement `Token` storage extensions

**Files:**
- Modify: `erc3643/contracts/token/Token.sol`

- [ ] **Step 1: Add storage fields and constants**

In `Token.sol`, modify the `TokenStorage` struct (around line 117) by appending three fields **at the end** so the layout stays additive:

```solidity
    /// @custom:storage-location erc7201:token.storage.main
    struct TokenStorage {
        uint8 decimals;
        address onchainId;
        IERC3643Compliance compliance;
        IERC3643IdentityRegistry identityRegistry;
        address trustedForwarder;

        mapping(address user => FrozenStatus) frozenStatus;
        mapping(address spender => bool) defaultAllowances;
        mapping(address user => bool) defaultAllowanceOptOuts;

        mapping(address agent => TokenRoles) agentsRestrictions;

        // Cross-chain hook fields (appended; do not reorder)
        address hook;
        mapping(address from => uint256) nextNonce;
        mapping(bytes32 hash => bool) pendingRequests;
    }
```

Add a constant near the top of the contract body, just below `VERSION`:

```solidity
    uint64 internal constant AUTHORIZATION_TTL = 5 minutes;
```

- [ ] **Step 2: Add `IReferenceCrossChainHook` import (will be created in Phase 6 — use a forward declaration for now)**

For now, define a minimal local interface inside `Token.sol` to keep this phase self-contained (it will be replaced with a real import in Task 6.2). Add near the existing imports:

```solidity
interface ITokenCrossChainHook {
    function sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) external;
}
```

(Place it above the `contract Token` declaration, after the imports.)

- [ ] **Step 3: Build**

Run: `forge build`
Expected: still failing because `IToken` declares functions not yet implemented. Continue to Task 5.3.

### Task 5.3: Add a unit test scaffold for `requestTransfer`

**Files:**
- Create: `erc3643/test/unit/token/TokenRequestTransferUnitTest.t.sol`
- Create: `erc3643/test/unit/mocks/CrossChainHookMock.sol`

- [ ] **Step 1: Create the hook mock**

Create `erc3643/test/unit/mocks/CrossChainHookMock.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

contract CrossChainHookMock {

    struct Sent {
        uint64 dstChainId;
        bytes32 hash;
        uint64 expiry;
        address from;
        address to;
        uint256 value;
    }

    Sent[] public sent;

    function sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) external {
        sent.push(Sent({ dstChainId: dstChainId, hash: hash, expiry: expiry, from: from, to: to, value: value }));
    }

    function sentCount() external view returns (uint256) {
        return sent.length;
    }

    function lastSent() external view returns (Sent memory) {
        return sent[sent.length - 1];
    }

}
```

- [ ] **Step 2: Write failing tests for `requestTransfer` happy path**

Create `erc3643/test/unit/token/TokenRequestTransferUnitTest.t.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { HashLib } from "contracts/libraries/HashLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";
import { CrossChainHookMock } from "../mocks/CrossChainHookMock.sol";

contract TokenRequestTransferUnitTest is TokenBaseUnitTest {

    CrossChainHookMock internal hookMock;

    address internal hookManager = makeAddr("HookManager");
    address internal alice = makeAddr("Alice");
    address internal bob = makeAddr("Bob");

    uint64 internal constant DST_CHAIN_ID = 11_155_111;

    function setUp() public override {
        super.setUp();

        hookMock = new CrossChainHookMock();

        // Wire the HOOK_MANAGER role so we can call setHook.
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("setHook(address)"));
        accessManager.setTargetFunctionRole(address(token), selectors, RolesLib.HOOK_MANAGER);
        accessManager.grantRole(RolesLib.HOOK_MANAGER, hookManager, 0);

        vm.prank(hookManager);
        token.setHook(address(hookMock));

        vm.prank(agent);
        token.unpause();
    }

    function test_requestTransfer_succeedsAndAllocatesNonce() public {
        uint64 expiry = uint64(block.timestamp + 5 minutes);
        bytes32 expectedHash = HashLib.hash(DST_CHAIN_ID, alice, bob, 100, 0, expiry);

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.TransferRequested(expectedHash, DST_CHAIN_ID, alice, bob, 100, 0, expiry);

        bytes32 returned = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);

        assertEq(returned, expectedHash);
        assertTrue(token.isPending(expectedHash));
        assertEq(token.nextNonce(alice), 1);

        assertEq(hookMock.sentCount(), 1);
        CrossChainHookMock.Sent memory s = hookMock.lastSent();
        assertEq(s.dstChainId, DST_CHAIN_ID);
        assertEq(s.hash, expectedHash);
        assertEq(s.expiry, expiry);
        assertEq(s.from, alice);
        assertEq(s.to, bob);
        assertEq(s.value, 100);
    }

    function test_requestTransfer_callableByAnyone() public {
        address stranger = makeAddr("Stranger");
        vm.prank(stranger);
        bytes32 hash = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
        assertTrue(token.isPending(hash));
    }

    function test_requestTransfer_incrementsNonceAcrossCalls() public {
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
        assertEq(token.nextNonce(alice), 2);
        assertEq(hookMock.sentCount(), 2);
    }

    function test_requestTransfer_revertsWhenPaused() public {
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenFromFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, alice));
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenToFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(bob, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, bob));
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenToNotVerified() public {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector, bob),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.TransferNotPossible.selector);
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenComplianceRejects() public {
        vm.mockCall(
            compliance,
            abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector, alice, bob, 100),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.TransferNotPossible.selector);
        token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }

    function test_requestTransfer_revertsWhenHookNotSet() public {
        // Re-deploy a fresh token with no hook configured.
        TokenBaseUnitTest fresh = TokenBaseUnitTest(address(this));
        fresh; // silence

        // Easier: just clear the hook by constructing a new token and skipping setHook.
        // The plan defers a fresh-suite helper to Task 5.5.
    }

}
```

The last test is intentionally a stub — it is fleshed out in Task 5.5 once the suite helper exists. Leave the body as-is for now.

- [ ] **Step 3: Run to verify failure**

Run: `forge test --match-path test/unit/token/TokenRequestTransferUnitTest.t.sol`
Expected: COMPILE FAIL — `Token.requestTransfer` not implemented.

### Task 5.4: Implement `requestTransfer`, `onTransferSettled`, `setHook`

**Files:**
- Modify: `erc3643/contracts/token/Token.sol`

- [ ] **Step 1: Add the implementations**

Add the imports near the top of `Token.sol` (just below the existing imports):

```solidity
import { HashLib } from "../libraries/HashLib.sol";
```

Add a new section after the `/* ----- Transfer Functions ----- */` block:

```solidity
    /* ----- Cross-Chain Authorization ----- */

    /// @inheritdoc IToken
    function requestTransfer(uint64 dstChainId, address from, address to, uint256 value)
        external
        override
        whenNotPaused
        returns (bytes32 hash)
    {
        TokenStorage storage s = _tokenStorage();

        require(s.hook != address(0), ErrorsLib.HookNotSet());
        require(!s.frozenStatus[from].addressFrozen, ErrorsLib.FrozenWallet(from));
        require(!s.frozenStatus[to].addressFrozen, ErrorsLib.FrozenWallet(to));
        require(s.identityRegistry.isVerified(to), ErrorsLib.TransferNotPossible());
        require(s.compliance.canTransfer(from, to, value), ErrorsLib.TransferNotPossible());

        uint256 nonce = s.nextNonce[from]++;
        uint64 expiry = uint64(block.timestamp) + AUTHORIZATION_TTL;
        hash = HashLib.hash(dstChainId, from, to, value, nonce, expiry);

        require(!s.pendingRequests[hash], ErrorsLib.RequestAlreadyPending(hash));
        s.pendingRequests[hash] = true;

        ITokenCrossChainHook(s.hook).sendAuthorization(dstChainId, hash, expiry, from, to, value);

        emit EventsLib.TransferRequested(hash, dstChainId, from, to, value, nonce, expiry);
    }

    /// @inheritdoc IToken
    function onTransferSettled(bytes32 hash) external override restricted {
        TokenStorage storage s = _tokenStorage();
        if (s.pendingRequests[hash]) {
            s.pendingRequests[hash] = false;
            emit EventsLib.TransferSettled(hash);
        }
    }

    /// @inheritdoc IToken
    function setHook(address newHook) external override restricted {
        require(newHook != address(0), ErrorsLib.ZeroAddress());
        _tokenStorage().hook = newHook;
        emit EventsLib.HookSet(newHook);
    }

    /// @inheritdoc IToken
    function hook() external view override returns (address) {
        return _tokenStorage().hook;
    }

    /// @inheritdoc IToken
    function nextNonce(address from) external view override returns (uint256) {
        return _tokenStorage().nextNonce[from];
    }

    /// @inheritdoc IToken
    function isPending(bytes32 hash) external view override returns (bool) {
        return _tokenStorage().pendingRequests[hash];
    }
```

- [ ] **Step 2: Build**

Run: `forge build`
Expected: PASS.

- [ ] **Step 3: Run the new tests**

Run: `forge test --match-path test/unit/token/TokenRequestTransferUnitTest.t.sol -vv`
Expected: All tests except `test_requestTransfer_revertsWhenHookNotSet` (the stub) PASS.

- [ ] **Step 4: Commit**

```bash
git add contracts/token/Token.sol contracts/token/IToken.sol test/unit/token/TokenRequestTransferUnitTest.t.sol test/unit/mocks/CrossChainHookMock.sol
git commit -m "✨ Add requestTransfer, onTransferSettled, and setHook on Token"
```

### Task 5.5: Tests for `setHook`, `onTransferSettled`, and `hook-not-set` revert

**Files:**
- Create: `erc3643/test/unit/token/TokenSetHookUnitTest.t.sol`
- Create: `erc3643/test/unit/token/TokenOnTransferSettledUnitTest.t.sol`
- Modify: `erc3643/test/unit/token/TokenRequestTransferUnitTest.t.sol`

- [ ] **Step 1: `setHook` test**

Create `erc3643/test/unit/token/TokenSetHookUnitTest.t.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenSetHookUnitTest is TokenBaseUnitTest {

    address internal hookManager = makeAddr("HookManager");
    address internal newHook = makeAddr("Hook");

    function setUp() public override {
        super.setUp();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("setHook(address)"));
        accessManager.setTargetFunctionRole(address(token), selectors, RolesLib.HOOK_MANAGER);
        accessManager.grantRole(RolesLib.HOOK_MANAGER, hookManager, 0);
    }

    function test_setHook_storesAddressAndEmits() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.HookSet(newHook);

        vm.prank(hookManager);
        token.setHook(newHook);

        assertEq(token.hook(), newHook);
    }

    function test_setHook_revertsOnZeroAddress() public {
        vm.prank(hookManager);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        token.setHook(address(0));
    }

    function test_setHook_revertsWithoutHookManagerRole() public {
        address stranger = makeAddr("Stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        token.setHook(newHook);
    }

}
```

- [ ] **Step 2: `onTransferSettled` test**

Create `erc3643/test/unit/token/TokenOnTransferSettledUnitTest.t.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";
import { CrossChainHookMock } from "../mocks/CrossChainHookMock.sol";

contract TokenOnTransferSettledUnitTest is TokenBaseUnitTest {

    CrossChainHookMock internal hookMock;
    address internal hookManager = makeAddr("HookManager");
    address internal hookCaller = makeAddr("HookCaller");
    address internal alice = makeAddr("Alice");
    address internal bob = makeAddr("Bob");

    uint64 internal constant DST_CHAIN_ID = 11_155_111;

    function setUp() public override {
        super.setUp();

        hookMock = new CrossChainHookMock();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("setHook(address)"));
        accessManager.setTargetFunctionRole(address(token), selectors, RolesLib.HOOK_MANAGER);
        accessManager.grantRole(RolesLib.HOOK_MANAGER, hookManager, 0);

        bytes4[] memory settledSelectors = new bytes4[](1);
        settledSelectors[0] = bytes4(keccak256("onTransferSettled(bytes32)"));
        accessManager.setTargetFunctionRole(address(token), settledSelectors, RolesLib.HOOK);
        accessManager.grantRole(RolesLib.HOOK, hookCaller, 0);

        vm.prank(hookManager);
        token.setHook(address(hookMock));

        vm.prank(agent);
        token.unpause();
    }

    function test_onTransferSettled_clearsPendingAndEmits() public {
        bytes32 h = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
        assertTrue(token.isPending(h));

        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.TransferSettled(h);

        vm.prank(hookCaller);
        token.onTransferSettled(h);

        assertFalse(token.isPending(h));
    }

    function test_onTransferSettled_isIdempotent() public {
        bytes32 h = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);

        vm.prank(hookCaller);
        token.onTransferSettled(h);

        // Second call: no revert, no event.
        vm.prank(hookCaller);
        token.onTransferSettled(h);

        assertFalse(token.isPending(h));
    }

    function test_onTransferSettled_revertsWithoutHookRole() public {
        bytes32 h = token.requestTransfer(DST_CHAIN_ID, alice, bob, 100);

        address stranger = makeAddr("Stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        token.onTransferSettled(h);
    }

}
```

- [ ] **Step 3: Replace the stub `test_requestTransfer_revertsWhenHookNotSet`**

In `TokenRequestTransferUnitTest.t.sol`, replace the placeholder body with a full implementation. Add to the contract:

```solidity
    function test_requestTransfer_revertsWhenHookNotSet() public {
        // Build an isolated token with no hook configured.
        TokenProxy freshProxy = new TokenProxy(
            implementationAuthority,
            identityRegistry,
            compliance,
            "Fresh",
            "FRSH",
            18,
            address(onchainId),
            address(accessManager)
        );
        Token fresh = Token(address(freshProxy));

        AccessManagerSetupLib.setupTokenRoles(accessManager, address(fresh));

        // Unpause through the agent.
        vm.prank(accessManagerAdmin);
        accessManager.grantRole(RolesLib.AGENT_PAUSER, agent, 0);
        vm.prank(agent);
        fresh.unpause();

        vm.expectRevert(ErrorsLib.HookNotSet.selector);
        fresh.requestTransfer(DST_CHAIN_ID, alice, bob, 100);
    }
```

…and add the matching imports at the top of the file:

```solidity
import { TokenProxy } from "contracts/proxy/TokenProxy.sol";
import { Token } from "contracts/token/Token.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
```

- [ ] **Step 4: Run the unit suite**

Run: `forge test --match-path "test/unit/token/Token*RequestTransfer*" -vv && forge test --match-path "test/unit/token/Token*Hook*" -vv && forge test --match-path "test/unit/token/Token*Settled*" -vv`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add test/unit/token/TokenSetHookUnitTest.t.sol test/unit/token/TokenOnTransferSettledUnitTest.t.sol test/unit/token/TokenRequestTransferUnitTest.t.sol
git commit -m "✅ Add unit tests for setHook, onTransferSettled, hook-not-set guard"
```

---

## Phase 6 — Reference chain: Hook system

### Task 6.1: `IReferenceCrossChainHook` interface

**Files:**
- Create: `erc3643/contracts/hooks/IReferenceCrossChainHook.sol`

- [ ] **Step 1: Create the interface**

Create `erc3643/contracts/hooks/IReferenceCrossChainHook.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

/// @title IReferenceCrossChainHook
/// @notice Reference-chain hook interface. Called by the Token to ship an authorization
/// message to a bridged chain. Settlement notifications received from the bridged chain are
/// dispatched directly to `Token.onTransferSettled` via the underlying transport — they are
/// not part of this interface.
interface IReferenceCrossChainHook {

    function sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) external;

}
```

- [ ] **Step 2: Replace the local `ITokenCrossChainHook` interface in `Token.sol`**

Edit `Token.sol`: delete the local `ITokenCrossChainHook` interface (added in Task 5.2 Step 2). Add the import:

```solidity
import { IReferenceCrossChainHook } from "../hooks/IReferenceCrossChainHook.sol";
```

Update `requestTransfer` to call `IReferenceCrossChainHook(s.hook).sendAuthorization(...)`.

- [ ] **Step 3: Build**

Run: `forge build`
Expected: PASS.

- [ ] **Step 4: Re-run the existing token tests**

Run: `forge test --match-path "test/unit/token/Token*RequestTransfer*" -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/hooks/IReferenceCrossChainHook.sol contracts/token/Token.sol
git commit -m "✨ Extract reference-chain hook interface"
```

### Task 6.2: `AbstractReferenceCrossChainHook`

**Files:**
- Create: `erc3643/contracts/hooks/AbstractReferenceCrossChainHook.sol`
- Create: `erc3643/test/unit/hooks/AbstractReferenceCrossChainHookUnitTest.t.sol`

- [ ] **Step 1: Write the failing test**

Create the test file:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { AbstractReferenceCrossChainHook } from "contracts/hooks/AbstractReferenceCrossChainHook.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

contract HookSpy is AbstractReferenceCrossChainHook {

    struct Call { uint64 dstChainId; bytes32 hash; uint64 expiry; address from; address to; uint256 value; }
    Call[] public calls;
    bytes32 public lastSettled;

    constructor(address accessManager, address token_) AbstractReferenceCrossChainHook(accessManager, token_) { }

    function _sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) internal override {
        calls.push(Call(dstChainId, hash, expiry, from, to, value));
    }

    function simulateSettlement(bytes32 hash) external {
        lastSettled = hash;
        _onSettlement(hash);
    }
}

contract TokenSpy {
    bytes32 public lastSettled;
    function onTransferSettled(bytes32 hash) external { lastSettled = hash; }
}

contract AbstractReferenceCrossChainHookUnitTest is Test {

    AccessManager internal accessManager;
    HookSpy internal hook;
    TokenSpy internal tokenSpy;

    address internal admin = makeAddr("admin");
    address internal tokenCaller = makeAddr("tokenCaller");

    function setUp() public {
        accessManager = new AccessManager(admin);
        tokenSpy = new TokenSpy();
        hook = new HookSpy(address(accessManager), address(tokenSpy));

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = HookSpy.sendAuthorization.selector;
        accessManager.setTargetFunctionRole(address(hook), selectors, RolesLib.TOKEN);
        accessManager.grantRole(RolesLib.TOKEN, tokenCaller, 0);
        vm.stopPrank();
    }

    function test_sendAuthorization_callsTemplate() public {
        vm.prank(tokenCaller);
        hook.sendAuthorization(11_155_111, bytes32(uint256(1)), uint64(block.timestamp + 1), address(0x1), address(0x2), 100);
        (uint64 dst,, uint64 exp, address from, address to, uint256 value) = hook.calls(0);
        assertEq(dst, 11_155_111);
        assertEq(from, address(0x1));
        assertEq(to, address(0x2));
        assertEq(value, 100);
        assertGt(exp, 0);
    }

    function test_sendAuthorization_revertsWithoutTokenRole() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, makeAddr("stranger")));
        hook.sendAuthorization(1, bytes32(0), 0, address(0), address(0), 0);
    }

    function test_onSettlement_dispatchesToToken() public {
        bytes32 h = bytes32(uint256(0xdead));
        hook.simulateSettlement(h);
        assertEq(tokenSpy.lastSettled(), h);
    }

}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/unit/hooks/AbstractReferenceCrossChainHookUnitTest.t.sol`
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement the abstract hook**

Create `erc3643/contracts/hooks/AbstractReferenceCrossChainHook.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import { IToken } from "../token/IToken.sol";
import { IReferenceCrossChainHook } from "./IReferenceCrossChainHook.sol";

/// @title AbstractReferenceCrossChainHook
/// @notice Reference-chain hook base. Subclasses implement `_sendAuthorization` for the outbound
/// transport and call `_onSettlement` from the inbound receive path.
abstract contract AbstractReferenceCrossChainHook is IReferenceCrossChainHook, AccessManaged {

    IToken internal immutable _token;

    constructor(address accessManager, address token_) AccessManaged(accessManager) {
        _token = IToken(token_);
    }

    function token() external view returns (address) {
        return address(_token);
    }

    /// @inheritdoc IReferenceCrossChainHook
    function sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) external restricted {
        _sendAuthorization(dstChainId, hash, expiry, from, to, value);
    }

    /// @dev Subclasses ship the message via their transport.
    function _sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) internal virtual;

    /// @dev Subclasses call this from their receive path to dispatch a settlement to the token.
    function _onSettlement(bytes32 hash) internal {
        _token.onTransferSettled(hash);
    }

}
```

- [ ] **Step 4: Run the test**

Run: `forge test --match-path test/unit/hooks/AbstractReferenceCrossChainHookUnitTest.t.sol -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/hooks/AbstractReferenceCrossChainHook.sol test/unit/hooks/AbstractReferenceCrossChainHookUnitTest.t.sol
git commit -m "✨ Add abstract reference-chain cross-chain hook"
```

### Task 6.3: `ChainlinkReferenceCrossChainHook`

**Files:**
- Create: `erc3643/contracts/hooks/ChainlinkReferenceCrossChainHook.sol`
- Create: `erc3643/test/unit/hooks/ChainlinkReferenceCrossChainHookUnitTest.t.sol`

- [ ] **Step 1: Write the failing test**

Create `erc3643/test/unit/hooks/ChainlinkReferenceCrossChainHookUnitTest.t.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

import { ChainlinkReferenceCrossChainHook } from "contracts/hooks/ChainlinkReferenceCrossChainHook.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

contract TokenStub {
    bytes32 public lastSettled;
    function onTransferSettled(bytes32 hash) external { lastSettled = hash; }
}

contract ChainlinkReferenceCrossChainHookUnitTest is Test {

    AccessManager internal accessManager;
    ChainlinkReferenceCrossChainHook internal hook;
    TokenStub internal tokenStub;

    address internal admin = makeAddr("admin");
    address internal hookAdmin = makeAddr("hookAdmin");
    address internal tokenCaller = makeAddr("tokenCaller");

    address internal router = makeAddr("router");
    address internal link = makeAddr("link");

    uint64 internal constant DST = 11_155_111;
    bytes32 internal constant PEER_HOOK = bytes32(uint256(uint160(0xBEEF)));

    function setUp() public {
        accessManager = new AccessManager(admin);
        tokenStub = new TokenStub();
        hook = new ChainlinkReferenceCrossChainHook(router, link, address(accessManager), address(tokenStub));

        // Mock CCIP router fee + send.
        vm.mockCall(router, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(uint256(123)));
        vm.mockCall(router, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(bytes32(uint256(0xCAFE))));
        vm.mockCall(link, abi.encodeWithSelector(LinkTokenInterface.approve.selector), abi.encode(true));

        vm.startPrank(admin);
        bytes4[] memory hookAdminSelectors = new bytes4[](1);
        hookAdminSelectors[0] = ChainlinkReferenceCrossChainHook.configureBridgedHook.selector;
        accessManager.setTargetFunctionRole(address(hook), hookAdminSelectors, RolesLib.HOOK_MANAGER);
        accessManager.grantRole(RolesLib.HOOK_MANAGER, hookAdmin, 0);

        bytes4[] memory tokenSelectors = new bytes4[](1);
        tokenSelectors[0] = bytes4(keccak256("sendAuthorization(uint64,bytes32,uint64,address,address,uint256)"));
        accessManager.setTargetFunctionRole(address(hook), tokenSelectors, RolesLib.TOKEN);
        accessManager.grantRole(RolesLib.TOKEN, tokenCaller, 0);
        vm.stopPrank();

        vm.prank(hookAdmin);
        hook.configureBridgedHook(DST, PEER_HOOK);
    }

    function test_sendAuthorization_revertsWhenDstNotConfigured() public {
        vm.prank(tokenCaller);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.DestinationChainNotConfigured.selector, uint64(80_002)));
        hook.sendAuthorization(80_002, bytes32(0), uint64(block.timestamp + 1), address(0x1), address(0x2), 100);
    }

    function test_sendAuthorization_callsCcipSendWithEncodedPayload() public {
        bytes32 h = bytes32(uint256(0xABCD));
        uint64 expiry = uint64(block.timestamp + 5 minutes);

        vm.expectCall(
            router,
            abi.encodeWithSelector(IRouterClient.ccipSend.selector)
        );

        vm.prank(tokenCaller);
        hook.sendAuthorization(DST, h, expiry, address(0x1), address(0x2), 100);
    }

    function test_ccipReceive_dispatchesSettlementToToken() public {
        bytes32 h = bytes32(uint256(0x1234));
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(0),
            sourceChainSelector: DST,
            sender: abi.encode(PEER_HOOK),
            data: abi.encode(h),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(router);
        hook.ccipReceive(msg_);

        assertEq(tokenStub.lastSettled(), h);
    }

    function test_ccipReceive_revertsOnUnknownPeer() public {
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(0),
            sourceChainSelector: DST,
            sender: abi.encode(bytes32(uint256(0xBAD))),
            data: abi.encode(bytes32(uint256(0x1234))),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(router);
        vm.expectRevert(ErrorsLib.UnauthorizedHookCaller.selector);
        hook.ccipReceive(msg_);
    }

    function test_configureBridgedHook_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit EventsLib.BridgedHookConfigured(80_002, bytes32(uint256(0x1)));

        vm.prank(hookAdmin);
        hook.configureBridgedHook(80_002, bytes32(uint256(0x1)));
    }

}
```

- [ ] **Step 2: Run the test (expect compile failure)**

Run: `forge test --match-path test/unit/hooks/ChainlinkReferenceCrossChainHookUnitTest.t.sol`
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement the Chainlink hook**

Create `erc3643/contracts/hooks/ChainlinkReferenceCrossChainHook.sol`:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { CCIPReceiver } from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { LinkTokenInterface } from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { AbstractReferenceCrossChainHook } from "./AbstractReferenceCrossChainHook.sol";

/// @title ChainlinkReferenceCrossChainHook
/// @notice Reference-chain hook that ships authorizations to bridged chains via CCIP and
/// dispatches inbound settlement notifications to the token.
contract ChainlinkReferenceCrossChainHook is AbstractReferenceCrossChainHook, CCIPReceiver {

    LinkTokenInterface internal immutable _linkToken;
    uint200 internal _gasLimit = 200_000;

    /// @dev dstChainId (CCIP selector) → bridged hook address (encoded as bytes32 for symmetry).
    mapping(uint64 dstChainId => bytes32 bridgedHook) internal _bridgedHooks;

    constructor(address router, address link, address accessManager, address token_)
        AbstractReferenceCrossChainHook(accessManager, token_)
        CCIPReceiver(router)
    {
        _linkToken = LinkTokenInterface(link);
    }

    // ----- Admin -----

    function configureBridgedHook(uint64 dstChainId, bytes32 bridgedHook) external restricted {
        _bridgedHooks[dstChainId] = bridgedHook;
        emit EventsLib.BridgedHookConfigured(dstChainId, bridgedHook);
    }

    function setGasLimit(uint200 gasLimit) external restricted {
        _gasLimit = gasLimit;
    }

    function bridgedHook(uint64 dstChainId) external view returns (bytes32) {
        return _bridgedHooks[dstChainId];
    }

    // ----- Outbound -----

    function _sendAuthorization(
        uint64 dstChainId,
        bytes32 hash,
        uint64 expiry,
        address from,
        address to,
        uint256 value
    ) internal override {
        bytes32 peer = _bridgedHooks[dstChainId];
        require(peer != bytes32(0), ErrorsLib.DestinationChainNotConfigured(dstChainId));

        Client.EVM2AnyMessage memory request = Client.EVM2AnyMessage({
            receiver: abi.encode(peer),
            data: abi.encode(hash, expiry, from, to, value),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({ gasLimit: _gasLimit, allowOutOfOrderExecution: true })
            ),
            feeToken: address(_linkToken)
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fees = router.getFee(dstChainId, request);
        _linkToken.approve(address(router), fees);
        router.ccipSend(dstChainId, request);
    }

    // ----- Inbound -----

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        bytes32 expected = _bridgedHooks[message.sourceChainSelector];
        bytes32 sender = abi.decode(message.sender, (bytes32));
        require(expected != bytes32(0) && sender == expected, ErrorsLib.UnauthorizedHookCaller());

        bytes32 hash = abi.decode(message.data, (bytes32));
        _onSettlement(hash);
    }

}
```

- [ ] **Step 4: Run the test**

Run: `forge test --match-path test/unit/hooks/ChainlinkReferenceCrossChainHookUnitTest.t.sol -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/hooks/ChainlinkReferenceCrossChainHook.sol test/unit/hooks/ChainlinkReferenceCrossChainHookUnitTest.t.sol
git commit -m "✨ Add Chainlink CCIP reference-chain cross-chain hook"
```

### Task 6.4: AccessManager wiring updates

**Files:**
- Modify: `erc3643/contracts/libraries/AccessManagerSetupLib.sol`

- [ ] **Step 1: Add `setHook` and `onTransferSettled` to the token role wiring**

Edit `setupTokenRoles` and append at the end (just before the closing brace of the function):

```solidity
    // ------ HOOK_MANAGER role ------
    functions = new bytes4[](1);
    functions[0] = Token.setHook.selector;
    accessManager.setTargetFunctionRole(token, functions, RolesLib.HOOK_MANAGER);

    // ------ HOOK role ------
    functions = new bytes4[](1);
    functions[0] = Token.onTransferSettled.selector;
    accessManager.setTargetFunctionRole(token, functions, RolesLib.HOOK);
```

- [ ] **Step 2: Add a hook-side setup helper**

Add a new function inside `AccessManagerSetupLib`:

```solidity
function setupReferenceHookRoles(IAccessManager accessManager, address hook, address token) external {
    // ------ TOKEN role on hook (token calls sendAuthorization) ------
    bytes4[] memory functions = new bytes4[](1);
    functions[0] = bytes4(keccak256("sendAuthorization(uint64,bytes32,uint64,address,address,uint256)"));
    accessManager.setTargetFunctionRole(hook, functions, RolesLib.TOKEN);

    // ------ HOOK_MANAGER role on hook (admin configures bridged peers) ------
    bytes4[] memory adminFns = new bytes4[](2);
    adminFns[0] = bytes4(keccak256("configureBridgedHook(uint64,bytes32)"));
    adminFns[1] = bytes4(keccak256("setGasLimit(uint200)"));
    accessManager.setTargetFunctionRole(hook, adminFns, RolesLib.HOOK_MANAGER);

    // The hook contract must hold the HOOK role so it can call Token.onTransferSettled.
    accessManager.grantRole(RolesLib.HOOK, hook, 0);
    // The token contract must hold the TOKEN role so it can call hook.sendAuthorization.
    accessManager.grantRole(RolesLib.TOKEN, token, 0);
}
```

- [ ] **Step 3: Add labels for the new roles**

Add three entries to the `setupLabels` `labels` array literal (and grow the fixed-size array from 13 to 16):

```solidity
RoleLabel[16] memory labels = [
    // ... existing entries ...
    RoleLabel({ roleId: RolesLib.SPENDING_ADMIN, label: "TREX-Suite Admin: Spending" }),
    RoleLabel({ roleId: RolesLib.HOOK_MANAGER, label: "TREX-Suite Hook Manager" }),
    RoleLabel({ roleId: RolesLib.HOOK, label: "TREX-Suite Hook" }),
    RoleLabel({ roleId: RolesLib.TOKEN, label: "TREX-Suite Token" })
];
```

- [ ] **Step 4: Build and run the AccessManager setup tests**

Run: `forge build && forge test --match-path "test/unit/**" -vv`
Expected: PASS. If existing setup tests assert exact selector counts, update them in this step.

- [ ] **Step 5: Commit**

```bash
git add contracts/libraries/AccessManagerSetupLib.sol test
git commit -m "✨ Wire HOOK_MANAGER, HOOK, and TOKEN roles for cross-chain transfers"
```

---

## Phase 7 — Cross-repo verification

### Task 7.1: Hash vector parity

**Files:**
- Modify: `erc3643/test/unit/libraries/HashLibUnitTest.t.sol`
- Modify: `erc3643-cc-light/test/unit/HashLibUnitTest.t.sol`

- [ ] **Step 1: Lock identical reference vectors in both repos**

Both repos already include `test_hash_referenceVector` from Tasks 1.1 and 4.1. Re-read both files and verify the inputs `(uint64(11_155_111), 0xAa00...0001, 0xbB00...0002, 123, 7, 1_700_000_300)` match exactly. If not, harmonize them.

- [ ] **Step 2: Run both repos' hash tests**

```bash
cd /Users/pgonday/ws/erc3643-cc-light && forge test --match-test test_hash_referenceVector -vv
cd /Users/pgonday/wt/erc3643/access-manager-develop && forge test --match-test test_hash_referenceVector -vv
```

Expected: BOTH PASS, with the same `expected` value computed.

- [ ] **Step 3: Commit any harmonization**

If either file was edited in Step 1, commit in the appropriate repo:

```bash
git add test/unit/.../HashLibUnitTest.t.sol
git commit -m "✅ Harmonize hash reference vector across repos"
```

### Task 7.2: Full suite green in both repos

- [ ] **Step 1: Run cc-light**

```bash
cd /Users/pgonday/ws/erc3643-cc-light
forge fmt --check
forge build
forge test
```

Expected: All checks PASS.

- [ ] **Step 2: Run reference chain**

```bash
cd /Users/pgonday/wt/erc3643/access-manager-develop
forge fmt --check
forge build
forge test
```

Expected: All checks PASS.

- [ ] **Step 3: Commit any formatting fixes**

If `forge fmt --check` reports issues, run `forge fmt` and commit in the appropriate repo:

```bash
git add -A
git commit -m "🎨 forge fmt"
```

---

## Open work tracked but not implemented in this plan

- **CCIP fee funding helpers** (script + docs for funding the reference-side hook with LINK).
- **`prunePending` admin helper** on the reference-chain Token for clearing expired-but-never-settled requests.
- **Multi-bridged-chain integration test** end-to-end (this plan only covers single-destination wiring).
- **Address-binding in the hash** (committing token contract addresses on both sides) — listed in spec §8 as a v2 hardening item.
