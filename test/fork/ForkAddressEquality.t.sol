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

import { Token } from "contracts/token/Token.sol";
import { BytecodeStore } from "scripts/deploy/lib/BytecodeStore.sol";
import { DeployConfig, DeployConfigLib } from "scripts/deploy/lib/DeployConfig.sol";
import { Row } from "scripts/deploy/lib/PlanTypes.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice Same config, same addresses, whatever the chain: the whole deployment on the target fork and on a second
///         fork running as the other target chain (chain id 1 from Base Sepolia, 84532 from mainnet) lands every row
///         at the same address, and a suite and an identity deployed with the same salts land at the same addresses
///         too. Off chain 1, SafeToL2Setup switches the Safes to the L2 singleton; on chain 1 they keep the L1
///         singleton, at the same Safe address. The rows are also checked against the table computed from
///         deploy/config/mainnet.json, the content of deploy/addresses/mainnet.json.
/// @dev A chain without the Safe contracts at all is covered by test/unit/deploy/LocalDeployment.t.sol, which
///      deploys them from the vendored init code. It cannot be combined with a fork here: Foundry carries state
///      deployed before the first fork switch into that fork, so the second deployment would find everything done.
contract ForkAddressEqualityTest is ForkBase {

    struct Landing {
        Row[] rows;
        bool[] hasCode;
        address token;
        address identity;
        address deploymentSafeSingleton;
    }

    function test_sameAddressesOnBothTargetChains() public {
        DeployConfig memory c = _config();
        Landing memory first = _deployEverything(c);

        _switchToTheOtherChain();
        Landing memory second = _deployEverything(c);
        Row[] memory mainnetTable = _addressTable(DeployConfigLib.load("mainnet"));

        assertEq(first.rows.length, second.rows.length);
        assertEq(first.rows.length, mainnetTable.length);
        for (uint256 i = 0; i < first.rows.length; i++) {
            assertEq(first.rows[i].expected, second.rows[i].expected, first.rows[i].id);
            assertEq(first.rows[i].expected, mainnetTable[i].expected, first.rows[i].id);
            assertTrue(first.hasCode[i] && second.hasCode[i], first.rows[i].id);
        }
        assertEq(first.token, second.token, "suite address differs");
        assertEq(first.identity, second.identity, "identity address differs");
        (address l1, address l2) = _onMainnet()
            ? (first.deploymentSafeSingleton, second.deploymentSafeSingleton)
            : (second.deploymentSafeSingleton, first.deploymentSafeSingleton);
        assertEq(l1, BytecodeStore.SAFE, "chain 1 Safe runs the L1 singleton");
        assertEq(l2, BytecodeStore.SAFE_L2, "other chains run the L2 singleton");
    }

    /// @dev A chain onboarded years later should hand governance to the owners of that day, not to the original
    ///      ones. The three governance Safes enter no contract address (CREATE3 salts depend on the Deployment Safe
    ///      only), so a config with rotated governance owners moves only those three rows; every protocol contract,
    ///      suite and identity lands where it does everywhere else, and the new Safes hold the roles.
    function test_laterChainWithCurrentGovernanceOwners() public {
        DeployConfig memory c = _config();
        Landing memory first = _deployEverything(c);

        _switchToTheOtherChain();
        DeployConfig memory rotated = _config();
        rotated.protocolAdminSafe.owners = _newOwners("admin", 5);
        rotated.upgradeCouncilSafe.owners = _newOwners("council", 3);
        rotated.operationsSafe.owners = _newOwners("operations", 3);
        Landing memory later = _deployEverything(rotated);

        assertEq(first.rows.length, later.rows.length);
        for (uint256 i = 0; i < first.rows.length; i++) {
            bytes32 id = keccak256(bytes(first.rows[i].id));
            bool governanceSafe = id == keccak256("protocolAdminSafe") || id == keccak256("upgradeCouncilSafe")
                || id == keccak256("operationsSafe");
            if (governanceSafe) assertNotEq(first.rows[i].expected, later.rows[i].expected, first.rows[i].id);
            else assertEq(first.rows[i].expected, later.rows[i].expected, first.rows[i].id);
        }
        assertEq(first.token, later.token, "suite address differs");
        assertEq(first.identity, later.identity, "identity address differs");
    }

    function _switchToTheOtherChain() internal {
        vm.selectFork(vm.createFork(_forkUrl(), _forkBlock()));
        vm.chainId(_otherChainId());
        assertEq(_addresses(_config()).genesis.code.length, 0, "the second fork must start clean");
    }

    function _newOwners(string memory prefix, uint256 n) internal returns (address[] memory owners) {
        owners = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            owners[i] = makeAddr(string.concat(prefix, " owner ", vm.toString(i)));
        }
    }

    function _deployEverything(DeployConfig memory c) internal returns (Landing memory l) {
        _deployAndConfigure(c);
        _handOver(c);
        l.rows = _addressTable(c);
        l.hasCode = new bool[](l.rows.length);
        for (uint256 i = 0; i < l.rows.length; i++) {
            l.hasCode[i] = l.rows[i].expected.code.length > 0;
        }
        (Token token,) = _deploySuite(c, "same-everywhere");
        l.token = address(token);
        l.identity = address(_selfDeployIdentity(c, alice, "same-everywhere-alice"));
        l.deploymentSafeSingleton = address(uint160(uint256(vm.load(_addresses(c).deploymentSafe, bytes32(0)))));
    }

}
