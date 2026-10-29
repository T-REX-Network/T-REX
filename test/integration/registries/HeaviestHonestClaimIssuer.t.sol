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

import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import {
    ERC7913WebAuthnVerifier
} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913WebAuthnVerifier.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice The gas cap on each `isClaimValid` call must not refuse an honest issuer. The heaviest one ONCHAINID
///  supports is an issuer whose claim signer is a WebAuthn key, checked in Solidity on a chain without the P-256
///  precompile, here with a claim carrying the largest payload ONCHAINID accepts. The claim is added in `setUp`, so
///  the test runs the check cold, as a transfer would.
contract HeaviestHonestClaimIssuerTest is TREXSuiteTest {

    /// @dev Order of the P-256 curve. A signature is accepted only with `s` in the lower half.
    uint256 internal constant P256_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    uint256 internal constant WEBAUTHN_PRIVATE_KEY = 0xA11CE;

    IERC3643IdentityRegistry internal identityRegistry;

    function setUp() public override {
        super.setUp();
        Token token = _deployTokenWithClaimTopic("webauthn-issuer", "WEB", "WEB");
        identityRegistry = token.identityRegistry();

        (uint256 publicKeyX, uint256 publicKeyY) = vm.publicKeyP256(WEBAUTHN_PRIVATE_KEY);
        bytes memory webAuthnSigner = abi.encodePacked(address(new ERC7913WebAuthnVerifier()), publicKeyX, publicKeyY);
        Identity webAuthnIssuer = _deployWebAuthnClaimIssuer(webAuthnSigner);
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        identityRegistry.issuersRegistry().addTrustedIssuer(address(webAuthnIssuer), topics);

        Structs.ClaimData memory data = Structs.ClaimData({
            issuedAt: block.timestamp,
            validUntil: 0,
            metadataHash: validatorModule.getMetadataHash(1, "uri"),
            payload: new bytes(Structs.MAX_CLAIM_PAYLOAD_LENGTH)
        });
        bytes32 digest = IIdentity(address(webAuthnIssuer)).getClaimHash(address(aliceIdentity), CLAIM_TOPIC_1, data);
        bytes memory signature = abi.encode(webAuthnSigner, _webAuthnSignature(digest));

        _registerIdentities(token);
        vm.prank(alice);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(webAuthnIssuer), signature, data, "uri");
    }

    function test_isVerified_AcceptsAWebAuthnIssuerWithTheLargestPayload() public view {
        assertTrue(identityRegistry.isVerified(alice));
    }

    /// @dev A claim issuer identity whose CLAIM_SIGNER key is `signer`. The factory only grants keys of the account
    ///  it deploys for, so the WebAuthn key is added afterwards by that account.
    function _deployWebAuthnClaimIssuer(bytes memory signer) internal returns (Identity issuer) {
        address issuerManager = makeAddr("webAuthnIssuerManager");
        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = _ecdsaKey(issuerManager, KeyPurposes.MANAGEMENT);
        vm.prank(deployer);
        issuer = Identity(
            payable(idFactory.createIdentityFor(issuerManager, IdentityTypes.CLAIM_ISSUER, "webauthn-issuer", keys))
        );
        vm.prank(issuerManager);
        issuer.addKeyWithData(keccak256(signer), KeyPurposes.CLAIM_SIGNER, KeyTypes.WEBAUTHN, signer, "");
    }

    /// @dev A WebAuthn assertion over `challenge`, encoded as the verifier reads it: the fields in order, not a
    ///  struct with a leading offset.
    function _webAuthnSignature(bytes32 challenge) internal pure returns (bytes memory) {
        string memory clientDataJSON = string.concat(
            '{"type":"webauthn.get","challenge":"',
            Base64.encodeURL(abi.encodePacked(challenge)),
            '","origin":"https://example.com","crossOrigin":false}'
        );
        // Flags 0x05: user present and user verified, both required by the verifier.
        bytes memory authenticatorData = abi.encodePacked(sha256("example.com"), bytes1(0x05), uint32(1));
        bytes32 message = sha256(abi.encodePacked(authenticatorData, sha256(bytes(clientDataJSON))));
        (bytes32 r, bytes32 s) = vm.signP256(WEBAUTHN_PRIVATE_KEY, message);
        if (uint256(s) > P256_ORDER / 2) s = bytes32(P256_ORDER - uint256(s));
        uint256 challengeIndex = 23;
        uint256 typeIndex = 1;
        return abi.encode(r, s, challengeIndex, typeIndex, authenticatorData, clientDataJSON);
    }

}
