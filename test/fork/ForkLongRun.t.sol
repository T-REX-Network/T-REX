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

import { IIdentity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { ReputationRegistry } from "@onchain-id/solidity/contracts/reputation/ReputationRegistry.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { DeployConfig, SafeConfig } from "scripts/deploy/lib/DeployConfig.sol";
import { Actor, Row } from "scripts/deploy/lib/PlanTypes.sol";
import { ISafe, SafeLib } from "scripts/deploy/lib/SafeLib.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice The protocol over a long life: months of suites, identities and transfers alongside delayed operational
///         changes, everyday calls under the EIP-7825 transaction gas cap, and a new chain joining later.
contract ForkLongRunTest is ForkBase {

    uint256 internal constant MONTHS = 6;

    /// @dev Six months of business: every month a new suite, the same two investors registered in it, a mint and a
    ///      transfer. Meanwhile the Operations Safe changes a reputation score and trusts a gateway, each taking
    ///      effect only after its 24 h delay. Everything still verifies at the end.
    function test_monthsOfActivity() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        // Identities bind for good: each investor deploys one and reuses it in every suite.
        IIdentity aliceId = _selfDeployIdentity(c, alice, "long-run-alice");
        IIdentity bobId = _selfDeployIdentity(c, bob, "long-run-bob");
        Token[] memory tokens = new Token[](MONTHS);

        for (uint256 m = 0; m < MONTHS; m++) {
            vm.warp(block.timestamp + 30 days);
            string memory salt = string.concat("month-", vm.toString(m));
            (tokens[m],) = _deploySuite(c, salt);
            _commissionAgent(tokens[m]);
            _register(tokens[m], alice, aliceId);
            _register(tokens[m], bob, bobId);
            vm.prank(agent);
            tokens[m].mint(alice, 100 + m);
            vm.prank(alice);
            tokens[m].transfer(bob, 10);

            if (m == 2) _changeReputation(c, a, address(aliceId));
            if (m == 4) _trustGateway(c, a);
        }

        uint256 aliceTotal;
        uint256 bobTotal;
        for (uint256 m = 0; m < MONTHS; m++) {
            aliceTotal += tokens[m].balanceOf(alice);
            bobTotal += tokens[m].balanceOf(bob);
            assertEq(tokens[m].totalSupply(), 100 + m, "supply per suite");
        }
        assertEq(bobTotal, 10 * MONTHS);
        assertEq(aliceTotal + bobTotal, 100 * MONTHS + (MONTHS * (MONTHS - 1)) / 2);
        _assertVerified(c);
    }

    function _changeReputation(DeployConfig memory c, Addrs memory a, address identity) internal {
        uint128 target = 777;
        bytes memory set = abi.encodeCall(ReputationRegistry.setReputation, (identity, target));
        _fromSafe(
            c,
            Actor.OperationsSafe,
            a.platformAM,
            abi.encodeCall(IAccessManager.schedule, (a.reputationRegistry, set, 0))
        );
        vm.warp(block.timestamp + c.configDelay - 1);
        assertTrue(ReputationRegistry(a.reputationRegistry).reputationOf(identity) != target, "not before the delay");
        vm.warp(block.timestamp + 2);
        _fromSafe(
            c, Actor.OperationsSafe, a.platformAM, abi.encodeCall(IAccessManager.execute, (a.reputationRegistry, set))
        );
        assertEq(ReputationRegistry(a.reputationRegistry).reputationOf(identity), target, "after the delay");
    }

    function _trustGateway(DeployConfig memory c, Addrs memory a) internal {
        address gateway = makeAddr("bridge gateway");
        bytes memory trust = abi.encodeCall(TrustedGatewayRegistry.setTrustedGateway, (gateway, true, 0));
        _expectSafeCallReverts(Actor.OperationsSafe, a.gatewayRegistry, trust);
        _fromSafe(
            c,
            Actor.OperationsSafe,
            a.platformAM,
            abi.encodeCall(IAccessManager.schedule, (a.gatewayRegistry, trust, 0))
        );
        assertFalse(TrustedGatewayRegistry(a.gatewayRegistry).isTrusted(gateway));
        vm.warp(block.timestamp + c.configDelay + 1);
        _fromSafe(
            c, Actor.OperationsSafe, a.platformAM, abi.encodeCall(IAccessManager.execute, (a.gatewayRegistry, trust))
        );
        assertTrue(TrustedGatewayRegistry(a.gatewayRegistry).isTrusted(gateway));
    }

    /// @dev EIP-7825 caps a transaction at 2^24 gas. Each everyday call is sent with exactly what is left of that cap
    ///      after the intrinsic cost, so a call that would not fit in a real transaction fails here.
    function test_everydayCallsFitTheGasCap() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);

        uint256 g = _cappedSafeExec(
            c,
            Actor.OperationsSafe,
            a.trexFactory,
            abi.encodeCall(ITREXFactory.deployTREXSuite, ("capped", _tokenDetails("capped"), _noClaims()))
        );
        emit log_named_uint("deployTREXSuite (through the Operations Safe)", g);
        g = _cappedSafeExec(
            c,
            Actor.OperationsSafe,
            a.trexFactory,
            abi.encodeCall(
                ITREXFactory.deployTREXSuiteIsolated, ("capped-isolated", _tokenDetails("capped-isolated"), _noClaims())
            )
        );
        emit log_named_uint("deployTREXSuiteIsolated (through the Operations Safe)", g);

        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = Structs.KeyParam({
            keyHash: keccak256(abi.encodePacked(alice)),
            purpose: KeyPurposes.MANAGEMENT,
            keyType: KeyTypes.ECDSA,
            signerData: abi.encodePacked(alice),
            clientData: ""
        });
        g = _cappedCall(
            alice,
            a.identityFactory,
            abi.encodeCall(IdentityFactory.createIdentity, (IdentityTypes.INDIVIDUAL, "capped-alice", keys))
        );
        emit log_named_uint("createIdentity", g);

        Token token = Token(ITREXFactory(a.trexFactory).getToken("capped"));
        _commissionAgent(token);
        _register(token, alice, _identityAt(a, alice));
        _register(token, bob, _selfDeployIdentity(c, bob, "capped-bob"));
        g = _cappedCall(agent, address(token), abi.encodeCall(IERC3643.mint, (alice, 100)));
        emit log_named_uint("mint", g);
        g = _cappedCall(alice, address(token), abi.encodeWithSignature("transfer(address,uint256)", bob, 40));
        emit log_named_uint("transfer", g);
        assertEq(token.balanceOf(bob), 40);
    }

    /// @dev Gas left for execution in a capped transaction: the cap minus the base cost and calldata (16 per byte,
    ///      the upper bound).
    function _executionBudget(bytes memory data) internal pure returns (uint256) {
        return TX_GAS_CAP - 21_000 - 16 * data.length;
    }

    function _cappedCall(address from, address to, bytes memory data) internal returns (uint256 used) {
        vm.prank(from);
        uint256 before = gasleft();
        (bool ok, bytes memory ret) = to.call{ gas: _executionBudget(data) }(data);
        used = before - gasleft();
        if (!ok) revert StepReverted("capped call", ret);
    }

    /// @dev One Safe transaction whose `execTransaction` runs within the cap. Owner approvals are their own
    ///      transactions, as they are on chain.
    function _cappedSafeExec(DeployConfig memory c, Actor actor, address to, bytes memory data)
        internal
        returns (uint256)
    {
        Addrs memory a = _addresses(c);
        SafeConfig memory s = _safeConfigOf(c, actor);
        ISafe safe = ISafe(_safeOf(a, actor));
        bytes32 txHash = safe.getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        address[] memory signers = new address[](s.threshold);
        for (uint256 i = 0; i < s.threshold; i++) {
            signers[i] = s.owners[i];
            vm.prank(signers[i]);
            safe.approveHash(txHash);
        }
        bytes memory exec = abi.encodeCall(
            ISafe.execTransaction,
            (to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), SafeLib.approvedHashSignatures(signers))
        );
        return _cappedCall(signers[0], address(safe), exec);
    }

    /// @dev The protocol runs on its first chain for a while; later it expands to the other target chain (here a
    ///      second fork at a later block, running as that chain's id) with the same config. Everything lands at the addresses
    ///      the first chain already uses.
    function test_expandingToANewChainLater() public {
        DeployConfig memory c = _config();
        _live(c);
        Row[] memory firstRows = _addressTable(c);
        (Token firstToken,) = _deploySuite(c, "multi-chain");
        address firstIdentity = address(_selfDeployIdentity(c, alice, "multi-chain-alice"));

        uint256 later = _laterBlock();
        vm.selectFork(vm.createFork(_forkUrl(), later));
        vm.chainId(_otherChainId());
        assertEq(_addresses(c).genesis.code.length, 0, "the new chain starts empty");
        _live(c);
        Row[] memory newRows = _addressTable(c);
        (Token newToken,) = _deploySuite(c, "multi-chain");
        address newIdentity = address(_selfDeployIdentity(c, alice, "multi-chain-alice"));

        assertEq(firstRows.length, newRows.length);
        for (uint256 i = 0; i < firstRows.length; i++) {
            assertEq(firstRows[i].expected, newRows[i].expected, firstRows[i].id);
            assertGt(newRows[i].expected.code.length, 0, firstRows[i].id);
        }
        assertEq(address(firstToken), address(newToken), "suite address");
        assertEq(firstIdentity, newIdentity, "identity address");
        emit log_named_uint("second chain forked at block", later);
    }

    /// @dev A block after the pinned one that the RPC still serves: a few thousand blocks on, capped at its head.
    function _laterBlock() internal returns (uint256) {
        bytes memory raw = vm.rpc("eth_blockNumber", "[]");
        uint256 head = uint256(bytes32(raw)) >> (256 - 8 * raw.length);
        uint256 target = block.number + 5000;
        return target < head ? target : head - 1;
    }

}
