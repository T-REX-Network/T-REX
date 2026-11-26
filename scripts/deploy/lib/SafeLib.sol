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

import { CreateXAddressLib } from "./CreateXAddressLib.sol";

/// @dev The parts of Safe v1.4.1 the deployment calls.
interface ISafe {

    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function approveHash(bytes32 hashToApprove) external;

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function nonce() external view returns (uint256);

    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);

}

interface ISafeProxyFactory {

    function proxyCreationCode() external pure returns (bytes memory);

    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);

}

interface ISafeToL2Setup {

    function setupToL2(address l2Singleton) external;

}

/// @title SafeLib
/// @notice Safe v1.4.1 address prediction, setup encoding and pre-approved signatures.
/// @dev Every Safe is created through the canonical SafeProxyFactory with the L1 singleton and a `setup` that
///      delegatecalls SafeToL2Setup, which switches the proxy to the L2 singleton on every chain but Ethereum
///      mainnet. The `setup` call is then byte-identical on every chain, and so is the Safe's address: same owner
///      order, threshold, fallback handler and salt nonce, and no payment refund (OpenZeppelin review §Safes).
library SafeLib {

    /// @dev Safe signature type for an owner that approved the hash on chain with `approveHash`.
    uint8 internal constant APPROVED_HASH = 1;

    /// @notice The `setup` initializer every T-REX Safe uses.
    function initializer(
        address[] memory owners,
        uint256 threshold,
        address safeToL2Setup,
        address safeL2Singleton,
        address fallbackHandler
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ISafe.setup,
            (
                owners,
                threshold,
                safeToL2Setup,
                abi.encodeCall(ISafeToL2Setup.setupToL2, (safeL2Singleton)),
                fallbackHandler,
                address(0),
                0,
                payable(address(0))
            )
        );
    }

    /// @notice SafeProxyFactory v1.4.1 `createProxyWithNonce` address.
    /// @param proxyCreationCode `SafeProxyFactory.proxyCreationCode()`, vendored as deploy/vendor/safe-1.4.1/SafeProxy.hex.
    function proxyAddress(
        address factory,
        address singleton,
        bytes memory setupData,
        uint256 saltNonce,
        bytes memory proxyCreationCode
    ) internal pure returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(setupData), saltNonce));
        bytes32 initCodeHash = keccak256(abi.encodePacked(proxyCreationCode, uint256(uint160(singleton))));
        return CreateXAddressLib.create2(factory, salt, initCodeHash);
    }

    /// @notice Signatures for `owners` who all called `approveHash`, sorted ascending as Safe requires.
    /// @dev Sorts a copy; `owners` is left as given.
    function approvedHashSignatures(address[] memory owners) internal pure returns (bytes memory signatures) {
        address[] memory sorted = new address[](owners.length);
        for (uint256 i = 0; i < owners.length; i++) {
            sorted[i] = owners[i];
        }
        for (uint256 i = 1; i < sorted.length; i++) {
            address key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }
        for (uint256 i = 0; i < sorted.length; i++) {
            signatures = abi.encodePacked(signatures, bytes32(uint256(uint160(sorted[i]))), bytes32(0), APPROVED_HASH);
        }
    }

}
