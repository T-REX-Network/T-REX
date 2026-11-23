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

import { DeployConfig } from "scripts/deploy/lib/DeployConfig.sol";
import { Step } from "scripts/deploy/lib/PlanTypes.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice Re-running and resuming: a second run sends nothing, a run that stopped half-way finishes with the same
///         addresses, a CREATE2 implementation someone else deployed first is accepted, and unexpected code at a
///         CREATE3 address stops the run before anything is sent.
contract ForkResumeTest is ForkBase {

    function test_secondRunSendsNothing() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        uint256 sent = stepsSent;
        _run(c, _genesisSteps(c), "genesis");
        _run(c, _protocolSteps(c), "protocol");
        _run(c, _configureSteps(c), "configure");
        // Labels have no getter and are re-sent; nothing else is.
        assertEq(stepsSent - sent, _labels(_addresses(c)).length, "a re-run sent more than the labels");
    }

    function test_resumesAfterAPartialRun() public {
        DeployConfig memory c = _config();
        _run(c, _genesisSteps(c), "genesis");
        Step[] memory all = _protocolSteps(c);
        Step[] memory firstPart = new Step[](all.length / 2);
        for (uint256 i = 0; i < firstPart.length; i++) {
            firstPart[i] = all[i];
        }
        _run(c, firstPart, "protocol-part");
        assertEq(_pendingCount(all), all.length - firstPart.length);
        _run(c, all, "protocol");
        assertEq(_pendingCount(all), 0);
        _run(c, _configureSteps(c), "configure");
        _handOver(c);
    }

    function test_acceptsAnImplementationDeployedByAStranger() public {
        DeployConfig memory c = _config();
        _run(c, _genesisSteps(c), "genesis");
        Step[] memory steps = _protocolSteps(c);
        Step memory tokenImpl = _find(steps, "Token.implementation");
        // Anyone can send a CREATE2 row: the address commits to the code, so it is the same contract.
        vm.prank(stranger);
        (bool ok,) = tokenImpl.to.call(tokenImpl.data);
        assertTrue(ok, "stranger deploy");
        assertGt(_addresses(c).tokenImpl.code.length, 0);
        uint256 sent = stepsSent;
        _run(c, steps, "protocol");
        assertEq(stepsSent - sent, steps.length - 1, "the stranger's step must be skipped");
        _run(c, _configureSteps(c), "configure");
        _handOver(c);
    }

    function test_stopsOnUnexpectedCodeBeforeSending() public {
        DeployConfig memory c = _config();
        _run(c, _genesisSteps(c), "genesis");
        vm.etch(_addresses(c).trexFactory, hex"6080604052600080fd");
        uint256 sent = stepsSent;
        vm.expectRevert(abi.encodeWithSelector(StepMismatch.selector, "T-REX:TREXFactory"));
        this.runProtocol();
        assertEq(stepsSent, sent);
        assertEq(_addresses(c).platformAM.code.length, 0, "nothing deployed before the mismatch was found");
    }

    function runProtocol() external {
        DeployConfig memory c = _config();
        _run(c, _protocolSteps(c), "protocol");
    }

    function _find(Step[] memory steps, string memory id) internal pure returns (Step memory) {
        for (uint256 i = 0; i < steps.length; i++) {
            if (keccak256(bytes(steps[i].id)) == keccak256(bytes(id))) return steps[i];
        }
        revert(string.concat("no step ", id));
    }

}
