// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

pragma solidity 0.8.30;

import { CommonBase } from "@forge-std/Base.sol";
import { console } from "@forge-std/console.sol";

import { PlanBuilder } from "./PlanBuilder.sol";
import { Planner } from "./Planner.sol";
import { DeployConfig, SafeConfig } from "./lib/DeployConfig.sol";
import { Actor, Probe, ProbeKind, Status, Step } from "./lib/PlanTypes.sol";
import { ISafe, SafeLib } from "./lib/SafeLib.sol";
import { TxBuilderJson } from "./lib/TxBuilderJson.sol";

/// @title PlanExecutor
/// @notice Runs a plan's steps, skipping what is already done and stopping on anything unexpected.
/// @dev Before sending anything, every step is probed: `Done` steps are skipped, a single `Mismatch` stops the run
///      before the first transaction. After each step is sent, its probe must read `Done`, or the run stops.
///      So a run can be repeated, resumed after a failure, and survives someone else having deployed a CREATE2
///      implementation first (its address commits to its bytecode).
///
///      Modes:
///      - Broadcast: every step is broadcast. Safe steps are sent as `approveHash` from each signing owner and
///        `execTransaction` with pre-approved signatures, so the owners' keys must be available to forge (local
///        anvil only: `--private-keys` with anvil's default keys, see deploy/README.md).
///      - SafeBatches: steps sent by a key are broadcast; the first run of pending Safe steps is written as
///        Transaction Builder files under deployments/<env>/batches/ and the run stops there. Once the Safe has
///        executed them, running again carries on from the next step.
///      - InTest: like Broadcast with `vm.prank` instead of broadcasts; Safe steps go through the real Safe with
///        each owner pranked into `approveHash`, so a fork test keeps the real Deployment Safe address.
abstract contract PlanExecutor is PlanBuilder, CommonBase {

    enum Mode {
        Broadcast,
        SafeBatches,
        InTest
    }

    /// @dev Transaction gas cap from EIP-7825; every step and every batch must stay below it.
    uint256 internal constant TX_GAS_CAP = 1 << 24;

    Mode internal executorMode;
    /// @dev Sender of `Anyone` steps in InTest mode.
    address internal anyoneSender = address(0xA11CE);

    // What the last runs did, for scripts to report and tests to assert.
    uint256 internal stepsSent;
    uint256 internal maxStepGas;
    string internal maxStepGasId;
    string[] internal batchFiles;

    PlanBuilder private immutable PLANNER = new Planner();

    function _engine() internal view override returns (PlanBuilder) {
        return PLANNER;
    }

    /// @notice The planner's address, for fork tests that must keep it across `vm.selectFork` (makePersistent).
    function _plannerAddress() internal view returns (address) {
        return address(PLANNER);
    }

    error StepMismatch(string id);
    error StepNotApplied(string id);
    error StepReverted(string id, bytes reason);
    error StepOverGasCap(string id, uint256 gasUsed);

    // ---------------------------------------------------------------------------------------------------------
    // Probing
    // ---------------------------------------------------------------------------------------------------------

    function _status(Probe memory p) internal view returns (Status) {
        if (p.kind == ProbeKind.None) return Status.Pending;
        if (p.kind == ProbeKind.CodeNonEmpty) return p.target.code.length > 0 ? Status.Done : Status.Pending;
        if (p.kind == ProbeKind.CodeHashMasked) {
            if (p.target.code.length == 0) return Status.Pending;
            return _engine().planMaskedHashAt(p.target, p.maskStarts, p.maskLengths) == p.expected
                ? Status.Done
                : Status.Mismatch;
        }
        if (p.kind == ProbeKind.ExactCodeHash) {
            if (p.target.code.length == 0) return Status.Pending;
            return p.target.codehash == p.expected ? Status.Done : Status.Mismatch;
        }
        if (p.kind == ProbeKind.StaticCallState || p.kind == ProbeKind.StaticCallStrict) {
            if (p.target.code.length == 0) return Status.Pending;
            (bool ok, bytes memory ret) = p.target.staticcall(p.callData);
            if (ok && keccak256(ret) == p.expected) return Status.Done;
            return p.kind == ProbeKind.StaticCallState ? Status.Pending : Status.Mismatch;
        }
        if (p.kind == ProbeKind.StorageSlotEquals) {
            if (p.target.code.length == 0) return Status.Pending;
            return vm.load(p.target, abi.decode(p.callData, (bytes32))) == p.expected ? Status.Done : Status.Pending;
        }
        if (p.kind == ProbeKind.StaticCallNonZero) {
            if (p.target.code.length == 0) return Status.Pending;
            (bool ok, bytes memory ret) = p.target.staticcall(p.callData);
            return ok && ret.length >= 32 && abi.decode(ret, (uint256)) != 0 ? Status.Done : Status.Pending;
        }
        // Grant delay / target admin delay, pending or in force: the value the manager will apply.
        if (p.target.code.length == 0) return Status.Pending;
        uint32 target = p.kind == ProbeKind.GrantDelayTarget
            ? _pendingGrantDelay(p.target, abi.decode(p.callData, (uint64)))
            : _pendingTargetAdminDelay(p.target, abi.decode(p.callData, (address)));
        return target == uint32(uint256(p.expected)) ? Status.Done : Status.Pending;
    }

    /// @dev OpenZeppelin 5.x AccessManager storage: `_targets` at slot 0, `_roles` at slot 1. A role's second slot
    ///      packs admin (bits 0-63), guardian (64-127) and the grant delay (128-239); a target's second slot packs
    ///      the admin delay (bits 0-111). A `Time.Delay` keeps the value it changes to in its low 32 bits, whether the
    ///      change is in force or not. Checked in test/unit/deploy/LocalDeployment.t.sol.
    function _pendingGrantDelay(address manager, uint64 roleId) internal view returns (uint32) {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(roleId), uint256(1)))) + 1);
        return uint32(uint256(vm.load(manager, slot)) >> 128);
    }

    function _pendingTargetAdminDelay(address manager, address target) internal view returns (uint32) {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(target, uint256(0)))) + 1);
        return uint32(uint256(vm.load(manager, slot)));
    }

    function _statuses(Step[] memory steps) internal view returns (Status[] memory st) {
        st = new Status[](steps.length);
        for (uint256 i = 0; i < steps.length; i++) {
            st[i] = _status(steps[i].probe);
        }
    }

    /// @notice How many steps are not done yet; reverts on the first mismatch.
    function _pendingCount(Step[] memory steps) internal view returns (uint256 pending) {
        Status[] memory st = _statuses(steps);
        for (uint256 i = 0; i < steps.length; i++) {
            if (st[i] == Status.Mismatch) revert StepMismatch(steps[i].id);
            if (st[i] == Status.Pending) pending++;
        }
    }

    function _printStatus(Step[] memory steps) internal view {
        Status[] memory st = _statuses(steps);
        for (uint256 i = 0; i < steps.length; i++) {
            string memory s = st[i] == Status.Done ? "done    " : st[i] == Status.Pending ? "pending " : "MISMATCH";
            console.log("%s %s", s, steps[i].id);
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Running
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Runs `steps`. Returns false when it stopped at a Safe batch (SafeBatches mode), true when done.
    function _run(DeployConfig memory c, Step[] memory steps, string memory phase) internal returns (bool finished) {
        Status[] memory st = _statuses(steps);
        for (uint256 i = 0; i < steps.length; i++) {
            if (st[i] == Status.Mismatch) revert StepMismatch(steps[i].id);
        }
        Addrs memory a = _addresses(c);
        for (uint256 i = 0; i < steps.length; i++) {
            if (_status(steps[i].probe) == Status.Done) continue;
            address safe = _safeOf(a, steps[i].actor);
            if (safe != address(0) && executorMode == Mode.SafeBatches) {
                _writeBatches(c, safe, steps, i, phase);
                return false;
            }
            _send(c, a, steps[i]);
            if (steps[i].probe.kind != ProbeKind.None && _status(steps[i].probe) != Status.Done) {
                revert StepNotApplied(steps[i].id);
            }
        }
        return true;
    }

    function _safeOf(Addrs memory a, Actor actor) internal pure returns (address) {
        if (actor == Actor.DeploymentSafe) return a.deploymentSafe;
        if (actor == Actor.ProtocolAdminSafe) return a.protocolAdminSafe;
        if (actor == Actor.UpgradeCouncilSafe) return a.upgradeCouncilSafe;
        if (actor == Actor.OperationsSafe) return a.operationsSafe;
        return address(0);
    }

    function _safeConfigOf(DeployConfig memory c, Actor actor) internal pure returns (SafeConfig memory) {
        if (actor == Actor.DeploymentSafe) return c.deploymentSafe;
        if (actor == Actor.ProtocolAdminSafe) return c.protocolAdminSafe;
        if (actor == Actor.UpgradeCouncilSafe) return c.upgradeCouncilSafe;
        return c.operationsSafe;
    }

    function _send(DeployConfig memory c, Addrs memory a, Step memory step) internal {
        address safe = _safeOf(a, step.actor);
        if (safe != address(0)) {
            _execThroughSafe(_safeConfigOf(c, step.actor), safe, step);
        } else {
            address sender = step.actor == Actor.Bootstrap ? c.bootstrap : address(0);
            _call(step.id, sender, step.to, step.value, step.data);
        }
        stepsSent++;
    }

    /// @dev Sends one call from `sender` (address(0): the default broadcaster, or `anyoneSender` in tests).
    function _call(string memory id, address sender, address to, uint256 value, bytes memory data)
        internal
        returns (bytes memory ret)
    {
        if (executorMode == Mode.InTest) {
            vm.prank(sender == address(0) ? anyoneSender : sender);
        } else if (sender == address(0)) {
            vm.broadcast();
        } else {
            vm.broadcast(sender);
        }
        uint256 before = gasleft();
        bool ok;
        (ok, ret) = to.call{ value: value }(data);
        uint256 used = before - gasleft();
        if (!ok) revert StepReverted(id, ret);
        if (used > maxStepGas) {
            maxStepGas = used;
            maxStepGasId = id;
        }
        if (used >= TX_GAS_CAP) revert StepOverGasCap(id, used);
    }

    /// @dev Pre-approved-hash flow: each signing owner calls `approveHash`, then the first one executes.
    function _execThroughSafe(SafeConfig memory s, address safe, Step memory step) internal {
        ISafe wallet = ISafe(safe);
        bytes32 txHash = wallet.getTransactionHash(
            step.to, step.value, step.data, 0, 0, 0, 0, address(0), address(0), wallet.nonce()
        );
        address[] memory signers = new address[](s.threshold);
        for (uint256 i = 0; i < s.threshold; i++) {
            signers[i] = s.owners[i];
            _call(
                string.concat(step.id, ".approveHash"), signers[i], safe, 0, abi.encodeCall(ISafe.approveHash, (txHash))
            );
        }
        bytes memory exec = abi.encodeCall(
            ISafe.execTransaction,
            (
                step.to,
                step.value,
                step.data,
                0,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                SafeLib.approvedHashSignatures(signers)
            )
        );
        bytes memory ret = _call(step.id, signers[0], safe, 0, exec);
        if (!abi.decode(ret, (bool))) revert StepReverted(step.id, ret);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Safe batches
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Writes the consecutive pending steps of one Safe, starting at `from`, as Transaction Builder files,
    ///      split so that no file needs more than `maxBatchGas`.
    function _writeBatches(DeployConfig memory c, address safe, Step[] memory steps, uint256 from, string memory phase)
        internal
    {
        uint256 until = from;
        while (until < steps.length && steps[until].actor == steps[from].actor) {
            until++;
        }
        uint256[] memory gasOf = _measureFromSafe(c, safe, steps, from, until);
        string memory dir = string.concat("deployments/", c.env, "/batches/");
        vm.createDir(dir, true);
        uint256 start = from;
        uint256 part = 1;
        while (start < until) {
            uint256 end = _chunkEnd(c, steps, gasOf, from, start, until);
            (Step[] memory chunk, uint256 total) = _collectChunk(steps, gasOf, from, start, end);
            _writeChunk(c, safe, chunk, total, string.concat(dir, phase, "-", _u(part), ".json"));
            start = end;
            part++;
        }
    }

    /// @dev Gas of each pending step when sent by the Safe, simulated in order (later steps may need earlier
    ///      ones), then rolled back.
    function _measureFromSafe(DeployConfig memory c, address safe, Step[] memory steps, uint256 from, uint256 until)
        internal
        returns (uint256[] memory gasOf)
    {
        gasOf = new uint256[](until - from);
        uint256 snapshot = vm.snapshotState();
        for (uint256 i = from; i < until; i++) {
            if (_status(steps[i].probe) == Status.Done) continue;
            vm.prank(safe);
            uint256 before = gasleft();
            (bool ok, bytes memory ret) = steps[i].to.call{ value: steps[i].value }(steps[i].data);
            gasOf[i - from] = before - gasleft();
            if (!ok) revert StepReverted(steps[i].id, ret);
            require(
                gasOf[i - from] <= c.maxBatchGas,
                string.concat("PlanExecutor: step alone over maxBatchGas: ", steps[i].id)
            );
        }
        vm.revertToState(snapshot);
    }

    /// @dev First index after `start` that would push the chunk over `maxBatchGas` (at least one step per chunk).
    function _chunkEnd(
        DeployConfig memory c,
        Step[] memory steps,
        uint256[] memory gasOf,
        uint256 from,
        uint256 start,
        uint256 until
    ) internal view returns (uint256 end) {
        uint256 total;
        bool any;
        end = start;
        while (end < until) {
            if (_status(steps[end].probe) != Status.Done) {
                if (any && total + gasOf[end - from] > c.maxBatchGas) break;
                total += gasOf[end - from];
                any = true;
            }
            end++;
        }
    }

    /// @dev The pending steps in [start, end) and the gas they need together.
    function _collectChunk(Step[] memory steps, uint256[] memory gasOf, uint256 from, uint256 start, uint256 end)
        internal
        view
        returns (Step[] memory chunk, uint256 total)
    {
        uint256 count;
        for (uint256 i = start; i < end; i++) {
            if (_status(steps[i].probe) != Status.Done) count++;
        }
        chunk = new Step[](count);
        uint256 k;
        for (uint256 i = start; i < end; i++) {
            if (_status(steps[i].probe) != Status.Done) {
                chunk[k++] = steps[i];
                total += gasOf[i - from];
            }
        }
    }

    function _writeChunk(DeployConfig memory c, address safe, Step[] memory chunk, uint256 total, string memory file)
        internal
    {
        string memory description = string.concat(
            _u(chunk.length),
            " calls, about ",
            _u(total),
            " gas. Generated by scripts/deploy; run the script again once executed."
        );
        TxBuilderJson.write(file, c.chainId, safe, string.concat("T-REX ", c.env, " batch"), description, chunk);
        batchFiles.push(file);
        console.log("Safe batch written: %s (%s calls, ~%s gas)", file, chunk.length, total);
    }

}
