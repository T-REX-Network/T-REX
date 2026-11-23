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

import { Script, console } from "@forge-std/Script.sol";
import { Vm } from "@forge-std/Vm.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { UpgradePlanner } from "./UpgradePlanner.sol";
import { BytecodeStore } from "./lib/BytecodeStore.sol";
import { DeployConfig, DeployConfigLib } from "./lib/DeployConfig.sol";
import { Actor, Method, Row } from "./lib/PlanTypes.sol";

/// @title DeployScriptBase
/// @notice What every deployment script shares: loading the config for the chain it runs on, the chain checks,
///         and the end-of-run summary.
abstract contract DeployScriptBase is Script, UpgradePlanner {

    /// @dev EIP-7951 / RIP-7212 P-256 verification precompile.
    address internal constant P256_PRECOMPILE = address(0x100);

    function _load(string memory env) internal view returns (DeployConfig memory c) {
        c = DeployConfigLib.load(env);
        require(
            block.chainid == c.chainId,
            string.concat("chain id ", vm.toString(block.chainid), " does not match deploy/config/", env, ".json")
        );
    }

    /// @notice The config for this chain, after checking the build against the committed address table.
    /// @param full Every row's address and init code hash (Genesis, protocol, configuration, verification). Without
    ///        it, only the rows an upgrade talks to: everything but the CREATE2 libraries and implementations, whose
    ///        bytes are the new release's by design.
    function _loadPinned(string memory env, bool full) internal view returns (DeployConfig memory c) {
        c = _load(env);
        _requireTableMatches(c, full);
    }

    function _tablePath(string memory env) internal pure returns (string memory) {
        return string.concat("deploy/addresses/", env, ".json");
    }

    /// @notice The address table is the pin: the build must give exactly the committed rows. Skipped on a local
    ///         chain (31337), so rehearsals never depend on a committed table.
    function _requireTableMatches(DeployConfig memory c, bool full) internal view {
        if (block.chainid == 31337) return;
        _compareTable(c, full);
    }

    /// @notice Reverts, naming the differing rows and the table's commit, unless the build gives the committed table.
    function _compareTable(DeployConfig memory c, bool full) internal view {
        string memory path = _tablePath(c.env);
        require(vm.isFile(path), string.concat(path, " missing: run AddressTable run(", c.env, ",<commit>)"));
        string memory json = vm.readFile(path);
        string memory commit = vm.keyExistsJson(json, ".commit") ? vm.parseJsonString(json, ".commit") : "unknown";
        Row[] memory rows = _addressTable(c);
        string memory diff;
        uint256 count;
        for (uint256 i = 0; i < rows.length; i++) {
            string memory key = string.concat(".rows[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, key)) {
                diff = string.concat(diff, " ", rows[i].id, "(missing)");
                count++;
                continue;
            }
            if (!full && rows[i].method == Method.Create2CreateX) continue;
            bool same = keccak256(bytes(vm.parseJsonString(json, string.concat(key, ".id"))))
                    == keccak256(bytes(rows[i].id))
                && vm.parseJsonAddress(json, string.concat(key, ".expected")) == rows[i].expected;
            if (full) {
                same = same && vm.parseJsonBytes32(json, string.concat(key, ".initCodeHash")) == rows[i].initCodeHash;
            }
            if (!same) {
                diff = string.concat(diff, " ", rows[i].id);
                count++;
            }
        }
        if (vm.keyExistsJson(json, string.concat(".rows[", vm.toString(rows.length), "]"))) {
            diff = string.concat(diff, " (extra committed rows)");
            count++;
        }
        require(
            count == 0,
            string.concat(
                "build does not match ",
                path,
                " (generated at commit ",
                commit,
                "): differing rows",
                diff,
                ". Check out that commit, or regenerate the table and review the diff."
            )
        );
    }

    /// @notice Logs of `topic0` from `emitter`, fetched in chunks of `span` blocks (RPCs cap a single range).
    function _fetchLogs(address emitter, bytes32 topic0, uint256 fromBlock, uint256 span)
        internal
        view
        returns (LogEntry[] memory out)
    {
        require(span > 0, "span must be positive");
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = topic0;
        LogEntry[] memory acc = new LogEntry[](0);
        for (uint256 start = fromBlock; start <= block.number; start += span) {
            uint256 end = start + span - 1 > block.number ? block.number : start + span - 1;
            Vm.EthGetLogs[] memory got = vm.eth_getLogs(start, end, emitter, topics);
            LogEntry[] memory grown = new LogEntry[](acc.length + got.length);
            for (uint256 i = 0; i < acc.length; i++) {
                grown[i] = acc[i];
            }
            for (uint256 i = 0; i < got.length; i++) {
                grown[acc.length + i] = LogEntry(got[i].emitter, got[i].topics, got[i].data);
            }
            acc = grown;
        }
        return acc;
    }

    /// @notice Every governance log since `fromBlock`: grants and function mappings on both managers, and
    ///         IdentityUtilities' AccessControl grants.
    function _governanceLogs(DeployConfig memory c, uint256 fromBlock, uint256 span)
        internal
        view
        returns (LogEntry[] memory all)
    {
        Addrs memory a = _addresses(c);
        LogEntry[][] memory parts = new LogEntry[][](5);
        parts[0] = _fetchLogs(a.platformAM, IAccessManager.RoleGranted.selector, fromBlock, span);
        parts[1] = _fetchLogs(a.upgradeAM, IAccessManager.RoleGranted.selector, fromBlock, span);
        parts[2] = _fetchLogs(a.platformAM, IAccessManager.TargetFunctionRoleUpdated.selector, fromBlock, span);
        parts[3] = _fetchLogs(a.upgradeAM, IAccessManager.TargetFunctionRoleUpdated.selector, fromBlock, span);
        parts[4] = _fetchLogs(a.identityUtilities, ACCESS_CONTROL_ROLE_GRANTED, fromBlock, span);
        uint256 n;
        for (uint256 i = 0; i < parts.length; i++) {
            n += parts[i].length;
        }
        all = new LogEntry[](n);
        uint256 k;
        for (uint256 i = 0; i < parts.length; i++) {
            for (uint256 j = 0; j < parts[i].length; j++) {
                all[k++] = parts[i][j];
            }
        }
    }

    /// @notice The governance logs since `fromBlock`, after proving `fromBlock` covers both managers' whole life:
    ///         neither has code at `fromBlock - 1`. `fromBlock` comes from the operator being checked, and a later
    ///         block would hide earlier grants.
    function _provenGovernanceLogs(DeployConfig memory c, uint256 fromBlock, uint256 span)
        internal
        returns (LogEntry[] memory)
    {
        Addrs memory a = _addresses(c);
        if (fromBlock > 0) {
            require(
                !_hadCodeAt(a.platformAM, fromBlock - 1) && !_hadCodeAt(a.upgradeAM, fromBlock - 1),
                "fromBlock is after the managers were deployed: the scan would miss earlier grants"
            );
        }
        return _governanceLogs(c, fromBlock, span);
    }

    function _hadCodeAt(address target, uint256 blockNumber) internal returns (bool) {
        // eth_getCode wants the block as a quantity, without leading zeros.
        string memory params = string.concat("[\"", vm.toString(target), "\",\"", _quantity(blockNumber), "\"]");
        return vm.rpc("eth_getCode", params).length > 0;
    }

    function _quantity(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0x0";
        bytes memory digits = "0123456789abcdef";
        uint256 len;
        for (uint256 x = n; x > 0; x >>= 4) {
            len++;
        }
        bytes memory out = new bytes(len + 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < len; i++) {
            out[len + 1 - i] = digits[(n >> (4 * i)) & 0xf];
        }
        return string(out);
    }

    /// @notice Runs {_unexpectedGovernance} over `logs` and reverts on any finding.
    function _requireGovernanceAsPlanned(DeployConfig memory c, LogEntry[] memory logs, bool bootstrapExempt)
        internal
        view
    {
        string[] memory failures = _unexpectedGovernance(c, logs, bootstrapExempt);
        _printFailures(failures);
        require(failures.length == 0, "governance differs from the role tables");
        console.log("%s governance logs scanned; every holder and mapping is planned.", logs.length);
    }

    /// @notice The anchor must be the canonical keyless CREATE2 factory, byte for byte: every address hangs on it.
    function _requireAnchor() internal view {
        require(
            BytecodeStore.ANCHOR.codehash == BytecodeStore.ANCHOR_CODEHASH,
            "anchor missing or different: this chain cannot host the canonical address set"
        );
    }

    /// @notice Where a Safe v1.4.1 contract is missing, the Safe Singleton Factory must be there to recreate it.
    function _requireSafeFactoryIfNeeded() internal view {
        BytecodeStore.VendorContract[] memory safes = BytecodeStore.safeContracts();
        for (uint256 i = 0; i < safes.length; i++) {
            if (safes[i].canonical.code.length == 0) {
                require(
                    BytecodeStore.SAFE_SINGLETON_FACTORY.codehash == BytecodeStore.ANCHOR_CODEHASH,
                    string.concat("Safe ", safes[i].name, " missing and no Safe Singleton Factory to deploy it")
                );
                return;
            }
        }
    }

    /// @notice Whether the chain verifies P-256 signatures natively (passkey signers in ONCHAINID depend on it).
    /// @dev Asked of the chain itself with `eth_call`: forge simulates with this repo's `evm_version` (cancun),
    ///      which predates the precompile, so a local call would always say no. Without an RPC, falls back to the
    ///      local EVM.
    function _p256PrecompilePresent() internal returns (bool) {
        uint256 key = 0xA11CE;
        bytes32 digest = keccak256("T-REX P-256 probe");
        (bytes32 r, bytes32 s) = vm.signP256(key, digest);
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        bytes memory input = abi.encode(digest, r, s, x, y);
        string memory params = string.concat(
            "[{\"to\":\"", vm.toString(P256_PRECOMPILE), "\",\"data\":\"", vm.toString(input), "\"},\"latest\"]"
        );
        try vm.rpc("eth_call", params) returns (bytes memory ret) {
            return ret.length == 32 && abi.decode(ret, (uint256)) == 1;
        } catch {
            (bool ok, bytes memory ret) = P256_PRECOMPILE.staticcall(input);
            return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
        }
    }

    function _chainReport() internal {
        console.log("chain id:               %s", block.chainid);
        console.log("block gas limit:        %s", block.gaslimit);
        console.log("P-256 precompile:       %s", _p256PrecompilePresent() ? "present" : "absent");
        console.log(
            "anchor code hash ok:    %s", BytecodeStore.ANCHOR.codehash == BytecodeStore.ANCHOR_CODEHASH ? "yes" : "no"
        );
    }

    function _summary() internal view {
        console.log("transactions sent:      %s", stepsSent);
        console.log("largest step gas:       %s (%s)", maxStepGas, maxStepGasId);
        for (uint256 i = 0; i < batchFiles.length; i++) {
            console.log("Safe batch to execute:  %s", batchFiles[i]);
        }
        if (batchFiles.length > 0) console.log("Execute the batches in the Safe, then run the same command again.");
    }

    function _printFailures(string[] memory failures) internal pure {
        for (uint256 i = 0; i < failures.length; i++) {
            console.log("FAIL %s", failures[i]);
        }
        console.log("%s failed checks", failures.length);
    }

    function _methodName(Method m) internal pure returns (string memory) {
        if (m == Method.Create2Anchor) return "CREATE2 (anchor)";
        if (m == Method.Create2SafeSingletonFactory) return "CREATE2 (Safe Singleton Factory)";
        if (m == Method.Create2CreateX) return "CREATE2 (Genesis Deployer)";
        if (m == Method.Create3CreateX) return "CREATE3 (Genesis Deployer)";
        if (m == Method.SafeProxyFactory) return "SafeProxyFactory.createProxyWithNonce";
        if (m == Method.Nonce) return "CREATE (deployer nonce)";
        return "CREATE3 (inside contract)";
    }

    function _actorName(Actor a) internal pure returns (string memory) {
        if (a == Actor.Anyone) return "anyone";
        if (a == Actor.DeploymentSafe) return "Deployment Safe";
        if (a == Actor.Bootstrap) return "Bootstrap Operator";
        if (a == Actor.ProtocolAdminSafe) return "Protocol Admin Safe";
        if (a == Actor.UpgradeCouncilSafe) return "Upgrade Council Safe";
        return "Operations Safe";
    }

    /// @notice The address table as JSON (deploy/addresses/<env>.json).
    function _addressTableJson(DeployConfig memory c, string memory commit) internal view returns (string memory json) {
        Row[] memory rows = _addressTable(c);
        Addrs memory a = _addresses(c);
        json = string.concat(
            "{\n  \"env\": \"",
            c.env,
            "\",\n  \"chainId\": ",
            vm.toString(c.chainId),
            ",\n  \"release\": \"",
            c.release,
            "\",\n  \"commit\": \"",
            commit,
            "\",\n  \"anchor\": \"",
            vm.toString(BytecodeStore.ANCHOR),
            "\",\n  \"genesisDeployer\": \"",
            vm.toString(a.genesis),
            "\",\n  \"deploymentSafe\": \"",
            vm.toString(a.deploymentSafe),
            "\",\n  \"rows\": ["
        );
        for (uint256 i = 0; i < rows.length; i++) {
            json = string.concat(json, i == 0 ? "\n" : ",\n", _rowJson(rows[i]));
        }
        json = string.concat(json, "\n  ]\n}\n");
    }

    function _rowJson(Row memory r) internal pure returns (string memory) {
        return string.concat(
            "    { \"id\": \"",
            r.id,
            "\", \"contract\": \"",
            r.contractName,
            "\", \"method\": \"",
            _methodName(r.method),
            "\", \"salt\": \"",
            vm.toString(r.salt),
            "\", \"initCodeHash\": \"",
            vm.toString(r.initCodeHash),
            "\", \"expected\": \"",
            vm.toString(r.expected),
            "\", \"actor\": \"",
            _actorName(r.actor),
            "\" }"
        );
    }

}
