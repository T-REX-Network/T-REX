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

/// @notice Who sends a step. The actor decides the channel: a broadcast from a key, or a Safe transaction.
enum Actor {
    // Permissionless: the anchor, Genesis Deployer CREATE2, the Safe factories. Any key can send it.
    Anyone,
    // CREATE3 through the Genesis Deployer: the salt is bound to the Deployment Safe, so only it can send.
    DeploymentSafe,
    // Configuration while the Bootstrap Operator still holds ADMIN_ROLE on both managers.
    Bootstrap,
    ProtocolAdminSafe,
    UpgradeCouncilSafe,
    OperationsSafe
}

/// @notice How an address in the address table is made.
enum Method {
    Create2Anchor,
    Create2SafeSingletonFactory,
    Create2CreateX,
    Create3CreateX,
    SafeProxyFactory,
    // CREATE by a deployed contract at a known nonce (the authority's beacons, the UtilityChecker proxy).
    Nonce,
    // OpenZeppelin Create3 run by a contract (the IdentityFactory's identity beacon).
    Create3InContract
}

/// @notice What a probe checks to tell whether a step already happened.
enum ProbeKind {
    // Always pending: the step is sent every run (labels, which have no getter).
    None,
    // Done once the address has code. Enough for CREATE2 rows: the address commits to the init code.
    CodeNonEmpty,
    // Runtime code equal to the committed runtime with immutable ranges zeroed. For CREATE3 rows, whose address
    // does not commit to the code.
    CodeHashMasked,
    // Runtime code hash exactly equal (vendored contracts at their canonical address).
    ExactCodeHash,
    // A view call whose result differs from `expected` means the step has not been applied yet.
    StaticCallState,
    // A view call whose result differs from `expected` means someone else did something else: stop.
    StaticCallStrict,
    // The grant delay of a role on an AccessManager, pending or in force, read from storage.
    GrantDelayTarget,
    // The admin delay of a target on an AccessManager, pending or in force, read from storage.
    TargetAdminDelayTarget,
    // A storage slot of `target` (slot in `callData`) equal to `expected`: an ERC-1967 implementation slot.
    StorageSlotEquals,
    // A view call returning a non-zero word: an operation scheduled on an AccessManager.
    StaticCallNonZero
}

enum Status {
    Pending,
    Done,
    Mismatch
}

struct Probe {
    ProbeKind kind;
    address target;
    bytes callData;
    bytes32 expected;
    // CodeHashMasked: ranges zeroed before hashing. GrantDelayTarget / TargetAdminDelayTarget: unused.
    uint256[] maskStarts;
    uint256[] maskLengths;
}

/// @notice One transaction of the plan.
struct Step {
    string id;
    Actor actor;
    address to;
    uint256 value;
    bytes data;
    Probe probe;
}

/// @notice One row of the address table.
struct Row {
    string id;
    string contractName;
    Method method;
    bytes32 salt;
    bytes32 initCodeHash;
    address expected;
    Actor actor;
}

/// @notice A growable list of steps (memory arrays cannot be pushed to).
struct StepList {
    Step[] items;
    uint256 length;
}

/// @notice A growable list of address table rows.
struct RowList {
    Row[] items;
    uint256 length;
}

library PlanLists {

    function newSteps(uint256 capacity) internal pure returns (StepList memory list) {
        list.items = new Step[](capacity);
    }

    function push(StepList memory list, Step memory step) internal pure {
        if (list.length == list.items.length) {
            Step[] memory grown = new Step[](list.items.length * 2 + 8);
            for (uint256 i = 0; i < list.length; i++) {
                grown[i] = list.items[i];
            }
            list.items = grown;
        }
        list.items[list.length++] = step;
    }

    function toArray(StepList memory list) internal pure returns (Step[] memory out) {
        out = new Step[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            out[i] = list.items[i];
        }
    }

    function newRows(uint256 capacity) internal pure returns (RowList memory list) {
        list.items = new Row[](capacity);
    }

    function push(RowList memory list, Row memory row) internal pure {
        if (list.length == list.items.length) {
            Row[] memory grown = new Row[](list.items.length * 2 + 8);
            for (uint256 i = 0; i < list.length; i++) {
                grown[i] = list.items[i];
            }
            list.items = grown;
        }
        list.items[list.length++] = row;
    }

    function toArray(RowList memory list) internal pure returns (Row[] memory out) {
        out = new Row[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            out[i] = list.items[i];
        }
    }

}

library Probes {

    function none() internal pure returns (Probe memory p) { }

    function code(address target) internal pure returns (Probe memory p) {
        p.kind = ProbeKind.CodeNonEmpty;
        p.target = target;
    }

    function exactCode(address target, bytes32 codeHash) internal pure returns (Probe memory p) {
        p.kind = ProbeKind.ExactCodeHash;
        p.target = target;
        p.expected = codeHash;
    }

    function maskedCode(address target, bytes32 maskedHash, uint256[] memory starts, uint256[] memory lengths)
        internal
        pure
        returns (Probe memory p)
    {
        p.kind = ProbeKind.CodeHashMasked;
        p.target = target;
        p.expected = maskedHash;
        p.maskStarts = starts;
        p.maskLengths = lengths;
    }

    function state(address target, bytes memory callData, bytes memory expectedReturn)
        internal
        pure
        returns (Probe memory p)
    {
        p.kind = ProbeKind.StaticCallState;
        p.target = target;
        p.callData = callData;
        p.expected = keccak256(expectedReturn);
    }

    function strict(address target, bytes memory callData, bytes memory expectedReturn)
        internal
        pure
        returns (Probe memory p)
    {
        p.kind = ProbeKind.StaticCallStrict;
        p.target = target;
        p.callData = callData;
        p.expected = keccak256(expectedReturn);
    }

    function grantDelay(address manager, uint64 roleId, uint32 delay) internal pure returns (Probe memory p) {
        p.kind = ProbeKind.GrantDelayTarget;
        p.target = manager;
        p.callData = abi.encode(roleId);
        p.expected = bytes32(uint256(delay));
    }

    function slotEquals(address target, bytes32 slot, bytes32 value) internal pure returns (Probe memory p) {
        p.kind = ProbeKind.StorageSlotEquals;
        p.target = target;
        p.callData = abi.encode(slot);
        p.expected = value;
    }

    function nonZero(address target, bytes memory callData) internal pure returns (Probe memory p) {
        p.kind = ProbeKind.StaticCallNonZero;
        p.target = target;
        p.callData = callData;
    }

    function targetAdminDelay(address manager, address target, uint32 delay) internal pure returns (Probe memory p) {
        p.kind = ProbeKind.TargetAdminDelayTarget;
        p.target = manager;
        p.callData = abi.encode(target);
        p.expected = bytes32(uint256(delay));
    }

}
