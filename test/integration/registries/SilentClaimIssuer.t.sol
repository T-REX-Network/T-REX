// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @dev An identity that reports, for any claim id, a claim on `topic` from `issuer`. An agent can register any
///  contract as an identity in the local storage, so the registry must not trust what it reports.
/// @dev An identity that reports a claim for whichever of its issuers `claimId` names, and the first issuer's
///  claim for any other `claimId`.
contract IdentityWithClaims {

    uint256 public immutable topic;
    address[] public issuers;

    constructor(address issuer_, uint256 topic_) {
        issuers.push(issuer_);
        topic = topic_;
    }

    function addIssuer(address issuer_) external {
        issuers.push(issuer_);
    }

    function getClaim(bytes32 claimId)
        external
        view
        returns (uint256, uint256, address, bytes memory, Structs.ClaimData memory, string memory)
    {
        address issuer = issuers[0];
        for (uint256 i = 0; i < issuers.length; i++) {
            if (keccak256(abi.encode(issuers[i], topic)) == claimId) issuer = issuers[i];
        }
        Structs.ClaimData memory data =
            Structs.ClaimData({ issuedAt: 1, validUntil: 0, metadataHash: bytes32(0), payload: "" });
        return (topic, 1, issuer, hex"00", data, "");
    }

}

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

/// @dev A claim issuer that calls every claim valid until it starts burning all the gas it is given, as a trusted
///  issuer that turns hostile after its claims were added.
contract GasBurningClaimIssuer {

    bool public burnsGas;

    function startBurningGas() external {
        burnsGas = true;
    }

    function isClaimValid(IIdentity, uint256, bytes calldata, Structs.ClaimData calldata) external view returns (bool) {
        while (burnsGas) { }
        return true;
    }

}

/// @dev A claim issuer that calls every claim valid.
contract AlwaysValidClaimIssuer {

    function isClaimValid(IIdentity, uint256, bytes calldata, Structs.ClaimData calldata) external pure returns (bool) {
        return true;
    }

}

