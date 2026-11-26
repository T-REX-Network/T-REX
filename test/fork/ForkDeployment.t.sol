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

import { BytecodeStore } from "scripts/deploy/lib/BytecodeStore.sol";
import { DeployConfig } from "scripts/deploy/lib/DeployConfig.sol";
import { Row } from "scripts/deploy/lib/PlanTypes.sol";
import { ISafeProxyFactory } from "scripts/deploy/lib/SafeLib.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice The full deployment on a Base Sepolia fork, doubling as the chain qualification check: the anchor
///         and the canonical Safe contracts are there byte for byte, every contract fits the size limits, every
///         transaction and Safe call fits the EIP-7825 gas cap, and the handover leaves a verified state.
contract ForkDeploymentTest is ForkBase {

    uint256 internal constant MAX_RUNTIME = 24_576;
    uint256 internal constant MAX_INITCODE = 49_152;

    function test_chainQualifiesAndDeploymentVerifies() public {
        DeployConfig memory c = _config();

        // Qualification before anything is sent.
        assertEq(BytecodeStore.ANCHOR.codehash, BytecodeStore.ANCHOR_CODEHASH, "anchor");
        BytecodeStore.VendorContract[] memory safes = BytecodeStore.safeContracts();
        for (uint256 i = 0; i < safes.length; i++) {
            assertEq(safes[i].canonical.codehash, BytecodeStore.safeRuntimeCodeHash(safes[i].name), safes[i].name);
        }
        // Safe addresses are predicted from the chain's own SafeProxyFactory here; the vendored copy (used offline and
        // on a bare chain) must be the same bytes, or the committed table would disagree with the chain.
        assertEq(
            ISafeProxyFactory(BytecodeStore.SAFE_PROXY_FACTORY).proxyCreationCode(),
            BytecodeStore.safeProxyCreationCode(),
            "vendored SafeProxy creation code"
        );
        emit log_named_uint("block gas limit", block.gaslimit);

        _deployAndConfigure(c);
        _handOver(c);

        // Every row of the address table holds code at its address, within the size limit.
        Row[] memory rows = _addressTable(c);
        for (uint256 i = 0; i < rows.length; i++) {
            assertGt(rows[i].expected.code.length, 0, rows[i].id);
            assertLe(rows[i].expected.code.length, MAX_RUNTIME, rows[i].id);
        }
        _assertInitCodeSizes();

        // Gas: every step (Safe executions included) and a real suite deployment stay under the cap.
        assertLt(maxStepGas, TX_GAS_CAP, maxStepGasId);
        emit log_named_uint("largest deployment step gas", maxStepGas);
        (, uint256 suiteGas) = _deploySuite(c, "qualification");
        assertLt(suiteGas, TX_GAS_CAP, "deployTREXSuite over the EIP-7825 cap");
        emit log_named_uint("deployTREXSuite gas (through the Operations Safe)", suiteGas);
    }

    function _assertInitCodeSizes() internal view {
        BytecodeStore.ReleaseContract[] memory list = BytecodeStore.releaseContracts();
        for (uint256 i = 0; i < list.length; i++) {
            uint256 size = bytes(BytecodeStore.unlinkedInitCodeHex(list[i].name)).length / 2 - 1;
            // Constructor arguments add at most a few hundred bytes.
            assertLe(size + 512, MAX_INITCODE, list[i].name);
        }
    }

    /// @dev The P-256 precompile is recorded, not required: ONCHAINID falls back to the Solidity verifier. Asked of
    ///      the forked chain with `eth_call`, since the local EVM runs this repo's `evm_version` (cancun).
    function test_recordsP256Precompile() public {
        uint256 key = 0xA11CE;
        bytes32 digest = keccak256("T-REX P-256 probe");
        (bytes32 r, bytes32 s) = vm.signP256(key, digest);
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        string memory params = string.concat(
            "[{\"to\":\"0x0000000000000000000000000000000000000100\",\"data\":\"",
            vm.toString(abi.encode(digest, r, s, x, y)),
            "\"},\"latest\"]"
        );
        bytes memory ret = vm.rpc("eth_call", params);
        bool present = ret.length == 32 && abi.decode(ret, (uint256)) == 1;
        emit log_named_string("P-256 precompile (chain head)", present ? "present" : "absent");
    }

}
