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

import { Test } from "@forge-std/Test.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { UpgradePlanner } from "scripts/deploy/UpgradePlanner.sol";
import { DeployConfig, DeployConfigLib, SafeConfig } from "scripts/deploy/lib/DeployConfig.sol";
import { Actor, Probes, Step } from "scripts/deploy/lib/PlanTypes.sol";

/// @notice Shared setup of the fork tests: a fork of the target chain at a pinned block, that chain's config, and
///         helpers that deploy the protocol through the real Safes and use it like an issuer would.
/// @dev Opt-in, so plain `forge test`, coverage and CI never reach for an RPC:
///        TREX_FORK_TESTS=true ALCHEMY_KEY=<key> forge test --match-path "test/fork/*" --threads 1
///      `TREX_FORK_ENV` picks the chain and its deploy/config/<env>.json: `baseSepolia` (default, where the T-REX
///      testnet lives) or `mainnet`. `TREX_FORK_RPC_URL` replaces the env's foundry.toml endpoint (any RPC that
///      serves the pinned block), and `TREX_FORK_BLOCK` replaces the pinned block. Safe owners and the Bootstrap
///      Operator are the config's placeholders; nobody's key is needed, each owner is pranked into `approveHash`.
abstract contract ForkBase is Test, UpgradePlanner {

    /// @dev Base Sepolia block where the CREATE2 anchor, the Safe Singleton Factory and every Safe v1.4.1 contract
    ///      are present with the code hashes in deploy/vendor.
    uint256 internal constant BASE_SEPOLIA_BLOCK = 61_840_000;
    /// @dev Ethereum mainnet block, same prerequisites.
    uint256 internal constant MAINNET_BLOCK = 26_459_000;

    string internal ENV = vm.envOr("TREX_FORK_ENV", string("baseSepolia"));

    address internal issuerAdmin = makeAddr("issuer admin");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        _requireForkTestsEnabled();
        vm.makePersistent(_plannerAddress());
        vm.createSelectFork(_forkUrl(), _forkBlock());
        // A wrong RPC for the env (say TREX_FORK_ENV=mainnet against a Base Sepolia endpoint) must not pass silently.
        assertEq(block.chainid, _config().chainId, string.concat("fork chain id does not match deploy/config/", ENV));
        executorMode = Mode.InTest;
    }

    function _requireForkTestsEnabled() internal {
        bool enabled = vm.envOr("TREX_FORK_TESTS", false);
        bool hasRpc = bytes(vm.envOr("TREX_FORK_RPC_URL", string(""))).length > 0
            || bytes(vm.envOr("ALCHEMY_KEY", string(""))).length > 0;
        if (!enabled || !hasRpc) vm.skip(true);
    }

    function _forkUrl() internal view returns (string memory) {
        string memory url = vm.envOr("TREX_FORK_RPC_URL", string(""));
        return bytes(url).length > 0 ? url : vm.rpcUrl(_onMainnet() ? "ethereum" : "baseSepolia");
    }

    function _onMainnet() internal view returns (bool) {
        return keccak256(bytes(ENV)) == keccak256("mainnet");
    }

    function _forkBlock() internal view returns (uint256) {
        return vm.envOr("TREX_FORK_BLOCK", _onMainnet() ? MAINNET_BLOCK : BASE_SEPOLIA_BLOCK);
    }

    /// @dev The chain id a second fork runs as, to stand for "the other target chain": mainnet from Base Sepolia,
    ///      Base Sepolia from mainnet. Off chain 1 the Safes run the L2 singleton.
    function _otherChainId() internal view returns (uint256) {
        return _onMainnet() ? 84532 : 1;
    }

    function _config() internal view returns (DeployConfig memory) {
        return DeployConfigLib.load(ENV);
    }

    function _deployAndConfigure(DeployConfig memory c) internal {
        assertTrue(_run(c, _genesisSteps(c), "genesis"), "genesis");
        assertTrue(_run(c, _protocolSteps(c), "protocol"), "protocol");
        assertTrue(_run(c, _configureSteps(c), "configure"), "configure");
    }

    function _handOver(DeployConfig memory c) internal {
        vm.warp(block.timestamp + c.codeDelay + 1);
        assertEq(_verify(c, true, false).length, 0, "verification before handover");
        assertTrue(_run(c, _finalizeSteps(c), "finalize"), "finalize");
        _assertVerified(c);
    }

    function _assertVerified(DeployConfig memory c) internal {
        string[] memory failures = _verify(c, true, true);
        for (uint256 i = 0; i < failures.length; i++) {
            emit log_named_string("verification failure", failures[i]);
        }
        assertEq(failures.length, 0, "verification failed");
    }

    /// @notice Sends `data` to `to` from one of the Safes, through the real Safe.
    function _fromSafe(DeployConfig memory c, Actor actor, address to, bytes memory data) internal {
        Addrs memory a = _addresses(c);
        _execThroughSafe(
            _safeConfigOf(c, actor), _safeOf(a, actor), Step("safe call", actor, to, 0, data, Probes.none())
        );
    }

    // ---- Life after the deployment ----

    /// @dev CREATE2 salts of "new" releases: the same code published at new addresses, which is everything an upgrade
    ///      path cares about until a second real release exists.
    bytes32 internal constant REHEARSAL_SALT =
        bytes32(hex"5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e000000000000000000000000");
    bytes32 internal constant SECOND_SALT =
        bytes32(hex"6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f000000000000000000000000");

    /// @notice Deploys, configures and hands over: the protocol as it runs in production.
    function _live(DeployConfig memory c) internal returns (Addrs memory) {
        _deployAndConfigure(c);
        _handOver(c);
        return _addresses(c);
    }

    /// @notice A delayed governance action: the Safe schedules `data` on `manager`, waits `delay`, executes it.
    function _scheduleAndExecute(
        DeployConfig memory c,
        Actor actor,
        address manager,
        address target,
        bytes memory data,
        uint256 delay
    ) internal {
        _fromSafe(c, actor, manager, abi.encodeCall(IAccessManager.schedule, (target, data, 0)));
        vm.warp(block.timestamp + delay + 1);
        _fromSafe(c, actor, manager, abi.encodeCall(IAccessManager.execute, (target, data)));
    }

    /// @notice One Safe transaction, as an external call so a test can wrap it in `vm.expectRevert`.
    function safeCall(Actor actor, address to, bytes calldata data) external {
        _fromSafe(_config(), actor, to, data);
    }

    function _expectSafeCallReverts(Actor actor, address to, bytes memory data) internal {
        vm.expectRevert();
        this.safeCall(actor, to, data);
    }

    /// @notice A Safe transaction signed by an explicit owner set (after an owner rotation, or a new Safe).
    function _execWithOwners(SafeConfig memory s, address safe, address to, bytes memory data) internal {
        _execThroughSafe(s, safe, Step("owners call", Actor.Anyone, to, 0, data, Probes.none()));
    }

    function execWithOwners(SafeConfig calldata s, address safe, address to, bytes calldata data) external {
        _execWithOwners(s, safe, to, data);
    }

    /// @notice Publishes the current release again under `salt`.
    function _publish(DeployConfig memory c, bytes32 salt) internal returns (Addrs memory) {
        _run(c, _publishSteps(c, salt), "publish");
        return _releaseAddresses(c, salt);
    }

    /// @notice Moves every shared suite to the release published under `salt`, as `patch` (Council, code delay).
    function _upgradeSuites(DeployConfig memory c, bytes32 salt, uint8 patch) internal {
        _run(c, _one(_scheduleSuiteUpgrade(c, salt, _version(c.versionMajor, c.versionMinor, patch))), "schedule");
        vm.warp(block.timestamp + c.codeDelay + 1);
        _run(c, _one(_executeSuiteUpgrade(c, salt, _version(c.versionMajor, c.versionMinor, patch))), "execute");
    }

    // ---- Using the deployed protocol as an issuer would ----

    function _noClaims() internal pure returns (ITREXFactory.ClaimDetails memory) {
        return ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
    }

    function _tokenDetails(string memory name) internal view returns (ITREXFactory.TokenDetails memory) {
        return ITREXFactory.TokenDetails({
            name: name,
            symbol: "TRX",
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(0),
            accessManagerAdmin: issuerAdmin
        });
    }

    /// @notice The Operations Safe (TOKEN_ISSUER) deploys a suite; the factory deploys its manager and mints the
    ///         token's identity with its ASSET_DEPLOYER role. Returns the gas the deploy call used.
    function _deploySuite(DeployConfig memory c, string memory salt) internal returns (Token token, uint256 gasUsed) {
        Addrs memory a = _addresses(c);
        uint256 before = maxStepGas;
        maxStepGas = 0;
        _fromSafe(
            c,
            Actor.OperationsSafe,
            a.trexFactory,
            abi.encodeCall(ITREXFactory.deployTREXSuite, (salt, _tokenDetails(salt), _noClaims()))
        );
        gasUsed = maxStepGas;
        if (before > maxStepGas) maxStepGas = before;
        token = Token(ITREXFactory(a.trexFactory).getToken(salt));
        assertTrue(address(token) != address(0), "suite not recorded");
    }

    /// @notice The issuer admin hands the agent the roles it needs, the agent unpauses.
    function _commissionAgent(Token token) internal {
        TREXAccessManager manager = TREXAccessManager(IERC173(address(token)).owner());
        uint32 ns = manager.domainOf(address(token));
        vm.startPrank(issuerAdmin);
        manager.grantRole(RolesLib.forDomain(ns, RolesLib.Role.AGENT_ADMIN), issuerAdmin, 0);
        manager.grantRole(RolesLib.forDomain(ns, RolesLib.Role.AGENT), agent, 0);
        manager.grantRole(RolesLib.forDomain(ns, RolesLib.Role.AGENT_PAUSER), agent, 0);
        manager.grantRole(RolesLib.forDomain(ns, RolesLib.Role.AGENT_MINTER), agent, 0);
        vm.stopPrank();
        vm.prank(agent);
        token.unpause();
    }

    /// @notice `wallet` deploys its own INDIVIDUAL identity (self-deployable by policy).
    function _selfDeployIdentity(DeployConfig memory c, address wallet, string memory salt)
        internal
        returns (IIdentity)
    {
        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = Structs.KeyParam({
            keyHash: keccak256(abi.encodePacked(wallet)),
            purpose: KeyPurposes.MANAGEMENT,
            keyType: KeyTypes.ECDSA,
            signerData: abi.encodePacked(wallet),
            clientData: ""
        });
        // Resolved before the prank: an external call in the argument list would consume it.
        IdentityFactory factory = IdentityFactory(_addresses(c).identityFactory);
        vm.prank(wallet);
        return IIdentity(factory.createIdentity(IdentityTypes.INDIVIDUAL, salt, keys));
    }

    /// @notice The identity `wallet` is bound to; the factory keys accounts by their ERC-7930 interoperable address.
    function _identityAt(Addrs memory a, address wallet) internal view returns (IIdentity) {
        return IIdentity(
            IdentityFactory(a.identityFactory).getIdentity(InteroperableAddress.formatEvmV1(block.chainid, wallet))
        );
    }

    function _register(Token token, address wallet, IIdentity identity) internal {
        IERC3643IdentityRegistry registry = IERC3643IdentityRegistry(address(token.identityRegistry()));
        vm.prank(agent);
        registry.registerIdentity(wallet, identity, 0);
    }

    /// @notice A suite with alice holding 100 and bob registered.
    function _suiteWithBalances(DeployConfig memory c, string memory salt) internal returns (Token token) {
        (token,) = _deploySuite(c, salt);
        _commissionAgent(token);
        _register(token, alice, _selfDeployIdentity(c, alice, string.concat(salt, "-alice")));
        _register(token, bob, _selfDeployIdentity(c, bob, string.concat(salt, "-bob")));
        vm.prank(agent);
        token.mint(alice, 100);
    }

}