/// @notice A claim issuer that cannot answer `isClaimValid` never validates a claim. A wallet cannot be trusted at
///  all, and an issuer contract that answers nothing or something that is not a bool is skipped like an invalid
///  claim, so another trusted issuer for the topic can still verify the holder. Before the fix, both passed
///  `isVerified`, because the answer was read from leftover memory.
contract SilentClaimIssuerTest is TREXSuiteTest {

    UtilityChecker internal utilityChecker;

    function setUp() public override {
        super.setUp();
        utilityChecker = UtilityChecker(
            address(
                new UtilityCheckerProxy(address(new UtilityChecker()), abi.encodeCall(UtilityChecker.initialize, ()))
            )
        );
    }

    function test_addTrustedIssuer_RevertWhen_IssuerIsAWallet() public {
        Token token = _deployTokenWithClaimTopic("wallet-issuer", "WAL", "WAL");
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        address walletIssuer = makeAddr("walletIssuer");
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ERC3643ErrorsLib.TrustedIssuerHasNoCode.selector, walletIssuer));
        registry.addTrustedIssuer(walletIssuer, topics);
    }

    /// @notice An empty answer is not `true`: the claim does not count, and the check does not revert.
    function test_isVerified_IsFalseWhen_TheIssuerAnswersNothing() public {
        TREXRegistry registry = _trustIssuerAndRegisterHolder("silent-issuer", address(new SilentClaimIssuer()));

        assertFalse(registry.isVerified(david));
    }

    function test_isVerified_IsFalseWhen_TheAnswerIsNotABool() public {
        TREXRegistry registry =
            _trustIssuerAndRegisterHolder("non-boolean-issuer", address(new NonBooleanClaimIssuer()));

        assertFalse(registry.isVerified(david));
    }

    /// @notice A broken issuer is skipped, not fatal: a second trusted issuer for the same topic still verifies the
    ///         holder, and the UtilityChecker reports the same per issuer.
    function test_isVerified_SkipsASilentIssuerAndCountsTheNextOne() public {
        Token token = _deployTokenWithClaimTopic("two-issuers", "TWO", "TWO");
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        address silentIssuer = address(new SilentClaimIssuer());
        address validIssuer = address(new AlwaysValidClaimIssuer());
        _trust(registry, silentIssuer);
        _trust(registry, validIssuer);
        IdentityWithClaims holder = new IdentityWithClaims(silentIssuer, CLAIM_TOPIC_1);
        holder.addIssuer(validIssuer);
        vm.prank(agent);
        registry.registerIdentity(david, IIdentity(address(holder)), 0);

        assertTrue(registry.isVerified(david), "the valid issuer's claim counts");
        (UtilityChecker.EligibilityCheckDetails[] memory details,) =
            utilityChecker.getVerifiedDetails(address(token), david);
        assertEq(address(details[0].issuer), validIssuer, "the UtilityChecker reports the issuer that passed");
        assertTrue(details[0].pass, "the UtilityChecker agrees");
    }

    /// @notice An issuer that burns its gas gets a capped share, so the registry still has the gas to ask the next
    ///  trusted issuer. Uncapped, it took 63/64 of the gas and left too little for the next issuer, here the suite's
    ///  ONCHAINID claim issuer checking a real signed claim. The gas limit is one a wallet could set for a transfer.
    function test_isVerified_SkipsAGasBurningIssuerAndCountsTheNextOne() public {
        Token token = _deployTokenWithClaimTopic("gas-burner", "GAS", "GAS");
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        GasBurningClaimIssuer gasBurningIssuer = new GasBurningClaimIssuer();
        // The registry asks issuers in the order they were trusted, so the burner goes ahead of the valid issuer.
        vm.prank(deployer);
        registry.removeTrustedIssuer(address(claimIssuer));
        _trust(registry, address(gasBurningIssuer));
        _trust(registry, address(claimIssuer));
        _registerIdentities(token);
        _addClaim(aliceIdentity, CLAIM_TOPIC_1, "kyc", claimIssuerSigner.key, address(claimIssuer), alice);
        Structs.ClaimData memory data = Structs.ClaimData({
            issuedAt: block.timestamp,
            validUntil: 0,
            metadataHash: validatorModule.getMetadataHash(1, "uri"),
            payload: ""
        });
        vm.prank(alice);
        aliceIdentity.addClaim(CLAIM_TOPIC_1, 1, address(gasBurningIssuer), hex"00", data, "uri");
        gasBurningIssuer.startBurningGas();

        assertTrue(registry.isVerified{ gas: 1_000_000 }(alice), "the valid issuer's claim counts");
        (UtilityChecker.EligibilityCheckDetails[] memory details,) =
            utilityChecker.getVerifiedDetails{ gas: 1_000_000 }(address(token), alice);
        assertEq(address(details[0].issuer), address(claimIssuer), "the UtilityChecker reports the issuer that passed");
        assertTrue(details[0].pass, "the UtilityChecker agrees");
    }

    /// @notice A claim filed under the trusted issuer's id but naming another issuer counts for neither side: the
    ///  registry skips it, and the UtilityChecker must not ask the issuer the claim names.
    function test_getVerifiedDetails_IgnoresAClaimNamingAnotherIssuer() public {
        Token token = _deployTokenWithClaimTopic("other-issuer", "OTH", "OTH");
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        _trust(registry, address(new SilentClaimIssuer()));
        IdentityWithClaims holder = new IdentityWithClaims(address(new AlwaysValidClaimIssuer()), CLAIM_TOPIC_1);
        vm.prank(agent);
        registry.registerIdentity(david, IIdentity(address(holder)), 0);

        (UtilityChecker.EligibilityCheckDetails[] memory details,) =
            utilityChecker.getVerifiedDetails(address(token), david);

        assertFalse(registry.isVerified(david), "the registry skips a claim naming another issuer");
        assertFalse(details[0].pass, "the UtilityChecker must agree with the registry");
    }

    /// @dev Deploys a token requiring `CLAIM_TOPIC_1`, trusts `issuer` for it, and registers `david` with an identity
    ///  reporting a claim from `issuer`.
    function _trustIssuerAndRegisterHolder(string memory salt, address issuer)
        internal
        returns (TREXRegistry registry)
    {
        Token token = _deployTokenWithClaimTopic(salt, salt, salt);
        registry = TREXRegistry(address(token.identityRegistry()));
        _trust(registry, issuer);
        IdentityWithClaims holder = new IdentityWithClaims(issuer, CLAIM_TOPIC_1);
        vm.prank(agent);
        registry.registerIdentity(david, IIdentity(address(holder)), 0);
    }

    function _trust(TREXRegistry registry, address issuer) internal {
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_1;
        vm.prank(deployer);
        registry.addTrustedIssuer(issuer, topics);
    }

}
