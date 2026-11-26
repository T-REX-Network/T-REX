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

import { Vm } from "@forge-std/Vm.sol";

/// @notice One Safe: its owners in the exact order they are passed to `setup`, its threshold and salt nonce.
///         All three are part of the Safe's address, so they are frozen once the Safe exists anywhere.
struct SafeConfig {
    address[] owners;
    uint256 threshold;
    uint256 saltNonce;
}

/// @notice The deployment configuration, read from deploy/config/<env>.json.
struct DeployConfig {
    string env;
    uint256 chainId;
    // Release directory under deploy/bytecode/ whose committed bytecode is deployed.
    string release;
    // Salt the Genesis Deployer (CreateX copy) is created with through the anchor. Frozen.
    bytes32 genesisSalt;
    // CreateX salt of every CREATE2 row: first 20 bytes random (permissionless). Frozen per release.
    bytes32 create2Salt;
    // Temporary admin of both AccessManagers until the handover; renounces everything at the end.
    address bootstrap;
    uint8 versionMajor;
    uint8 versionMinor;
    uint8 versionPatch;
    // Largest gas a single Safe batch may need; batches are split below it (one batch is one transaction).
    uint256 maxBatchGas;
    // Delay tiers (OpenZeppelin review: 5 days for code, 48 h for power, 24 h for configuration hurting tokens).
    uint32 codeDelay;
    uint32 powerDelay;
    uint32 configDelay;
    SafeConfig deploymentSafe;
    SafeConfig protocolAdminSafe;
    SafeConfig upgradeCouncilSafe;
    SafeConfig operationsSafe;
}

/// @title DeployConfigLib
/// @notice Loads deploy/config/<env>.json.
library DeployConfigLib {

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function path(string memory env) internal pure returns (string memory) {
        return string.concat("deploy/config/", env, ".json");
    }

    function load(string memory env) internal view returns (DeployConfig memory c) {
        string memory json = VM.readFile(path(env));
        c.env = env;
        c.chainId = VM.parseJsonUint(json, ".chainId");
        c.release = VM.parseJsonString(json, ".release");
        c.genesisSalt = VM.parseJsonBytes32(json, ".genesisSalt");
        c.create2Salt = VM.parseJsonBytes32(json, ".create2Salt");
        c.bootstrap = VM.parseJsonAddress(json, ".bootstrapOperator");
        uint256[] memory version = VM.parseJsonUintArray(json, ".initialVersion");
        require(version.length == 3, "DeployConfig: initialVersion must be [major, minor, patch]");
        c.versionMajor = uint8(version[0]);
        c.versionMinor = uint8(version[1]);
        c.versionPatch = uint8(version[2]);
        c.maxBatchGas = VM.parseJsonUint(json, ".maxBatchGas");
        c.codeDelay = uint32(VM.parseJsonUint(json, ".delays.code"));
        c.powerDelay = uint32(VM.parseJsonUint(json, ".delays.power"));
        c.configDelay = uint32(VM.parseJsonUint(json, ".delays.config"));
        c.deploymentSafe = _safe(json, ".safes.deployment");
        c.protocolAdminSafe = _safe(json, ".safes.protocolAdmin");
        c.upgradeCouncilSafe = _safe(json, ".safes.upgradeCouncil");
        c.operationsSafe = _safe(json, ".safes.operations");
        _validate(c);
    }

    function _safe(string memory json, string memory key) private pure returns (SafeConfig memory s) {
        s.owners = VM.parseJsonAddressArray(json, string.concat(key, ".owners"));
        s.threshold = VM.parseJsonUint(json, string.concat(key, ".threshold"));
        s.saltNonce = VM.parseJsonUint(json, string.concat(key, ".saltNonce"));
    }

    function _validate(DeployConfig memory c) private pure {
        require(address(bytes20(c.create2Salt)) != address(0), "DeployConfig: create2Salt needs a random prefix");
        require(c.bootstrap != address(0), "DeployConfig: bootstrapOperator is zero");
        require(c.maxBatchGas > 0 && c.maxBatchGas < 1 << 24, "DeployConfig: maxBatchGas must be below 2^24");
        require(c.codeDelay >= c.powerDelay && c.powerDelay >= c.configDelay, "DeployConfig: delay tiers out of order");
        _validateSafe(c.deploymentSafe);
        _validateSafe(c.protocolAdminSafe);
        _validateSafe(c.upgradeCouncilSafe);
        _validateSafe(c.operationsSafe);
        // Two Safes with the same owners, threshold and salt nonce would be one address holding both roles.
        SafeConfig[4] memory safes = [c.deploymentSafe, c.protocolAdminSafe, c.upgradeCouncilSafe, c.operationsSafe];
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                require(
                    keccak256(abi.encode(safes[i].owners, safes[i].threshold, safes[i].saltNonce))
                        != keccak256(abi.encode(safes[j].owners, safes[j].threshold, safes[j].saltNonce)),
                    "DeployConfig: two Safes have the same owners, threshold and salt nonce"
                );
            }
        }
    }

    function _validateSafe(SafeConfig memory s) private pure {
        require(s.owners.length > 0, "DeployConfig: a Safe has no owners");
        require(s.threshold > 0 && s.threshold <= s.owners.length, "DeployConfig: Safe threshold out of range");
    }

}
