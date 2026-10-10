// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @dev An identity that reports, for any claim id, a claim on `topic` from `issuer`. An agent can register any
///  contract as an identity in the local storage, so the registry must not trust what it reports.
contract StampForgingIdentity {

    address public immutable issuer;
    uint256 public immutable topic;

    constructor(address issuer_, uint256 topic_) {
        issuer = issuer_;
        topic = topic_;
    }

    function getClaim(bytes32)
        external
        view
        returns (uint256, uint256, address, bytes memory, Structs.ClaimData memory, string memory)
    {
        Structs.ClaimData memory data =
            Structs.ClaimData({ issuedAt: 1, validUntil: 0, metadataHash: bytes32(0), payload: "" });
        return (topic, 1, issuer, hex"00", data, "");
    }

}

/// @dev A claim issuer that answers nothing: every call lands on an empty fallback.
contract SilentClaimIssuer {

    fallback() external { }

}

/// @dev A claim issuer whose answer is a full word that is not `true`.
contract NonBooleanClaimIssuer {

    fallback() external {
        assembly {
            mstore(0x00, 2)
            return(0x00, 0x20)
        }
    }

}

/// @dev A claim issuer that calls every claim valid.
contract AlwaysValidClaimIssuer {

    function isClaimValid(IIdentity, uint256, bytes calldata, Structs.ClaimData calldata) external pure returns (bool) {
        return true;
    }

}

/// @notice A trusted issuer that does not answer `isClaimValid` with `true` never validates a claim, in the registry
///  and in the UtilityChecker alike. Before the fix, an issuer that answered nothing passed `isVerified`, because the
///  answer was read from leftover memory, and made `getVerifiedDetails` revert.
contract SilentClaimIssuerTest is TREXSuiteTest {

    UtilityChecker internal utilityChecker;

    function setUp() public override {
        super.setUp();
        utilityChecker = UtilityChecker(
            address(
                new UtilityCheckerProxy(
                    address(new UtilityChecker()), abi.encodeCall(UtilityChecker.initialize, (address(accessManager)))
                )
            )
        );
    }

    // ============ isVerified ============

    function test_isVerified_RefusesAWalletAsIssuer() public {
        (, TREXRegistry registry) = _trustIssuerAndRegisterForgedStamp("wallet-issuer", makeAddr("walletIssuer"));

        assertFalse(registry.isVerified(david));
    }

    function test_isVerified_RefusesAnIssuerThatAnswersNothing() public {
        (, TREXRegistry registry) =
            _trustIssuerAndRegisterForgedStamp("silent-issuer", address(new SilentClaimIssuer()));

        assertFalse(registry.isVerified(david));
    }

    function test_isVerified_RefusesAnAnswerThatIsNotTrue() public {
        (, TREXRegistry registry) =
            _trustIssuerAndRegisterForgedStamp("non-boolean-issuer", address(new NonBooleanClaimIssuer()));

        assertFalse(registry.isVerified(david));
    }

    // ============ getVerifiedDetails ============

    function test_getVerifiedDetails_ReportsAWalletIssuerAsFailing() public {
        (Token token,) = _trustIssuerAndRegisterForgedStamp("wallet-issuer", makeAddr("walletIssuer"));

        (UtilityChecker.EligibilityCheckDetails[] memory details,) =
            utilityChecker.getVerifiedDetails(address(token), david);

        assertFalse(details[0].pass);
    }

    function test_getVerifiedDetails_ReportsAnIssuerThatAnswersNothingAsFailing() public {
        (Token token,) = _trustIssuerAndRegisterForgedStamp("silent-issuer", address(new SilentClaimIssuer()));

        (UtilityChecker.EligibilityCheckDetails[] memory details,) =
            utilityChecker.getVerifiedDetails(address(token), david);

        assertFalse(details[0].pass);
    }

    /// @notice A claim filed under the trusted issuer's id but naming another issuer counts for neither side: the
    ///  registry skips it, and the UtilityChecker must not ask the issuer the claim names.
    function test_getVerifiedDetails_IgnoresAClaimNamingAnotherIssuer() public {
        Token token = _deployTokenWithClaimTopic("other-issuer", "OTH", "OTH");
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        _trust(registry, address(new SilentClaimIssuer()));
        StampForgingIdentity forged = new StampForgingIdentity(address(new AlwaysValidClaimIssuer()), CLAIM_TOPIC_1);
        vm.prank(agent);
        registry.registerIdentity(david, IIdentity(address(forged)), 0);

        (UtilityChecker.EligibilityCheckDetails[] memory details,) =
            utilityChecker.getVerifiedDetails(address(token), david);

        assertFalse(registry.isVerified(david), "the registry skips a claim naming another issuer");
        assertFalse(details[0].pass, "the UtilityChecker must agree with the registry");
    }

    // ============ helpers ============

    /// @dev Deploys a token requiring `CLAIM_TOPIC_1`, trusts `issuer` for it, and registers `david` with an identity
    ///  reporting a claim from `issuer`.
    function _trustIssuerAndRegisterForgedStamp(string memory salt, address issuer)
        internal
        returns (Token token, TREXRegistry registry)
    {
        token = _deployTokenWithClaimTopic(salt, salt, salt);
        registry = TREXRegistry(address(token.identityRegistry()));
        _trust(registry, issuer);
        StampForgingIdentity forged = new StampForgingIdentity(issuer, CLAIM_TOPIC_1);
        vm.prank(agent);
        registry.registerIdentity(david, IIdentity(address(forged)), 0);
    }

    function _trust(TREXRegistry registry, address issuer) internal {
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        registry.addTrustedIssuer(issuer, topics);
    }

}
