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

import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { IERC735 } from "@onchain-id/solidity/contracts/interface/IERC735.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IKeyExecutor } from "@onchain-id/solidity/contracts/interface/IKeyExecutor.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { ReputationRegistry } from "@onchain-id/solidity/contracts/reputation/ReputationRegistry.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_FALLBACK,
    MODULE_TYPE_VALIDATOR
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import { Create3 } from "@openzeppelin/contracts/utils/Create3.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { Version, VersionLib } from "contracts/libraries/VersionLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";

import { BytecodeStore } from "./lib/BytecodeStore.sol";
import { CreateXAddressLib } from "./lib/CreateXAddressLib.sol";
import { DeployConfig, SafeConfig } from "./lib/DeployConfig.sol";
import { Actor, Method, PlanLists, Probe, Probes, Row, RowList, Step, StepList } from "./lib/PlanTypes.sol";
import { RoleTable } from "./lib/RoleTable.sol";
import { ISafeProxyFactory, SafeLib } from "./lib/SafeLib.sol";

/// @dev CreateX entry points the plan calls.
interface ICreateX {

    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address);

    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);

}

/// @dev UUPS upgrade entry point (OpenZeppelin `UUPSUpgradeable`).
interface IUUPS {

    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;

}

/// @title PlanBuilder
/// @notice Turns a deployment config and the build's bytecode into the address table and the ordered
///         steps of every phase: genesis, protocol, configuration, handover. Builds without calling any chain.
/// @dev Phases:
///      1. Genesis (Genesis.s.sol): the Genesis Deployer (a CreateX copy) through the anchor, the Safe v1.4.1
///         contracts through the Safe Singleton Factory where missing, then the four Safes.
///      2. Protocol (DeployProtocol.s.sol): every implementation and library with CREATE2 through the Genesis
///         Deployer (anyone may send), then every proxy, manager and factory with CREATE3 (only the Deployment
///         Safe may send: the salts are bound to it).
///      3. Configuration (ConfigureAndHandover.s.sol `configure`): the corrected handover steps 1 to 5, sent by
///         the Bootstrap Operator, which is ADMIN of both managers.
///      4. Handover (`finalize`): after the delays are in force, the Bootstrap Operator renounces every role.
abstract contract PlanBuilder {

    /// @notice The contract the heavy builders run in, each call in its own frame. A script may not call itself
    ///         (forge forbids `address(this)` in scripts), so the executor deploys a {Planner} and returns it here.
    function _engine() internal view virtual returns (PlanBuilder) {
        return PlanBuilder(address(this));
    }

    /// @notice Hash of `target`'s runtime code with the given ranges zeroed, in its own call frame.
    function planMaskedHashAt(address target, uint256[] calldata starts, uint256[] calldata lengths)
        external
        view
        returns (bytes32)
    {
        return BytecodeStore.maskedHash(target.code, starts, lengths);
    }

    /// @notice The addresses the current build gets under CREATE2 salt `salt`; CREATE3 addresses are `cIn`'s.
    function planReleaseAddresses(DeployConfig calldata cIn, bytes32 salt) external view returns (Addrs memory) {
        DeployConfig memory r = cIn;
        r.create2Salt = salt;
        return _addresses(r);
    }

    /// @notice CREATE2 steps deploying the current build's libraries and implementations under `salt`.
    function planPublishSteps(DeployConfig calldata cIn, bytes32 salt) external view returns (Step[] memory) {
        DeployConfig memory r = cIn;
        r.create2Salt = salt;
        Addrs memory a = _addresses(r);
        StepList memory steps = PlanLists.newSteps(24);
        _create2Steps(a, salt, "publish.", steps);
        return PlanLists.toArray(steps);
    }

    /// @notice Every address of the deployment, computed from the config and the committed bytecode.
    struct Addrs {
        address genesis;
        address deploymentSafe;
        address protocolAdminSafe;
        address upgradeCouncilSafe;
        address operationsSafe;
        address[8] libs;
        address tokenImpl;
        address mcImpl;
        address trexRegistryImpl;
        address irsImpl;
        address accessManagerImpl;
        address spenderVerificationImpl;
        address spenderWhitelistImpl;
        address maxBalanceImpl;
        address utilityCheckerImpl;
        address identityUtilitiesImpl;
        address keyApprovalModule;
        address identityImpl;
        address webAuthnVerifier;
        address platformAM;
        address upgradeAM;
        address identityFactory;
        address reputationRegistry;
        address validator;
        address identityUtilities;
        address implementationAuthority;
        address gatewayRegistry;
        address trexFactory;
        address spenderVerification;
        address spenderWhitelist;
        address maxBalance;
        address utilityCheckerDeployer;
        address utilityChecker;
        address roleRevoker;
        address[5] suiteBeacons;
        address identityBeacon;
    }

    /// @dev keccak256("TOPIC_MANAGER_ROLE"), IdentityUtilities' topic role.
    bytes32 internal constant TOPIC_MANAGER_ROLE = keccak256("TOPIC_MANAGER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @dev Labels of the CREATE3 rows. Each becomes the low part of a salt bound to the Deployment Safe, so a
    ///      label is frozen once anything is deployed under it.
    string internal constant L_PLATFORM_AM = "T-REX:PlatformAccessManager";
    string internal constant L_UPGRADE_AM = "T-REX:UpgradeAccessManager";
    string internal constant L_IDENTITY_FACTORY = "ONCHAINID:IdentityFactory";
    string internal constant L_REPUTATION = "ONCHAINID:ReputationRegistry";
    string internal constant L_VALIDATOR = "ONCHAINID:ERC734Validator";
    string internal constant L_IDENTITY_UTILITIES = "ONCHAINID:IdentityUtilitiesProxy";
    string internal constant L_AUTHORITY = "T-REX:TREXImplementationAuthority";
    string internal constant L_GATEWAY_REGISTRY = "T-REX:TrustedGatewayRegistry";
    string internal constant L_FACTORY = "T-REX:TREXFactory";
    string internal constant L_SPENDER_VERIFICATION = "T-REX:SpenderVerificationModuleProxy";
    string internal constant L_SPENDER_WHITELIST = "T-REX:SpenderWhitelistModuleProxy";
    string internal constant L_MAX_BALANCE = "T-REX:MaxBalancePerIdentityModuleProxy";
    string internal constant L_UTILITY_CHECKER = "T-REX:UtilityCheckerDeployer";
    string internal constant L_ROLE_REVOKER = "T-REX:RoleRevoker";

    // ---------------------------------------------------------------------------------------------------------
    // Addresses
    // ---------------------------------------------------------------------------------------------------------

    function _genesisAddress(DeployConfig memory c) internal view returns (address) {
        return
            CreateXAddressLib.create2(BytecodeStore.ANCHOR, c.genesisSalt, keccak256(BytecodeStore.createxInitCode()));
    }

    function _safeInitializer(SafeConfig memory s) internal pure returns (bytes memory) {
        return SafeLib.initializer(
            s.owners,
            s.threshold,
            BytecodeStore.SAFE_TO_L2_SETUP,
            BytecodeStore.SAFE_L2,
            BytecodeStore.COMPATIBILITY_FALLBACK_HANDLER
        );
    }

    function _safeAddress(SafeConfig memory s) internal view returns (address) {
        return SafeLib.proxyAddress(
            BytecodeStore.SAFE_PROXY_FACTORY,
            BytecodeStore.SAFE,
            _safeInitializer(s),
            s.saltNonce,
            _safeProxyCreationCode()
        );
    }

    /// @dev From the chain's SafeProxyFactory when it is there, so planning on a live chain reads no vendored Safe
    ///      bytes; from deploy/vendor otherwise (offline table, bare local chain). ForkDeployment checks both agree.
    function _safeProxyCreationCode() internal view returns (bytes memory) {
        if (BytecodeStore.SAFE_PROXY_FACTORY.code.length > 0) {
            return ISafeProxyFactory(BytecodeStore.SAFE_PROXY_FACTORY).proxyCreationCode();
        }
        return BytecodeStore.safeProxyCreationCode();
    }

    function _create3Address(Addrs memory a, string memory label) internal pure returns (address) {
        return CreateXAddressLib.create3ViaCreateX(
            a.genesis, a.deploymentSafe, CreateXAddressLib.permissionedSalt(a.deploymentSafe, keccak256(bytes(label)))
        );
    }

    function _create2Address(Addrs memory a, bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return CreateXAddressLib.create2ViaCreateX(a.genesis, salt, keccak256(initCode));
    }

    /// @notice Every address of the deployment. Pure computation from the config and committed bytecode.
    /// @dev The heavy builders run as external calls to this contract (`_engine().plan...`). Reading and linking the
    ///      artifact JSON allocates a lot of memory, and memory is only released when a call frame ends; done in
    ///      one frame, a full plan runs out of gas on memory expansion alone.
    function _addresses(DeployConfig memory c) internal view returns (Addrs memory) {
        return _engine().planAddresses(c);
    }

    function planAddresses(DeployConfig calldata cIn) external view returns (Addrs memory a) {
        DeployConfig memory c = cIn;
        a.genesis = _genesisAddress(c);
        a.deploymentSafe = _safeAddress(c.deploymentSafe);
        a.protocolAdminSafe = _safeAddress(c.protocolAdminSafe);
        a.upgradeCouncilSafe = _safeAddress(c.upgradeCouncilSafe);
        a.operationsSafe = _safeAddress(c.operationsSafe);
        _fillCreate3(a);
        _fillLibraries(a, c.create2Salt);
        _fillImplementations(a, c.create2Salt);
        _fillDerived(a);
    }

    function _fillCreate3(Addrs memory a) internal pure {
        a.platformAM = _create3Address(a, L_PLATFORM_AM);
        a.upgradeAM = _create3Address(a, L_UPGRADE_AM);
        a.identityFactory = _create3Address(a, L_IDENTITY_FACTORY);
        a.reputationRegistry = _create3Address(a, L_REPUTATION);
        a.validator = _create3Address(a, L_VALIDATOR);
        a.identityUtilities = _create3Address(a, L_IDENTITY_UTILITIES);
        a.implementationAuthority = _create3Address(a, L_AUTHORITY);
        a.gatewayRegistry = _create3Address(a, L_GATEWAY_REGISTRY);
        a.trexFactory = _create3Address(a, L_FACTORY);
        a.spenderVerification = _create3Address(a, L_SPENDER_VERIFICATION);
        a.spenderWhitelist = _create3Address(a, L_SPENDER_WHITELIST);
        a.maxBalance = _create3Address(a, L_MAX_BALANCE);
        a.utilityCheckerDeployer = _create3Address(a, L_UTILITY_CHECKER);
        a.roleRevoker = _create3Address(a, L_ROLE_REVOKER);
    }

    /// @dev Libraries in dependency order: TokenDelegationLib links the two before it.
    function _fillLibraries(Addrs memory a, bytes32 salt) internal view {
        (string[8] memory names,) = BytecodeStore.libraries();
        for (uint256 i = 0; i < 8; i++) {
            a.libs[i] = _create2Address(a, salt, _initCode(names[i], a.libs));
        }
    }

    /// @dev Implementations. Their constructor arguments are CREATE3 addresses, known before anything exists.
    function _fillImplementations(Addrs memory a, bytes32 salt) internal view {
        a.tokenImpl = _create2Address(a, salt, _implInitCode(a, "Token"));
        a.mcImpl = _create2Address(a, salt, _implInitCode(a, "ModularCompliance"));
        a.trexRegistryImpl = _create2Address(a, salt, _implInitCode(a, "TREXRegistry"));
        a.irsImpl = _create2Address(a, salt, _implInitCode(a, "IdentityRegistryStorage"));
        a.accessManagerImpl = _create2Address(a, salt, _implInitCode(a, "TREXAccessManager"));
        a.spenderVerificationImpl = _create2Address(a, salt, _implInitCode(a, "SpenderVerificationModule"));
        a.spenderWhitelistImpl = _create2Address(a, salt, _implInitCode(a, "SpenderWhitelistModule"));
        a.maxBalanceImpl = _create2Address(a, salt, _implInitCode(a, "MaxBalancePerIdentityModule"));
        a.utilityCheckerImpl = _create2Address(a, salt, _implInitCode(a, "UtilityChecker"));
        a.identityUtilitiesImpl = _create2Address(a, salt, _implInitCode(a, "IdentityUtilities"));
        a.keyApprovalModule = _create2Address(a, salt, _implInitCode(a, "KeyApprovalModule"));
        a.identityImpl = _create2Address(a, salt, _implInitCode(a, "Identity"));
        a.webAuthnVerifier = _create2Address(a, salt, _implInitCode(a, "ERC7913WebAuthnVerifier"));
    }

    function _fillDerived(Addrs memory a) internal pure {
        for (uint8 i = 0; i < 5; i++) {
            a.suiteBeacons[i] = CreateXAddressLib.createAt(a.implementationAuthority, i + 1);
        }
        a.utilityChecker = CreateXAddressLib.createAt(a.utilityCheckerDeployer, 1);
        a.identityBeacon = Create3.computeAddress(keccak256("onchainid.beacon.v1"), a.identityFactory);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Init code
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Linked creation code of a release contract, built in its own call frame.
    function _initCode(string memory name, address[8] memory libs) internal view returns (bytes memory) {
        return _engine().planInitCode(name, libs);
    }

    function planInitCode(string calldata name, address[8] calldata libs) external view returns (bytes memory) {
        return BytecodeStore.initCode(name, libs);
    }

    /// @notice Creation code of a CREATE2 row, linked and with its constructor arguments.
    function _implInitCode(Addrs memory a, string memory name) internal view returns (bytes memory code) {
        code = _initCode(name, a.libs);
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("TREXRegistry")) return bytes.concat(code, abi.encode(a.identityFactory));
        if (h == keccak256("Identity")) return bytes.concat(code, abi.encode(a.validator, a.identityFactory));
    }

    function _suiteImplementations(Addrs memory a)
        internal
        pure
        returns (ITREXImplementationAuthority.SuiteImplementations memory)
    {
        return ITREXImplementationAuthority.SuiteImplementations({
            tokenImplementation: a.tokenImpl,
            trexRegistryImplementation: a.trexRegistryImpl,
            irsImplementation: a.irsImpl,
            mcImplementation: a.mcImpl,
            accessManagerImplementation: a.accessManagerImpl
        });
    }

    function _initialVersion(DeployConfig memory c) internal pure returns (Version) {
        return VersionLib.pack(c.versionMajor, c.versionMinor, c.versionPatch);
    }

    /// @notice Creation code of a CREATE3 row, with its constructor arguments.
    function _create3InitCode(DeployConfig memory c, Addrs memory a, string memory label)
        internal
        view
        returns (bytes memory)
    {
        return _engine().planCreate3InitCode(c, a, label);
    }

    function planCreate3InitCode(DeployConfig calldata cIn, Addrs calldata aIn, string calldata label)
        external
        view
        returns (bytes memory)
    {
        DeployConfig memory c = cIn;
        Addrs memory a = aIn;
        bytes32 h = keccak256(bytes(label));
        if (h == keccak256(bytes(L_PLATFORM_AM)) || h == keccak256(bytes(L_UPGRADE_AM))) {
            return bytes.concat(_initCode("AccessManager", a.libs), abi.encode(c.bootstrap));
        }
        if (h == keccak256(bytes(L_IDENTITY_FACTORY))) {
            return bytes.concat(_initCode("IdentityFactory", a.libs), abi.encode(a.platformAM));
        }
        if (h == keccak256(bytes(L_REPUTATION))) {
            return bytes.concat(_initCode("ReputationRegistry", a.libs), abi.encode(a.platformAM, a.identityFactory));
        }
        if (h == keccak256(bytes(L_VALIDATOR))) {
            return
                bytes.concat(_initCode("ERC734Validator", a.libs), abi.encode(a.identityFactory, a.reputationRegistry));
        }
        if (h == keccak256(bytes(L_IDENTITY_UTILITIES))) {
            return bytes.concat(
                _initCode("IdentityUtilitiesProxy", a.libs), abi.encode(a.identityUtilitiesImpl, c.bootstrap)
            );
        }
        if (h == keccak256(bytes(L_AUTHORITY))) {
            return bytes.concat(
                _initCode("TREXImplementationAuthority", a.libs),
                abi.encode(a.upgradeAM, _initialVersion(c), _suiteImplementations(a))
            );
        }
        if (h == keccak256(bytes(L_GATEWAY_REGISTRY))) {
            return bytes.concat(_initCode("TrustedGatewayRegistry", a.libs), abi.encode(a.platformAM));
        }
        if (h == keccak256(bytes(L_FACTORY))) {
            return bytes.concat(
                _initCode("TREXFactory", a.libs),
                abi.encode(a.implementationAuthority, a.identityFactory, a.gatewayRegistry, a.platformAM)
            );
        }
        if (h == keccak256(bytes(L_SPENDER_VERIFICATION))) return _moduleProxyInit(a, a.spenderVerificationImpl);
        if (h == keccak256(bytes(L_SPENDER_WHITELIST))) return _moduleProxyInit(a, a.spenderWhitelistImpl);
        if (h == keccak256(bytes(L_MAX_BALANCE))) return _moduleProxyInit(a, a.maxBalanceImpl);
        if (h == keccak256(bytes(L_UTILITY_CHECKER))) {
            return
                bytes.concat(_initCode("UtilityCheckerDeployer", a.libs), abi.encode(a.utilityCheckerImpl, a.upgradeAM));
        }
        if (h == keccak256(bytes(L_ROLE_REVOKER))) {
            return bytes.concat(_initCode("RoleRevoker", a.libs), abi.encode(a.platformAM));
        }
        revert(string.concat("PlanBuilder: unknown CREATE3 label ", label));
    }

    /// @dev Every module's `initialize(address)` makes the given manager its authority.
    function _moduleProxyInit(Addrs memory a, address impl) internal view returns (bytes memory) {
        bytes memory init = abi.encodeWithSignature("initialize(address)", a.upgradeAM);
        return bytes.concat(_initCode("ModuleProxy", a.libs), abi.encode(impl, init));
    }

    /// @dev CREATE3 rows in deployment order, with the release contract each one runs.
    function _create3Rows() internal pure returns (string[14] memory labels, string[14] memory contracts) {
        labels = [
            L_PLATFORM_AM,
            L_UPGRADE_AM,
            L_IDENTITY_FACTORY,
            L_REPUTATION,
            L_VALIDATOR,
            L_IDENTITY_UTILITIES,
            L_AUTHORITY,
            L_GATEWAY_REGISTRY,
            L_FACTORY,
            L_SPENDER_VERIFICATION,
            L_SPENDER_WHITELIST,
            L_MAX_BALANCE,
            L_UTILITY_CHECKER,
            L_ROLE_REVOKER
        ];
        contracts = [
            "AccessManager",
            "AccessManager",
            "IdentityFactory",
            "ReputationRegistry",
            "ERC734Validator",
            "IdentityUtilitiesProxy",
            "TREXImplementationAuthority",
            "TrustedGatewayRegistry",
            "TREXFactory",
            "ModuleProxy",
            "ModuleProxy",
            "ModuleProxy",
            "UtilityCheckerDeployer",
            "RoleRevoker"
        ];
    }

    /// @dev CREATE2 implementation rows in deployment order (after the libraries).
    function _implementationNames() internal pure returns (string[13] memory names) {
        names = [
            "Token",
            "ModularCompliance",
            "TREXRegistry",
            "IdentityRegistryStorage",
            "TREXAccessManager",
            "SpenderVerificationModule",
            "SpenderWhitelistModule",
            "MaxBalancePerIdentityModule",
            "UtilityChecker",
            "IdentityUtilities",
            "KeyApprovalModule",
            "Identity",
            "ERC7913WebAuthnVerifier"
        ];
    }

    // ---------------------------------------------------------------------------------------------------------
    // Address table
    // ---------------------------------------------------------------------------------------------------------

    /// @notice The address table: every contract, how it is made, its salt, init code hash and address.
    /// @dev Runs in its own call frame (see {_addresses}).
    function _addressTable(DeployConfig memory c) internal view returns (Row[] memory) {
        return _engine().planAddressTable(c);
    }

    function planAddressTable(DeployConfig calldata cIn) external view returns (Row[] memory) {
        DeployConfig memory c = cIn;
        Addrs memory a = _addresses(c);
        RowList memory rows = PlanLists.newRows(64);
        _genesisRows(c, a, rows);
        _protocolRows(c, a, rows);
        _derivedRows(a, rows);
        return PlanLists.toArray(rows);
    }

    function _genesisRows(DeployConfig memory c, Addrs memory a, RowList memory rows) internal view {
        PlanLists.push(
            rows,
            Row(
                "genesisDeployer",
                "CreateX",
                Method.Create2Anchor,
                c.genesisSalt,
                keccak256(BytecodeStore.createxInitCode()),
                a.genesis,
                Actor.Anyone
            )
        );
        BytecodeStore.VendorContract[] memory safes = BytecodeStore.safeContracts();
        for (uint256 i = 0; i < safes.length; i++) {
            PlanLists.push(
                rows,
                Row(
                    string.concat("safe.", safes[i].name),
                    safes[i].name,
                    Method.Create2SafeSingletonFactory,
                    bytes32(0),
                    BytecodeStore.safeInitCodeHash(safes[i].name),
                    safes[i].canonical,
                    Actor.Anyone
                )
            );
        }
        _safeRow(rows, "deploymentSafe", c.deploymentSafe, a.deploymentSafe);
        _safeRow(rows, "protocolAdminSafe", c.protocolAdminSafe, a.protocolAdminSafe);
        _safeRow(rows, "upgradeCouncilSafe", c.upgradeCouncilSafe, a.upgradeCouncilSafe);
        _safeRow(rows, "operationsSafe", c.operationsSafe, a.operationsSafe);
    }

    function _safeRow(RowList memory rows, string memory id, SafeConfig memory s, address expected) internal pure {
        PlanLists.push(
            rows,
            Row(
                id,
                "SafeProxy",
                Method.SafeProxyFactory,
                keccak256(abi.encodePacked(keccak256(_safeInitializer(s)), s.saltNonce)),
                bytes32(0),
                expected,
                Actor.Anyone
            )
        );
    }

    function _protocolRows(DeployConfig memory c, Addrs memory a, RowList memory rows) internal view {
        (string[8] memory libs,) = BytecodeStore.libraries();
        for (uint256 i = 0; i < 8; i++) {
            bytes memory init = _initCode(libs[i], a.libs);
            PlanLists.push(
                rows,
                Row(libs[i], libs[i], Method.Create2CreateX, c.create2Salt, keccak256(init), a.libs[i], Actor.Anyone)
            );
        }
        string[13] memory impls = _implementationNames();
        for (uint256 i = 0; i < impls.length; i++) {
            bytes memory init = _implInitCode(a, impls[i]);
            PlanLists.push(
                rows,
                Row(
                    string.concat(impls[i], ".implementation"),
                    impls[i],
                    Method.Create2CreateX,
                    c.create2Salt,
                    keccak256(init),
                    _create2Address(a, c.create2Salt, init),
                    Actor.Anyone
                )
            );
        }
        (string[14] memory labels, string[14] memory names) = _create3Rows();
        for (uint256 i = 0; i < labels.length; i++) {
            PlanLists.push(
                rows,
                Row(
                    labels[i],
                    names[i],
                    Method.Create3CreateX,
                    CreateXAddressLib.permissionedSalt(a.deploymentSafe, keccak256(bytes(labels[i]))),
                    keccak256(_create3InitCode(c, a, labels[i])),
                    _create3Address(a, labels[i]),
                    Actor.DeploymentSafe
                )
            );
        }
    }

    function _derivedRows(Addrs memory a, RowList memory rows) internal pure {
        string[5] memory beacons =
            ["Token", "TREXRegistry", "IdentityRegistryStorage", "ModularCompliance", "TREXAccessManager"];
        for (uint256 i = 0; i < 5; i++) {
            PlanLists.push(
                rows,
                Row(
                    string.concat("beacon.", beacons[i]),
                    "UpgradeableBeacon",
                    Method.Nonce,
                    bytes32(i + 1),
                    bytes32(0),
                    a.suiteBeacons[i],
                    Actor.DeploymentSafe
                )
            );
        }
        PlanLists.push(
            rows,
            Row(
                "UtilityChecker.proxy",
                "UtilityCheckerProxy",
                Method.Nonce,
                bytes32(uint256(1)),
                bytes32(0),
                a.utilityChecker,
                Actor.DeploymentSafe
            )
        );
        PlanLists.push(
            rows,
            Row(
                "identityBeacon",
                "UpgradeableBeacon",
                Method.Create3InContract,
                keccak256("onchainid.beacon.v1"),
                bytes32(0),
                a.identityBeacon,
                Actor.Bootstrap
            )
        );
    }

    // ---------------------------------------------------------------------------------------------------------
    // Genesis steps
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Runs in its own call frame (see {_addresses}).
    function _genesisSteps(DeployConfig memory c) internal view returns (Step[] memory) {
        return _engine().planGenesisSteps(c);
    }

    function planGenesisSteps(DeployConfig calldata cIn) external view returns (Step[] memory) {
        DeployConfig memory c = cIn;
        Addrs memory a = _addresses(c);
        StepList memory steps = PlanLists.newSteps(16);
        PlanLists.push(
            steps,
            Step(
                "genesisDeployer",
                Actor.Anyone,
                BytecodeStore.ANCHOR,
                0,
                abi.encodePacked(c.genesisSalt, BytecodeStore.createxInitCode()),
                Probes.code(a.genesis)
            )
        );
        BytecodeStore.VendorContract[] memory safes = BytecodeStore.safeContracts();
        for (uint256 i = 0; i < safes.length; i++) {
            PlanLists.push(
                steps,
                Step(
                    string.concat("safe.", safes[i].name),
                    Actor.Anyone,
                    BytecodeStore.SAFE_SINGLETON_FACTORY,
                    0,
                    // The init code is read only where the contract is missing (a bare chain); on a chain that has
                    // it the step is already done and carries no bytes.
                    safes[i].canonical.code.length > 0
                        ? bytes("")
                        : abi.encodePacked(bytes32(0), BytecodeStore.safeInitCode(safes[i].name)),
                    Probes.exactCode(safes[i].canonical, BytecodeStore.safeRuntimeCodeHash(safes[i].name))
                )
            );
        }
        _safeStep(steps, "deploymentSafe", c.deploymentSafe, a.deploymentSafe);
        _safeStep(steps, "protocolAdminSafe", c.protocolAdminSafe, a.protocolAdminSafe);
        _safeStep(steps, "upgradeCouncilSafe", c.upgradeCouncilSafe, a.upgradeCouncilSafe);
        _safeStep(steps, "operationsSafe", c.operationsSafe, a.operationsSafe);
        return PlanLists.toArray(steps);
    }

    function _safeStep(StepList memory steps, string memory id, SafeConfig memory s, address expected) internal pure {
        PlanLists.push(
            steps,
            Step(
                id,
                Actor.Anyone,
                BytecodeStore.SAFE_PROXY_FACTORY,
                0,
                abi.encodeCall(
                    ISafeProxyFactory.createProxyWithNonce, (BytecodeStore.SAFE, _safeInitializer(s), s.saltNonce)
                ),
                Probes.code(expected)
            )
        );
    }

    // ---------------------------------------------------------------------------------------------------------
    // Protocol steps
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Runs in its own call frame (see {_addresses}).
    function _protocolSteps(DeployConfig memory c) internal view returns (Step[] memory) {
        return _engine().planProtocolSteps(c);
    }

    function planProtocolSteps(DeployConfig calldata cIn) external view returns (Step[] memory) {
        DeployConfig memory c = cIn;
        Addrs memory a = _addresses(c);
        StepList memory steps = PlanLists.newSteps(40);
        _create2Steps(a, c.create2Salt, "", steps);
        _create3Steps(c, a, steps);
        return PlanLists.toArray(steps);
    }

    /// @notice CREATE2 steps for the build's libraries and implementations under `salt`.
    /// @dev `a` must have been filled for that salt (Upgrade.s.sol publishes a release under its own salt).
    function _create2Steps(Addrs memory a, bytes32 salt, string memory idPrefix, StepList memory steps) internal view {
        (string[8] memory libs,) = BytecodeStore.libraries();
        for (uint256 i = 0; i < 8; i++) {
            bytes memory init = _initCode(libs[i], a.libs);
            _create2Step(steps, string.concat(idPrefix, libs[i]), a, salt, init);
        }
        string[13] memory impls = _implementationNames();
        for (uint256 i = 0; i < impls.length; i++) {
            _create2Step(
                steps, string.concat(idPrefix, impls[i], ".implementation"), a, salt, _implInitCode(a, impls[i])
            );
        }
    }

    function _create2Step(StepList memory steps, string memory id, Addrs memory a, bytes32 salt, bytes memory init)
        internal
        pure
    {
        PlanLists.push(
            steps,
            Step(
                id,
                Actor.Anyone,
                a.genesis,
                0,
                abi.encodeCall(ICreateX.deployCreate2, (salt, init)),
                Probes.code(_create2Address(a, salt, init))
            )
        );
    }

    function _create3Steps(DeployConfig memory c, Addrs memory a, StepList memory steps) internal view {
        (string[14] memory labels, string[14] memory names) = _create3Rows();
        for (uint256 i = 0; i < labels.length; i++) {
            Probe memory probe;
            if (keccak256(bytes(labels[i])) == keccak256(bytes(L_UTILITY_CHECKER))) {
                // The deployer keeps no code; its proof is the proxy it leaves behind, whose authority, which it
                // reports as its owner, is the Upgrade manager.
                probe = Probes.strict(a.utilityChecker, abi.encodeCall(Ownable.owner, ()), abi.encode(a.upgradeAM));
            } else {
                probe = _maskedProbe(_create3Address(a, labels[i]), names[i]);
            }
            PlanLists.push(
                steps,
                Step(
                    labels[i],
                    Actor.DeploymentSafe,
                    a.genesis,
                    0,
                    abi.encodeCall(
                        ICreateX.deployCreate3,
                        (
                            CreateXAddressLib.permissionedSalt(a.deploymentSafe, keccak256(bytes(labels[i]))),
                            _create3InitCode(c, a, labels[i])
                        )
                    ),
                    probe
                )
            );
        }
    }

    function _maskedProbe(address target, string memory name) internal view returns (Probe memory) {
        return _engine().planMaskedProbe(target, name);
    }

    function planMaskedProbe(address target, string calldata name) external view returns (Probe memory) {
        (uint256[] memory starts, uint256[] memory lengths) = BytecodeStore.immutableRanges(name);
        bytes32 masked = BytecodeStore.maskedHash(BytecodeStore.runtimeCode(name), starts, lengths);
        return Probes.maskedCode(target, masked, starts, lengths);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Role tables (shared by configuration and verification)
    // ---------------------------------------------------------------------------------------------------------

    struct FunctionRole {
        address manager;
        address target;
        bytes4[] selectors;
        uint64 role;
    }

    struct Grant {
        address manager;
        uint64 role;
        address account;
        uint32 executionDelay;
    }

    struct RoleSetting {
        address manager;
        uint64 role;
        // Admin or guardian role, depending on the table.
        uint64 value;
    }

    struct DelaySetting {
        address manager;
        // A role id (grant delays) or a target address (target admin delays), left-padded.
        uint256 subject;
        uint32 delay;
    }

    struct Label {
        address manager;
        uint64 role;
        string label;
    }

    function _functionRoles(Addrs memory a) internal pure returns (FunctionRole[] memory t) {
        t = new FunctionRole[](12);
        uint64 version = RoleTable.versionManager();
        // TREXFactory: the same split as AccessManagerSetupLib.setupTREXFactoryRoles, with every setter that
        // changes which code or which registry new suites use given to the code role.
        t[0] = FunctionRole(
            a.platformAM,
            a.trexFactory,
            _sel2(ITREXFactory.deployTREXSuite.selector, ITREXFactory.deployTREXSuiteIsolated.selector),
            RoleTable.tokenIssuer()
        );
        t[1] = FunctionRole(
            a.platformAM,
            a.trexFactory,
            _sel3(
                ITREXFactory.setImplementationAuthority.selector,
                ITREXFactory.setTrustedGatewayRegistry.selector,
                ITREXFactory.setIdFactory.selector
            ),
            version
        );
        t[2] = FunctionRole(
            a.platformAM,
            a.gatewayRegistry,
            _sel1(TrustedGatewayRegistry.setTrustedGateway.selector),
            RoleTable.interopManager()
        );
        t[3] = FunctionRole(
            a.platformAM,
            a.identityFactory,
            _sel3(
                IdentityFactory.upgradeBeacon.selector,
                IdentityFactory.setIdentityTypeModules.selector,
                IdentityFactory.setTrustedVerifier.selector
            ),
            version
        );
        t[4] = FunctionRole(
            a.platformAM,
            a.reputationRegistry,
            _sel3(
                ReputationRegistry.setReputation.selector,
                ReputationRegistry.setDefault.selector,
                ReputationRegistry.setClaimAddThreshold.selector
            ),
            RoleTable.reputationManager()
        );
        t[5] = FunctionRole(
            a.upgradeAM,
            a.implementationAuthority,
            _sel3(
                ITREXImplementationAuthority.publish.selector,
                ITREXImplementationAuthority.upgrade.selector,
                ITREXImplementationAuthority.publishAndUpgrade.selector
            ),
            version
        );
        t[6] = FunctionRole(a.upgradeAM, a.spenderVerification, _sel1(IUUPS.upgradeToAndCall.selector), version);
        t[7] = FunctionRole(a.upgradeAM, a.spenderWhitelist, _sel1(IUUPS.upgradeToAndCall.selector), version);
        t[8] = FunctionRole(a.upgradeAM, a.maxBalance, _sel1(IUUPS.upgradeToAndCall.selector), version);
        // UtilityChecker is AccessManaged by the Upgrade manager, like the modules: its upgrade is its only
        // restricted function, and its `transferOwnership` always reverts.
        t[9] = FunctionRole(a.upgradeAM, a.utilityChecker, _sel1(IUUPS.upgradeToAndCall.selector), version);
        // IdentityUtilities' DEFAULT_ADMIN_ROLE goes to the Upgrade manager. Upgrades and its AccessControl grants
        // all need the code role, so the guardian can cancel each of them: a DEFAULT_ADMIN_ROLE grant left on the
        // manager's ADMIN would let a new admin upgrade with no delay and no veto.
        t[10] = FunctionRole(
            a.upgradeAM,
            a.identityUtilities,
            _sel4(
                IUUPS.upgradeToAndCall.selector,
                IAccessControl.grantRole.selector,
                IAccessControl.revokeRole.selector,
                // The manager renouncing DEFAULT_ADMIN_ROLE would end every upgrade path.
                IAccessControl.renounceRole.selector
            ),
            version
        );
        // The IdentityFactory's cross-chain gateway trust sits with the registry's: INTEROP_MANAGER, config delay,
        // guardian.
        t[11] = FunctionRole(
            a.platformAM,
            a.identityFactory,
            _sel1(IdentityFactory.setTrustedGateway.selector),
            RoleTable.interopManager()
        );
    }

    function _guardians(Addrs memory a) internal pure returns (RoleSetting[] memory t) {
        t = new RoleSetting[](4);
        uint64 g = RoleTable.guardian();
        t[0] = RoleSetting(a.platformAM, RoleTable.versionManager(), g);
        t[1] = RoleSetting(a.platformAM, RoleTable.interopManager(), g);
        t[2] = RoleSetting(a.platformAM, RoleTable.reputationManager(), g);
        t[3] = RoleSetting(a.upgradeAM, RoleTable.versionManager(), g);
    }

    function _roleAdmins(Addrs memory a) internal pure returns (RoleSetting[] memory t) {
        t = new RoleSetting[](6);
        uint64 m = RoleTable.roleManager();
        t[0] = RoleSetting(a.platformAM, RoleTable.tokenIssuer(), m);
        t[1] = RoleSetting(a.platformAM, RoleTable.interopManager(), m);
        t[2] = RoleSetting(a.platformAM, RoleTable.reputationManager(), m);
        t[3] = RoleSetting(a.platformAM, RoleTable.claimIssuerAdmin(), m);
        t[4] = RoleSetting(a.platformAM, RoleTable.issuer(), m);
        t[5] = RoleSetting(a.platformAM, RoleTable.publicAuthority(), m);
    }

    /// @notice Operational roles (handover step 2), granted while ADMIN is still every role's admin: those held by
    ///         contracts and the Operations Safe's, with their execution delays. Granting them before step 3 makes
    ///         ROLE_MANAGER their admin means the Bootstrap Operator never needs ROLE_MANAGER, as OpenZeppelin's
    ///         order has it.
    function _operationalGrants(DeployConfig memory c, Addrs memory a) internal pure returns (Grant[] memory t) {
        t = new Grant[](8);
        t[0] = Grant(a.platformAM, RoleTable.assetDeployer(), a.trexFactory, 0);
        t[1] = Grant(a.platformAM, RoleTable.roleManager(), a.roleRevoker, 0);
        t[2] = Grant(a.platformAM, RoleTable.tokenIssuer(), a.operationsSafe, 0);
        t[3] = Grant(a.platformAM, RoleTable.interopManager(), a.operationsSafe, c.configDelay);
        t[4] = Grant(a.platformAM, RoleTable.reputationManager(), a.operationsSafe, c.configDelay);
        // Identity-creation roles: the IdentityFactory refuses an execution delay on them.
        t[5] = Grant(a.platformAM, RoleTable.claimIssuerAdmin(), a.operationsSafe, 0);
        t[6] = Grant(a.platformAM, RoleTable.issuer(), a.operationsSafe, 0);
        t[7] = Grant(a.platformAM, RoleTable.publicAuthority(), a.operationsSafe, 0);
    }

    /// @notice Governance roles held by the Safes, with their execution delays (handover step 4). Their admin stays
    ///         ADMIN, so the Bootstrap Operator grants them after step 3 too.
    function _safeGrants(DeployConfig memory c, Addrs memory a) internal pure returns (Grant[] memory t) {
        t = new Grant[](7);
        t[0] = Grant(a.platformAM, RoleTable.ADMIN, a.protocolAdminSafe, c.powerDelay);
        // Behind the power delay: instant revocation goes through the RoleRevoker.
        t[1] = Grant(a.platformAM, RoleTable.roleManager(), a.protocolAdminSafe, c.powerDelay);
        t[2] = Grant(a.platformAM, RoleTable.guardian(), a.protocolAdminSafe, 0);
        t[3] = Grant(a.platformAM, RoleTable.versionManager(), a.upgradeCouncilSafe, c.codeDelay);
        t[4] = Grant(a.upgradeAM, RoleTable.ADMIN, a.upgradeCouncilSafe, c.codeDelay);
        t[5] = Grant(a.upgradeAM, RoleTable.versionManager(), a.upgradeCouncilSafe, c.codeDelay);
        t[6] = Grant(a.upgradeAM, RoleTable.guardian(), a.protocolAdminSafe, 0);
    }

    function _grantDelays(DeployConfig memory c, Addrs memory a) internal pure returns (DelaySetting[] memory t) {
        t = new DelaySetting[](14);
        t[0] = DelaySetting(a.platformAM, RoleTable.ADMIN, c.powerDelay);
        t[1] = DelaySetting(a.platformAM, RoleTable.roleManager(), c.powerDelay);
        t[2] = DelaySetting(a.platformAM, RoleTable.guardian(), c.powerDelay);
        t[3] = DelaySetting(a.platformAM, RoleTable.versionManager(), c.codeDelay);
        t[4] = DelaySetting(a.platformAM, RoleTable.assetDeployer(), c.powerDelay);
        t[5] = DelaySetting(a.platformAM, RoleTable.tokenIssuer(), c.configDelay);
        t[6] = DelaySetting(a.platformAM, RoleTable.interopManager(), c.configDelay);
        t[7] = DelaySetting(a.platformAM, RoleTable.reputationManager(), c.configDelay);
        t[8] = DelaySetting(a.platformAM, RoleTable.claimIssuerAdmin(), c.configDelay);
        t[9] = DelaySetting(a.platformAM, RoleTable.issuer(), c.configDelay);
        t[10] = DelaySetting(a.platformAM, RoleTable.publicAuthority(), c.configDelay);
        t[11] = DelaySetting(a.upgradeAM, RoleTable.ADMIN, c.codeDelay);
        t[12] = DelaySetting(a.upgradeAM, RoleTable.versionManager(), c.codeDelay);
        t[13] = DelaySetting(a.upgradeAM, RoleTable.guardian(), c.powerDelay);
    }

    function _targetAdminDelays(DeployConfig memory c, Addrs memory a) internal pure returns (DelaySetting[] memory t) {
        t = new DelaySetting[](10);
        // Targets holding code-changing functions take the code delay, so remapping those functions does too.
        t[0] = DelaySetting(a.platformAM, uint160(a.trexFactory), c.codeDelay);
        t[1] = DelaySetting(a.platformAM, uint160(a.identityFactory), c.codeDelay);
        t[2] = DelaySetting(a.platformAM, uint160(a.gatewayRegistry), c.powerDelay);
        t[3] = DelaySetting(a.platformAM, uint160(a.reputationRegistry), c.powerDelay);
        t[4] = DelaySetting(a.upgradeAM, uint160(a.implementationAuthority), c.codeDelay);
        t[5] = DelaySetting(a.upgradeAM, uint160(a.spenderVerification), c.codeDelay);
        t[6] = DelaySetting(a.upgradeAM, uint160(a.spenderWhitelist), c.codeDelay);
        t[7] = DelaySetting(a.upgradeAM, uint160(a.maxBalance), c.codeDelay);
        t[8] = DelaySetting(a.upgradeAM, uint160(a.utilityChecker), c.codeDelay);
        t[9] = DelaySetting(a.upgradeAM, uint160(a.identityUtilities), c.codeDelay);
    }

    function _labels(Addrs memory a) internal pure returns (Label[] memory t) {
        t = new Label[](12);
        t[0] = Label(a.platformAM, RoleTable.roleManager(), "ROLE_MANAGER");
        t[1] = Label(a.platformAM, RoleTable.guardian(), "GUARDIAN");
        t[2] = Label(a.platformAM, RoleTable.versionManager(), "VERSION_MANAGER");
        t[3] = Label(a.platformAM, RoleTable.tokenIssuer(), "TOKEN_ISSUER");
        t[4] = Label(a.platformAM, RoleTable.assetDeployer(), "ASSET_DEPLOYER");
        t[5] = Label(a.platformAM, RoleTable.interopManager(), "INTEROP_MANAGER");
        t[6] = Label(a.platformAM, RoleTable.reputationManager(), "REPUTATION_MANAGER");
        t[7] = Label(a.platformAM, RoleTable.claimIssuerAdmin(), "CLAIM_ISSUER_ADMIN");
        t[8] = Label(a.platformAM, RoleTable.issuer(), "ISSUER");
        t[9] = Label(a.platformAM, RoleTable.publicAuthority(), "PUBLIC_AUTHORITY");
        t[10] = Label(a.upgradeAM, RoleTable.versionManager(), "VERSION_MANAGER");
        t[11] = Label(a.upgradeAM, RoleTable.guardian(), "GUARDIAN");
    }

    /// @notice Identity type -> (creation role, self-deployable, single-binding), as ONCHAINID's deploy script sets
    ///         them, except ASSET and SMART_CONTRACT, gated by T-REX's ASSET_DEPLOYER.
    function _identityPolicies()
        internal
        pure
        returns (
            uint256[8] memory types,
            uint64[8] memory roles,
            bool[8] memory selfDeployable,
            bool[8] memory singleBinding
        )
    {
        types = [
            IdentityTypes.ASSET,
            IdentityTypes.SMART_CONTRACT,
            IdentityTypes.CLAIM_ISSUER,
            IdentityTypes.INDIVIDUAL,
            IdentityTypes.CORPORATE,
            IdentityTypes.IOT,
            IdentityTypes.AI_AGENT,
            IdentityTypes.PUBLIC_AUTHORITY
        ];
        uint64 asset = RoleTable.assetDeployer();
        roles = [
            asset,
            asset,
            RoleTable.claimIssuerAdmin(),
            RoleTable.issuer(),
            RoleTable.issuer(),
            RoleTable.issuer(),
            RoleTable.issuer(),
            RoleTable.publicAuthority()
        ];
        selfDeployable = [false, false, false, true, true, true, true, false];
        singleBinding = [true, true, false, false, false, false, false, false];
    }

    /// @notice ONCHAINID's standard module bundle (19 entries, as its deploy script registers it for every type).
    function _standardModules(Addrs memory a) internal pure returns (Structs.ModuleInstall[] memory m) {
        address v = a.validator;
        address k = a.keyApprovalModule;
        m = new Structs.ModuleInstall[](19);
        m[0] = Structs.ModuleInstall({ moduleType: MODULE_TYPE_VALIDATOR, module: v, initData: "", purpose: 0 });
        m[1] = Structs.ModuleInstall({
            moduleType: MODULE_TYPE_EXECUTOR, module: k, initData: "", purpose: KeyPurposes.MANAGEMENT
        });
        m[2] = _fallback(k, IKeyExecutor.execute.selector);
        m[3] = _fallback(k, IKeyExecutor.approve.selector);
        m[4] = _fallback(k, IKeyExecutor.getCurrentNonce.selector);
        m[5] = Structs.ModuleInstall({ moduleType: MODULE_TYPE_EXECUTOR, module: v, initData: "", purpose: 0 });
        m[6] = _fallback(v, IERC735.addClaim.selector);
        m[7] = _fallback(v, IERC735.removeClaim.selector);
        m[8] = _fallback(v, IERC735.getClaim.selector);
        m[9] = _fallback(v, IERC735.getClaimIdsByTopic.selector);
        m[10] = _fallback(v, IIdentity.isClaimValid.selector);
        m[11] = _fallback(v, IIdentity.getClaimHash.selector);
        m[12] = _fallback(v, IClaimIssuer.revokeClaimByDigest.selector);
        m[13] = _fallback(v, IClaimIssuer.isDigestRevoked.selector);
        m[14] = _fallback(v, IClaimIssuer.addClaimTo.selector);
        m[15] = _fallback(v, IERC734.keyHasPurpose.selector);
        m[16] = _fallback(v, IERC734.getKey.selector);
        m[17] = _fallback(v, IERC734.getKeyPurposes.selector);
        m[18] = _fallback(v, IERC734.getKeysByPurpose.selector);
    }

    function _fallback(address module, bytes4 selector) private pure returns (Structs.ModuleInstall memory) {
        return Structs.ModuleInstall({
            moduleType: MODULE_TYPE_FALLBACK, module: module, initData: abi.encodePacked(selector), purpose: 0
        });
    }

    // ---------------------------------------------------------------------------------------------------------
    // Configuration steps: corrected handover order, steps 1 to 5 (OpenZeppelin review pp. 23-24)
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Runs in its own call frame (see {_addresses}).
    function _configureSteps(DeployConfig memory c) internal view returns (Step[] memory) {
        return _engine().planConfigureSteps(c);
    }

    function planConfigureSteps(DeployConfig calldata cIn) external view returns (Step[] memory) {
        DeployConfig memory c = cIn;
        Addrs memory a = _addresses(c);
        StepList memory steps = PlanLists.newSteps(96);
        // Step 1a. ONCHAINID configuration, while the Bootstrap Operator still reaches these functions as ADMIN
        // (they are remapped to the code role in step 1b, which the Bootstrap Operator never holds).
        _onchainidSteps(a, steps);
        // Step 1b. Function-to-role mappings, labels and guardians.
        _functionRoleSteps(a, steps);
        _labelSteps(a, steps);
        _roleSettingSteps(steps, _guardians(a), true);
        // Step 2. Operational roles, while ADMIN is still their admin: contracts' and the Operations Safe's.
        _grantSteps(steps, _operationalGrants(c, a), "grant");
        // Step 3. Role admins: ROLE_MANAGER administers the operational roles from here on.
        _roleSettingSteps(steps, _roleAdmins(a), false);
        // Step 4. The governance roles with their execution delays: no grant delay is set yet, so they apply at once.
        _grantSteps(steps, _safeGrants(c, a), "grant");
        _identityUtilitiesGrantSteps(a, steps);
        // Step 5. Grant delays and target admin delays. They come into force after the manager's minimum setback
        // (5 days); `finalize` waits for that.
        _delaySteps(steps, _grantDelays(c, a), true);
        _delaySteps(steps, _targetAdminDelays(c, a), false);
        return PlanLists.toArray(steps);
    }

    function _onchainidSteps(Addrs memory a, StepList memory steps) internal pure {
        PlanLists.push(
            steps,
            Step(
                "identityFactory.initializeBeacon",
                Actor.Bootstrap,
                a.identityFactory,
                0,
                abi.encodeCall(IdentityFactory.initializeBeacon, (a.identityImpl)),
                Probes.code(a.identityBeacon)
            )
        );
        (uint256[8] memory types, uint64[8] memory roles, bool[8] memory selfDep, bool[8] memory single) =
            _identityPolicies();
        for (uint256 i = 0; i < 8; i++) {
            PlanLists.push(
                steps,
                Step(
                    string.concat("identityFactory.policy.", _u(types[i])),
                    Actor.Bootstrap,
                    a.identityFactory,
                    0,
                    abi.encodeCall(IdentityFactory.setIdentityTypePolicy, (types[i], roles[i], selfDep[i], single[i])),
                    Probes.state(
                        a.identityFactory,
                        abi.encodeCall(IdentityFactory.getIdentityTypePolicy, (types[i])),
                        abi.encode(roles[i], selfDep[i], single[i], true)
                    )
                )
            );
        }
        Structs.ModuleInstall[] memory modules = _standardModules(a);
        for (uint256 i = 0; i < 8; i++) {
            PlanLists.push(
                steps,
                Step(
                    string.concat("identityFactory.modules.", _u(types[i])),
                    Actor.Bootstrap,
                    a.identityFactory,
                    0,
                    abi.encodeCall(IdentityFactory.setIdentityTypeModules, (types[i], modules)),
                    Probes.state(
                        a.identityFactory,
                        abi.encodeCall(IdentityFactory.getIdentityTypeModules, (types[i])),
                        abi.encode(modules)
                    )
                )
            );
        }
        PlanLists.push(
            steps,
            Step(
                "identityFactory.trustWebAuthnVerifier",
                Actor.Bootstrap,
                a.identityFactory,
                0,
                abi.encodeCall(IdentityFactory.setTrustedVerifier, (a.webAuthnVerifier, true)),
                Probes.state(
                    a.identityFactory,
                    abi.encodeCall(IdentityFactory.isTrustedVerifier, (a.webAuthnVerifier)),
                    abi.encode(true)
                )
            )
        );
    }

    function _functionRoleSteps(Addrs memory a, StepList memory steps) internal pure {
        FunctionRole[] memory t = _functionRoles(a);
        for (uint256 i = 0; i < t.length; i++) {
            bytes4 last = t[i].selectors[t[i].selectors.length - 1];
            PlanLists.push(
                steps,
                Step(
                    string.concat("functionRole.", _u(i)),
                    Actor.Bootstrap,
                    t[i].manager,
                    0,
                    abi.encodeCall(IAccessManager.setTargetFunctionRole, (t[i].target, t[i].selectors, t[i].role)),
                    Probes.state(
                        t[i].manager,
                        abi.encodeCall(IAccessManager.getTargetFunctionRole, (t[i].target, last)),
                        abi.encode(t[i].role)
                    )
                )
            );
        }
    }

    function _labelSteps(Addrs memory a, StepList memory steps) internal pure {
        Label[] memory t = _labels(a);
        for (uint256 i = 0; i < t.length; i++) {
            PlanLists.push(
                steps,
                Step(
                    string.concat("label.", t[i].label),
                    Actor.Bootstrap,
                    t[i].manager,
                    0,
                    abi.encodeCall(IAccessManager.labelRole, (t[i].role, t[i].label)),
                    Probes.none()
                )
            );
        }
    }

    function _roleSettingSteps(StepList memory steps, RoleSetting[] memory t, bool guardians) internal pure {
        for (uint256 i = 0; i < t.length; i++) {
            bytes memory data = guardians
                ? abi.encodeCall(IAccessManager.setRoleGuardian, (t[i].role, t[i].value))
                : abi.encodeCall(IAccessManager.setRoleAdmin, (t[i].role, t[i].value));
            bytes memory read = guardians
                ? abi.encodeCall(IAccessManager.getRoleGuardian, (t[i].role))
                : abi.encodeCall(IAccessManager.getRoleAdmin, (t[i].role));
            PlanLists.push(
                steps,
                Step(
                    string.concat(guardians ? "guardian." : "roleAdmin.", _u(i)),
                    Actor.Bootstrap,
                    t[i].manager,
                    0,
                    data,
                    Probes.state(t[i].manager, read, abi.encode(t[i].value))
                )
            );
        }
    }

    function _grantSteps(StepList memory steps, Grant[] memory t, string memory prefix) internal pure {
        for (uint256 i = 0; i < t.length; i++) {
            PlanLists.push(
                steps,
                Step(
                    string.concat(prefix, ".", _u(steps.length)),
                    Actor.Bootstrap,
                    t[i].manager,
                    0,
                    abi.encodeCall(IAccessManager.grantRole, (t[i].role, t[i].account, t[i].executionDelay)),
                    Probes.state(
                        t[i].manager,
                        abi.encodeCall(IAccessManager.hasRole, (t[i].role, t[i].account)),
                        abi.encode(true, t[i].executionDelay)
                    )
                )
            );
        }
    }

    function _identityUtilitiesGrantSteps(Addrs memory a, StepList memory steps) internal pure {
        _accessControlGrant(steps, a.identityUtilities, DEFAULT_ADMIN_ROLE, a.upgradeAM, "identityUtilities.admin");
        _accessControlGrant(
            steps, a.identityUtilities, TOPIC_MANAGER_ROLE, a.operationsSafe, "identityUtilities.topicManager"
        );
    }

    function _accessControlGrant(StepList memory steps, address target, bytes32 role, address account, string memory id)
        internal
        pure
    {
        PlanLists.push(
            steps,
            Step(
                id,
                Actor.Bootstrap,
                target,
                0,
                abi.encodeCall(IAccessControl.grantRole, (role, account)),
                Probes.state(target, abi.encodeCall(IAccessControl.hasRole, (role, account)), abi.encode(true))
            )
        );
    }

    function _delaySteps(StepList memory steps, DelaySetting[] memory t, bool grantDelays) internal pure {
        for (uint256 i = 0; i < t.length; i++) {
            bytes memory data;
            Probe memory probe;
            if (grantDelays) {
                data = abi.encodeCall(IAccessManager.setGrantDelay, (uint64(t[i].subject), t[i].delay));
                probe = Probes.grantDelay(t[i].manager, uint64(t[i].subject), t[i].delay);
            } else {
                address target = address(uint160(t[i].subject));
                data = abi.encodeCall(IAccessManager.setTargetAdminDelay, (target, t[i].delay));
                probe = Probes.targetAdminDelay(t[i].manager, target, t[i].delay);
            }
            PlanLists.push(
                steps,
                Step(
                    string.concat(grantDelays ? "grantDelay." : "targetAdminDelay.", _u(i)),
                    Actor.Bootstrap,
                    t[i].manager,
                    0,
                    data,
                    probe
                )
            );
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Handover steps 6 and 7: run by `finalize` once verification passes with every delay in force
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Runs in its own call frame (see {_addresses}).
    function _finalizeSteps(DeployConfig memory c) internal view returns (Step[] memory) {
        return _engine().planFinalizeSteps(c);
    }

    function planFinalizeSteps(DeployConfig calldata cIn) external view returns (Step[] memory) {
        DeployConfig memory c = cIn;
        Addrs memory a = _addresses(c);
        StepList memory steps = PlanLists.newSteps(8);
        _renounceAccessControl(
            steps, a.identityUtilities, TOPIC_MANAGER_ROLE, c.bootstrap, "renounce.identityUtilities.topicManager"
        );
        _renounceAccessControl(
            steps, a.identityUtilities, DEFAULT_ADMIN_ROLE, c.bootstrap, "renounce.identityUtilities.admin"
        );
        // ADMIN last on each manager: once renounced, the Bootstrap Operator can do nothing more there.
        _renounceManagerAdmin(steps, a.platformAM, c.bootstrap, "renounce.platformAM.admin");
        _renounceManagerAdmin(steps, a.upgradeAM, c.bootstrap, "renounce.upgradeAM.admin");
        return PlanLists.toArray(steps);
    }

    function _renounceAccessControl(
        StepList memory steps,
        address target,
        bytes32 role,
        address account,
        string memory id
    ) internal pure {
        PlanLists.push(
            steps,
            Step(
                id,
                Actor.Bootstrap,
                target,
                0,
                abi.encodeCall(IAccessControl.renounceRole, (role, account)),
                Probes.state(target, abi.encodeCall(IAccessControl.hasRole, (role, account)), abi.encode(false))
            )
        );
    }

    function _renounceManagerAdmin(StepList memory steps, address manager, address account, string memory id)
        internal
        pure
    {
        _renounceManagerRole(steps, manager, RoleTable.ADMIN, account, id);
    }

    function _renounceManagerRole(
        StepList memory steps,
        address manager,
        uint64 role,
        address account,
        string memory id
    ) internal pure {
        PlanLists.push(
            steps,
            Step(
                id,
                Actor.Bootstrap,
                manager,
                0,
                abi.encodeCall(IAccessManager.renounceRole, (role, account)),
                Probes.state(
                    manager, abi.encodeCall(IAccessManager.hasRole, (role, account)), abi.encode(false, uint32(0))
                )
            )
        );
    }

    // ---------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------

    function _sel1(bytes4 a) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = a;
    }

    function _sel2(bytes4 a, bytes4 b) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = a;
        s[1] = b;
    }

    function _sel4(bytes4 a, bytes4 b, bytes4 c, bytes4 d) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = a;
        s[1] = b;
        s[2] = c;
        s[3] = d;
    }

    function _sel3(bytes4 a, bytes4 b, bytes4 c) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = a;
        s[1] = b;
        s[2] = c;
    }

    function _u(uint256 value) internal pure returns (string memory) {
        return Strings.toString(value);
    }

}
