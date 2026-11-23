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

import { LinkerLib } from "./LinkerLib.sol";
// Puts every default-profile release contract in the build, so `forge test` on a clean checkout has the artifacts.
import { ReleaseBuild } from "./ReleaseBuild.sol";

/// @title BytecodeStore
/// @notice Where the deployment's bytecode comes from.
/// @dev - T-REX and ONCHAINID contracts: Foundry's build output. T-REX from `out/` (default profile); the ONCHAINID
///        contracts from `out-onchainid/` (the `onchainid` profile, via_ir, as upstream ships them). Nothing is
///        stored: the address table (deploy/addresses/<env>.json) records every row's init code hash, and the
///        broadcasting scripts refuse to run when the build no longer matches it.
///      - Third-party bytes that cannot come from our build, committed under deploy/vendor/: the CreateX creation
///        code (pinned below by hash, checked on every read) and the Safe v1.4.1 bytes, which are read only where a
///        chain lacks the canonical contracts (a bare local chain) and to predict Safe addresses offline.
library BytecodeStore {

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant VENDOR_DIR = "deploy/vendor/";
    /// @dev keccak256 of the CreateX creation code (pcaversaccio/createx, see deploy/vendor/vendor.json for the
    ///      commit and compiler settings it rebuilds from). Every address derives from it.
    bytes32 internal constant CREATEX_INITCODE_HASH =
        0x12ec861579b63a3ab9db3b5a23c57d56402ad3061475b088f17054e2f2daf22f;
    /// @dev The command that produces the ONCHAINID artifacts, named in every "missing artifact" message.
    string internal constant ONCHAINID_BUILD =
        "FOUNDRY_PROFILE=onchainid forge build (the 8 ONCHAINID paths listed in deploy/README.md)";

    // ---- Third-party contracts every chain is expected to have, or that the genesis script can recreate ----

    /// @dev Keyless CREATE2 factory (Arachnid deterministic deployment proxy): the anchor every address hangs on.
    address internal constant ANCHOR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev Runtime code hash of the anchor, as OpenZeppelin's review requires it to be checked.
    bytes32 internal constant ANCHOR_CODEHASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    /// @dev Safe Singleton Factory: same 69-byte runtime as the anchor; deploys the Safe v1.4.1 contracts.
    address internal constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;

    // Safe v1.4.1 canonical addresses (safe-global/safe-deployments v1.4.1, checked in VendorBytecode.t.sol).
    address internal constant SAFE = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant COMPATIBILITY_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant MULTI_SEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address internal constant SAFE_TO_L2_SETUP = 0xBD89A1CE4DDe368FFAB0eC35506eEcE0b1fFdc54;

    struct VendorContract {
        string name;
        address canonical;
    }

    /// @notice The Safe v1.4.1 contracts the deployment relies on, in deployment order: the two singletons, the
    ///         proxy factory, the fallback handler the Safes are set up with, MultiSendCallOnly (the Transaction
    ///         Builder batches through it) and SafeToL2Setup (the chain-independent setup).
    function safeContracts() internal pure returns (VendorContract[] memory list) {
        list = new VendorContract[](6);
        list[0] = VendorContract("Safe", SAFE);
        list[1] = VendorContract("SafeL2", SAFE_L2);
        list[2] = VendorContract("SafeProxyFactory", SAFE_PROXY_FACTORY);
        list[3] = VendorContract("CompatibilityFallbackHandler", COMPATIBILITY_FALLBACK_HANDLER);
        list[4] = VendorContract("MultiSendCallOnly", MULTI_SEND_CALL_ONLY);
        list[5] = VendorContract("SafeToL2Setup", SAFE_TO_L2_SETUP);
    }

    function createxInitCode() internal view returns (bytes memory code) {
        code = _readHex(string.concat(VENDOR_DIR, "createx.hex"));
        require(keccak256(code) == CREATEX_INITCODE_HASH, "BytecodeStore: deploy/vendor/createx.hex changed");
    }

    /// @notice Creation code of a Safe contract. Read only to deploy it where a chain lacks it (a bare local chain).
    function safeInitCode(string memory name) internal view returns (bytes memory) {
        return _readHex(string.concat(VENDOR_DIR, "safe-1.4.1/", name, ".hex"));
    }

    /// @notice `SafeProxyFactory.proxyCreationCode()`, for predicting Safe addresses where the factory is not on the
    ///         chain being planned for (offline address table, bare local chain).
    function safeProxyCreationCode() internal view returns (bytes memory) {
        return _readHex(string.concat(VENDOR_DIR, "safe-1.4.1/SafeProxy.hex"));
    }

    /// @notice Runtime code of the anchor and of the Safe Singleton Factory (they are the same), for local chains.
    function create2FactoryRuntime() internal view returns (bytes memory) {
        return _readHex(string.concat(VENDOR_DIR, "create2-factory-runtime.hex"));
    }

    /// @notice Init code hash of a Safe contract, from deploy/vendor/vendor.json (the address table records it).
    function safeInitCodeHash(string memory name) internal view returns (bytes32) {
        string memory json = VM.readFile(string.concat(VENDOR_DIR, "vendor.json"));
        return VM.parseJsonBytes32(json, string.concat(".safe.contracts.", name, ".initCodeHash"));
    }

    /// @notice Expected runtime code hash of a vendored Safe contract, from deploy/vendor/vendor.json.
    function safeRuntimeCodeHash(string memory name) internal view returns (bytes32) {
        string memory json = VM.readFile(string.concat(VENDOR_DIR, "vendor.json"));
        return VM.parseJsonBytes32(json, string.concat(".safe.contracts.", name, ".runtimeCodeHash"));
    }

    // ---- T-REX and ONCHAINID bytecode, from the build ----

    /// @notice One deployable contract: where its artifact is and which libraries it links.
    struct ReleaseContract {
        string name;
        // "default" (out/) or "onchainid" (via_ir build, out-onchainid/).
        string profile;
        // Artifact file name under the profile's output dir, e.g. "Token.sol".
        string artifactFile;
        // Indices into {libraries} this contract links against.
        uint8[] links;
    }

    /// @notice The seven linked libraries, by fully qualified name, in deployment order: TokenDelegationLib
    ///         links TREXMessagingLib and TokenLedgerLib, so both come before it.
    function libraries() internal pure returns (string[7] memory names, string[7] memory fullyQualified) {
        names = [
            "TREXMessagingLib",
            "TokenLedgerLib",
            "TokenRecoveryLib",
            "TokenGuardsLib",
            "TokenDelegationLib",
            "ModuleSetLib",
            "TransferValidationLib"
        ];
        fullyQualified = [
            "contracts/interop/TREXMessagingLib.sol:TREXMessagingLib",
            "contracts/token/TokenLedgerLib.sol:TokenLedgerLib",
            "contracts/token/TokenRecoveryLib.sol:TokenRecoveryLib",
            "contracts/token/TokenGuardsLib.sol:TokenGuardsLib",
            "contracts/token/TokenDelegationLib.sol:TokenDelegationLib",
            "contracts/compliance/modular/ModuleSetLib.sol:ModuleSetLib",
            "contracts/compliance/modular/TransferValidationLib.sol:TransferValidationLib"
        ];
    }

    /// @notice Every contract a release ships, libraries first.
    function releaseContracts() internal pure returns (ReleaseContract[] memory list) {
        list = new ReleaseContract[](32);
        uint8[] memory none = new uint8[](0);
        (string[7] memory libs,) = libraries();
        for (uint256 i = 0; i < 7; i++) {
            list[i] = ReleaseContract(libs[i], "default", string.concat(libs[i], ".sol"), none);
        }
        uint8[] memory delegationLinks = new uint8[](2);
        delegationLinks[0] = 0; // TREXMessagingLib
        delegationLinks[1] = 1; // TokenLedgerLib
        list[4].links = delegationLinks;
        uint8[] memory tokenLinks = new uint8[](5);
        for (uint8 i = 0; i < 5; i++) {
            tokenLinks[i] = i;
        }
        uint8[] memory mcLinks = new uint8[](2);
        mcLinks[0] = 5;
        mcLinks[1] = 6;
        list[7] = ReleaseContract("Token", "default", "Token.sol", tokenLinks);
        list[8] = ReleaseContract("ModularCompliance", "default", "ModularCompliance.sol", mcLinks);
        list[9] = ReleaseContract("TREXRegistry", "default", "TREXRegistry.sol", none);
        list[10] = ReleaseContract("IdentityRegistryStorage", "default", "IdentityRegistryStorage.sol", none);
        list[11] = ReleaseContract("TREXAccessManager", "default", "TREXAccessManager.sol", none);
        list[12] = ReleaseContract("TREXImplementationAuthority", "default", "TREXImplementationAuthority.sol", none);
        list[13] = ReleaseContract("TrustedGatewayRegistry", "default", "TrustedGatewayRegistry.sol", none);
        list[14] = ReleaseContract("TREXFactory", "default", "TREXFactory.sol", none);
        list[15] = ReleaseContract("SpenderVerificationModule", "default", "SpenderVerificationModule.sol", none);
        list[16] = ReleaseContract("SpenderWhitelistModule", "default", "SpenderWhitelistModule.sol", none);
        list[17] = ReleaseContract("MaxBalancePerIdentityModule", "default", "MaxBalancePerIdentityModule.sol", none);
        list[18] = ReleaseContract("ModuleProxy", "default", "ModuleProxy.sol", none);
        list[19] = ReleaseContract("UtilityChecker", "default", "UtilityChecker.sol", none);
        list[20] = ReleaseContract("UtilityCheckerProxy", "default", "UtilityCheckerProxy.sol", none);
        list[21] = ReleaseContract("UtilityCheckerDeployer", "default", "UtilityCheckerDeployer.sol", none);
        list[22] = ReleaseContract("AccessManager", "default", "AccessManager.sol", none);
        list[23] = ReleaseContract("IdentityFactory", "onchainid", "IdentityFactory.sol", none);
        list[24] = ReleaseContract("Identity", "onchainid", "Identity.sol", none);
        list[25] = ReleaseContract("IdentityUtilities", "onchainid", "IdentityUtilities.sol", none);
        list[26] = ReleaseContract("IdentityUtilitiesProxy", "onchainid", "IdentityUtilitiesProxy.sol", none);
        list[27] = ReleaseContract("ERC734Validator", "onchainid", "ERC734Validator.sol", none);
        list[28] = ReleaseContract("KeyApprovalModule", "onchainid", "KeyApprovalModule.sol", none);
        list[29] = ReleaseContract("ReputationRegistry", "onchainid", "ReputationRegistry.sol", none);
        list[30] = ReleaseContract("ERC7913WebAuthnVerifier", "onchainid", "ERC7913WebAuthnVerifier.sol", none);
        list[31] = ReleaseContract("RoleRevoker", "default", "RoleRevoker.sol", none);
    }

    function releaseContract(string memory name) internal pure returns (ReleaseContract memory) {
        ReleaseContract[] memory list = releaseContracts();
        for (uint256 i = 0; i < list.length; i++) {
            if (keccak256(bytes(list[i].name)) == keccak256(bytes(name))) return list[i];
        }
        revert(string.concat("BytecodeStore: unknown contract ", name));
    }

    /// @notice The build artifact a contract is read from.
    function artifactPath(ReleaseContract memory c) internal pure returns (string memory) {
        return string.concat(_isOnchainid(c) ? "out-onchainid/" : "out/", c.artifactFile, "/", c.name, ".json");
    }

    function _isOnchainid(ReleaseContract memory c) private pure returns (bool) {
        return keccak256(bytes(c.profile)) == keccak256("onchainid");
    }

    /// @notice Whether every ONCHAINID artifact is built. `forge test` builds `out/` itself; `out-onchainid/` needs
    ///         {ONCHAINID_BUILD} first.
    function onchainidBuilt() internal view returns (bool) {
        ReleaseContract[] memory list = releaseContracts();
        for (uint256 i = 0; i < list.length; i++) {
            if (_isOnchainid(list[i]) && !VM.isFile(artifactPath(list[i]))) return false;
        }
        return true;
    }

    /// @dev The artifact path of `name`, after checking it is built.
    function _builtPath(string memory name) private view returns (string memory path, ReleaseContract memory c) {
        c = releaseContract(name);
        path = artifactPath(c);
        require(
            VM.isFile(path),
            string.concat(
                "BytecodeStore: missing artifact ",
                path,
                _isOnchainid(c) ? string.concat("; run ", ONCHAINID_BUILD) : "; run forge build"
            )
        );
    }

    /// @dev The whole artifact JSON. Expensive in EVM memory (artifacts are hundreds of KB, mostly metadata), so it
    ///      is read only where the bytecode itself cannot come from `getCode`: linked contracts and immutables.
    function _artifact(string memory name) private view returns (string memory json, ReleaseContract memory c) {
        string memory path;
        (path, c) = _builtPath(name);
        json = VM.readFile(path);
    }

    /// @notice Creation code of `name` from the build, unlinked (library placeholders still in). Reverts when the
    ///         artifact's link references no longer match {releaseContracts}.
    function unlinkedInitCodeHex(string memory name) internal view returns (string memory initHex) {
        (string memory artifact, ReleaseContract memory c) = _artifact(name);
        _requireLinksMatch(artifact, c);
        initHex = VM.parseJsonString(artifact, ".bytecode.object");
    }

    /// @notice Runtime code of `name` from the build, immutables zero as solc emits them. Only for contracts that
    ///         link no library (every CREATE3 contract): a linked runtime still has placeholders.
    function runtimeCode(string memory name) internal view returns (bytes memory) {
        (string memory path,) = _builtPath(name);
        return VM.getDeployedCode(path);
    }

    /// @dev A contract that links no library comes straight from `getCode`, which reads the artifact natively (no
    ///      JSON in EVM memory) and refuses bytecode that still has library placeholders, so a library added to it
    ///      fails here. The three linked contracts are read as JSON and linked by {LinkerLib}.
    function initCode(string memory name, address[7] memory libraryAddresses) internal view returns (bytes memory) {
        (string memory path, ReleaseContract memory c) = _builtPath(name);
        if (c.links.length == 0) return VM.getCode(path);
        (, string[7] memory fqn) = libraries();
        LinkerLib.Link[] memory links = new LinkerLib.Link[](c.links.length);
        for (uint256 i = 0; i < c.links.length; i++) {
            links[i] = LinkerLib.Link(fqn[c.links[i]], libraryAddresses[c.links[i]]);
        }
        return LinkerLib.link(unlinkedInitCodeHex(name), links);
    }

    /// @dev One immutable reference. Fields in alphabetical order, as forge decodes JSON objects.
    struct ImmutableRef {
        uint256 length;
        uint256 start;
    }

    /// @notice Immutable ranges of `name`'s runtime code, from `deployedBytecode.immutableReferences`.
    function immutableRanges(string memory name)
        internal
        view
        returns (uint256[] memory starts, uint256[] memory lengths)
    {
        (string memory artifact,) = _artifact(name);
        string memory base = ".deployedBytecode.immutableReferences";
        if (!VM.keyExistsJson(artifact, base)) return (new uint256[](0), new uint256[](0));
        string[] memory ids = VM.parseJsonKeys(artifact, base);
        ImmutableRef[][] memory refs = new ImmutableRef[][](ids.length);
        uint256 total;
        for (uint256 i = 0; i < ids.length; i++) {
            refs[i] = abi.decode(VM.parseJson(artifact, string.concat(base, ".", ids[i])), (ImmutableRef[]));
            total += refs[i].length;
        }
        starts = new uint256[](total);
        lengths = new uint256[](total);
        uint256 k;
        for (uint256 i = 0; i < refs.length; i++) {
            for (uint256 j = 0; j < refs[i].length; j++) {
                starts[k] = refs[i][j].start;
                lengths[k] = refs[i][j].length;
                k++;
            }
        }
    }

    /// @dev The links hardcoded in {releaseContracts} must be exactly the artifact's link references, so a new
    ///      library (or a removed one) fails loudly instead of deploying unlinked code.
    function _requireLinksMatch(string memory artifact, ReleaseContract memory c) private view {
        string memory base = ".bytecode.linkReferences";
        string[] memory sources = VM.keyExistsJson(artifact, base) ? VM.parseJsonKeys(artifact, base) : new string[](0);
        require(
            sources.length == c.links.length,
            string.concat("BytecodeStore: link references changed for ", c.name, "; update releaseContracts")
        );
        (, string[7] memory fqn) = libraries();
        for (uint256 i = 0; i < c.links.length; i++) {
            string memory source = VM.split(fqn[c.links[i]], ":")[0];
            bool found;
            for (uint256 j = 0; j < sources.length; j++) {
                if (keccak256(bytes(sources[j])) == keccak256(bytes(source))) found = true;
            }
            require(found, string.concat("BytecodeStore: ", c.name, " no longer links ", source));
        }
    }

    /// @notice keccak256 of `code` with the given ranges zeroed: compares runtime code whose immutables differ.
    function maskedHash(bytes memory code, uint256[] memory starts, uint256[] memory lengths)
        internal
        pure
        returns (bytes32)
    {
        bytes memory copy = new bytes(code.length);
        for (uint256 i = 0; i < code.length; i++) {
            copy[i] = code[i];
        }
        for (uint256 r = 0; r < starts.length; r++) {
            for (uint256 i = starts[r]; i < starts[r] + lengths[r] && i < copy.length; i++) {
                copy[i] = 0;
            }
        }
        return keccak256(copy);
    }

    function _readHex(string memory path) private view returns (bytes memory) {
        return VM.parseBytes(VM.trim(VM.readFile(path)));
    }

}
