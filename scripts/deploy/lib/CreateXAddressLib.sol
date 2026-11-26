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

/// @title CreateXAddressLib
/// @notice Address math for the deployment, computed without calling any chain.
/// @dev Three ways an address is made here:
///      - plain CREATE2 (`create2`), used for the anchor (keyless CREATE2 factory) deploying the Genesis Deployer
///        and for the Safe Singleton Factory;
///      - CreateX `deployCreate2` with a permissionless salt: the salt's first 20 bytes are neither zero nor the
///        caller, so CreateX guards it as `keccak256(abi.encode(salt))` and anyone can deploy the same bytecode at
///        the same address on every chain (`create2ViaCreateX`);
///      - CreateX `deployCreate3` with a salt bound to the caller (`bytes20(sender) ‖ 0x00 ‖ 11 bytes`): the 0x00
///        flag keeps the chain id out of the guard, so the address depends only on the sender and the label
///        (`create3ViaCreateX`).
///      The guard and proxy math mirrors CreateX v1 (`_guard`, `_parseSalt`, `computeCreate3Address`). It is
///      checked against the vendored CreateX bytecode in test/unit/deploy/CreateXAddressLib.t.sol.
library CreateXAddressLib {

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev keccak256 of CreateX's CREATE3 proxy init code `0x67363d3d37363d34f03d5260086018f3`. Not the same proxy
    ///      as OpenZeppelin's `Create3` library (whose hash is 0x57a34f6e…), so the two give different addresses.
    bytes32 internal constant CREATE3_PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    error SaltPrefixNotRandom(bytes32 salt);

    /// @notice The address `deployer` creates with CREATE2 for `salt` and init code hash `initCodeHash`.
    function create2(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return VM.computeCreate2Address(salt, initCodeHash, deployer);
    }

    /// @notice The address `deployer` creates with CREATE at `nonce`.
    function createAt(address deployer, uint8 nonce) internal pure returns (address) {
        return VM.computeCreateAddress(deployer, nonce);
    }

    /// @notice A CreateX salt bound to `sender`, with redeploy protection off (same address on every chain).
    /// @param label Any 32 bytes; the first 11 bytes of `keccak256(abi.encode(label))` fill the rest.
    function permissionedSalt(address sender, bytes32 label) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(bytes20(sender), bytes1(0x00), bytes11(keccak256(abi.encode(label)))));
    }

    /// @notice The salt CreateX actually uses for a `permissionedSalt` called by `sender`.
    function guardPermissioned(address sender, bytes32 salt) internal pure returns (bytes32) {
        // Taking the salt's first 20 bytes is the point: CreateX reads them as the address the salt is bound to.
        // forge-lint: disable-next-line(unsafe-typecast)
        require(address(bytes20(salt)) == sender && salt[20] == 0x00, "CreateXAddressLib: salt not bound to sender");
        return keccak256(abi.encode(bytes32(uint256(uint160(sender))), salt));
    }

    /// @notice The salt CreateX actually uses for a permissionless salt (first 20 bytes random, not the caller).
    function guardRandom(bytes32 salt) internal pure returns (bytes32) {
        // Taking the salt's first 20 bytes is the point: CreateX reads them as the address the salt is bound to.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(bytes20(salt)) == address(0)) revert SaltPrefixNotRandom(salt);
        return keccak256(abi.encode(salt));
    }

    /// @notice The address CreateX `createx` gives `deployCreate2(salt, initCode)` for a permissionless salt.
    function create2ViaCreateX(address createx, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return create2(createx, guardRandom(salt), initCodeHash);
    }

    /// @notice The address CreateX `createx` gives `deployCreate3(salt, initCode)` when `sender` calls it with a
    ///         salt bound to itself.
    function create3ViaCreateX(address createx, address sender, bytes32 salt) internal pure returns (address) {
        return create3FromGuarded(createx, guardPermissioned(sender, salt));
    }

    /// @notice CreateX `computeCreate3Address(guardedSalt, createx)`.
    function create3FromGuarded(address createx, bytes32 guardedSalt) internal pure returns (address) {
        address proxy = create2(createx, guardedSalt, CREATE3_PROXY_INITCODE_HASH);
        return createAt(proxy, 1);
    }

}
