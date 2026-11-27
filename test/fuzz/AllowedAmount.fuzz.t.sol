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

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { TicketsHarness } from "test/integration/helpers/TicketsHarness.sol";
import { RecordingModule, RuleOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { ModularComplianceBaseUnitTest } from "test/unit/compliance/helpers/ModularComplianceBaseUnitTest.t.sol";
import { TokenReservationStub } from "test/unit/compliance/helpers/TokenReservationStub.sol";
import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

/// @dev The three properties of an issued range, over random requests, balances and rule answers: it sits
///      inside what the caller asked for, never above what the wallet holds, and does not depend on the order
///      the rules were bound in.
///
///      A rule answers one number, so it can only lower the maximum. The caller's minimum is never raised,
///      which is the property the first assertion pins.
contract AllowedAmountFuzzTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;

    bytes internal from = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("aliceOnPolygon"));
    bytes internal to = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygon"));
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");

    TicketsHarness internal reversed;
    RuleOnlyModule internal a;
    RuleOnlyModule internal b;

    function setUp() public override {
        super.setUp();
        reversed = TicketsHarness(
            BeaconProxyDeployer.newProxy(
                mcBeacon,
                abi.encodeCall(ModularCompliance.init, (token, address(suiteManager), new address[](0), new bytes[](0)))
            )
        );
        _setupComplianceRoles(address(reversed));

        a = RuleOnlyModule(
            address(new ModuleProxy(address(new RuleOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        b = RuleOnlyModule(
            address(new ModuleProxy(address(new RuleOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        mc.addModule(address(a));
        mc.addModule(address(b));
        reversed.addModule(address(b));
        reversed.addModule(address(a));

        bytes32 polygon = _evmChainKey(POLYGON);
        ITickets.AskLimits memory limits = ITickets.AskLimits({
            openTicketsPerIdentity: type(uint32).max,
            asksPerIdentityPerWindow: type(uint32).max,
            askWindow: 1 days,
            smallestAmount: 1
        });
        mc.setValidityWindows(15 minutes, 25 minutes);
        mc.setWaitingTime(polygon, 95 minutes);
        mc.setAskLimits(limits);
        reversed.setValidityWindows(15 minutes, 25 minutes);
        reversed.setWaitingTime(polygon, 95 minutes);
        reversed.setAskLimits(limits);

        // The wallet's room, the receipt route the tickets go out on and the token's pause are the stub's, with
        // real state; the registry is the token's.
        vm.etch(token, address(new TokenReservationStub()).code);
        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", from), abi.encode(aliceIdentity));
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", to), abi.encode(bobIdentity));
        vm.mockCall(registry, abi.encodeWithSignature("isWalletVerified(bytes)", to), abi.encode(true));
    }

    function testFuzz_requestTransferValidation_NeverWidensNeverExceedsTheBalanceAndIgnoresTheOrder(
        uint96 requestedMin,
        uint96 requestedMax,
        uint96 balance,
        uint96 allowedByA,
        uint96 allowedByB
    ) public {
        if (requestedMin > requestedMax) {
            (requestedMin, requestedMax) = (requestedMax, requestedMin);
        }
        // Each compliance reserves against the same stub, so the wallet holds enough for both requests.
        TokenReservationStub(token).setBridgedBalance(from, 2 * uint256(balance));
        a.setAllowedAmount(allowedByA);
        b.setAllowedAmount(allowedByB);

        if (requestedMax == 0) {
            vm.prank(aliceIdentity);
            vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BelowSmallestAmount.selector, 0, 1));
            mc.askToMove(from, to, requestedMin, requestedMax, "", _salt());
            return;
        }
        // The asked maximum is part of the id, so a request above the free balance is refused, never narrowed.
        if (requestedMax > uint256(balance)) {
            TokenReservationStub(token).setBridgedBalance(from, balance);
            vm.prank(aliceIdentity);
            vm.expectRevert(
                abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, from, uint256(balance), requestedMax)
            );
            mc.askToMove(from, to, requestedMin, requestedMax, "", _salt());
            return;
        }

        uint256 expectedMin = requestedMin;
        uint256 expectedMax = _min(requestedMax, _min(allowedByA, allowedByB));

        if (expectedMin > expectedMax || expectedMax == 0) {
            bytes4 expected =
                expectedMin > expectedMax ? ErrorsLib.EmptyValidationRange.selector : ErrorsLib.ZeroValue.selector;
            vm.prank(aliceIdentity);
            vm.expectPartialRevert(expected);
            mc.askToMove(from, to, requestedMin, requestedMax, "", _salt());
            vm.prank(aliceIdentity);
            vm.expectPartialRevert(expected);
            reversed.askToMove(from, to, requestedMin, requestedMax, "", _salt());
            return;
        }

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(from, to, requestedMin, requestedMax, "", _salt());
        vm.prank(aliceIdentity);
        bytes32 reversedId = reversed.askToMove(from, to, requestedMin, requestedMax, "", _salt());
        ITickets.Ticket memory validation = mc.ticketOf(id);
        ITickets.Ticket memory reversedValidation = reversed.ticketOf(reversedId);

        assertEq(validation.amountMin, requestedMin, "the caller's minimum is never raised");
        assertLe(validation.amountMax, requestedMax, "never wider than the request");
        assertLe(validation.amountMax, balance, "never above what the wallet holds");
        assertLe(validation.amountMin, validation.amountMax);
        assertEq(validation.amountMax, expectedMax, "the smallest rule answer wins");
        assertEq(reversedValidation.amountMin, validation.amountMin, "the bind order does not matter");
        assertEq(reversedValidation.amountMax, validation.amountMax);
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
    }

    function _evmChainKey(uint256 chainId) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}
