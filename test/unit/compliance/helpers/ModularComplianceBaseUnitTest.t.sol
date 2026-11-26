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

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
import { AccessManagerHelper } from "test/integration/helpers/AccessManagerHelper.sol";
import { TicketsHarness } from "test/integration/helpers/TicketsHarness.sol";
import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

/// @notice Base for the ModularCompliance unit suites: one compliance behind a beacon proxy and a real
///         AccessManager, its selectors wired through `AccessManagerSetupLib`, the token and the registry
///         replaced by addresses ready for `vm.mockCall`.
/// @dev The implementation is {TicketsHarness}, a ModularCompliance that also exposes the validation
///      layer's internal hooks; suites that need none of them use it as a plain compliance.
abstract contract ModularComplianceBaseUnitTest is AccessManagerHelper {

    TicketsHarness public mc;
    address public mcBeacon;

    address public token = makeAddr("Token");
    address public registry = makeAddr("Registry");
    address public stranger = makeAddr("Stranger");

    function setUp() public virtual {
        _deploySuiteManager();
        mcBeacon = BeaconProxyDeployer.newBeacon(address(new TicketsHarness()));
        mc = TicketsHarness(
            BeaconProxyDeployer.newProxy(
                mcBeacon,
                abi.encodeCall(ModularCompliance.init, (token, address(suiteManager), new address[](0), new bytes[](0)))
            )
        );
        _setupComplianceRoles(address(mc));
        _grantOwnerRole(address(this));
        _grantComplianceManagerRole(address(this));
        _grantAgentRole(agentAccount);
        _grantValidationKeeperRole(keeperAccount);
    }

    address public agentAccount = makeAddr("Agent");
    address public keeperAccount = makeAddr("Keeper");

    uint256 private _saltNonce;
    /// @dev The salt the last `_salt()` returned, so a test can name the id a refused request would have taken.
    bytes32 internal lastSalt;

    /// @dev A fresh salt per request, as a requester's backend would supply one.
    function _salt() internal returns (bytes32) {
        lastSalt = keccak256(abi.encode(address(this), ++_saltNonce));
        return lastSalt;
    }

    /// @dev The id a request gets, as the compliance builds it: a move, the keys of both wallets and of the
    ///  spender, the asked bounds and the salt.
    function _ticketId(
        bytes memory from,
        bytes memory to,
        bytes memory spender,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return TicketLib.ticketIdOf(
            ITickets.TicketKind.MOVE,
            WalletKeyLib.canonicalKey(from),
            WalletKeyLib.canonicalKey(to),
            keccak256(spender),
            requestedMin,
            requestedMax,
            salt
        );
    }

    /// @dev The issued ask block hash of `id`, read straight off the compliance's storage so that building a leg
    ///  makes no call and consumes neither a prank nor an expected emit. `validations` is the namespace's fourth
    ///  field and `askBlockHash` the record's first.
    function _issuedAskBlockHash(bytes32 id) internal view returns (bytes32) {
        bytes32 base = 0x518dcda4927033bd42da8dd6047b92b4a950cebbc5bdd8461a5e9bb9c0545400;
        return vm.load(address(mc), keccak256(abi.encode(id, uint256(base) + 3)));
    }

    /// @dev The request sent with the last salt was refused: nothing was recorded under its id.
    function _assertNothingRecorded(
        bytes memory from,
        bytes memory to,
        bytes memory spender,
        uint256 requestedMin,
        uint256 requestedMax
    ) internal view {
        bytes32 refusedId = _ticketId(from, to, spender, requestedMin, requestedMax, lastSalt);
        assertEq(mc.ticketOf(refusedId).fromIdentity, address(0), "nothing recorded");
    }

}
