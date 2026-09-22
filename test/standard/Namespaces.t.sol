// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { Utils } from "../unit/helpers/Utils.sol";

/// @dev Pins the expected ERC-7201 slot of every domain this repo uses. It hashes a string written
///  here against a constant written here, so it fixes the intended values for review and for the swap
///  checklist in `docs/erc3643-oz-swap.md`; it does not read the contracts. Real storage layout is
///  checked by the storage-layout tests named there.
contract DomainsTest is Test {

    function test_tokenDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.ERC3643Token"),
            0x1c6ea0581535d63a38daa138246885c0e308b5f6335af4548c056841c5c18f00
        );
    }

    function test_identityRegistryDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.IdentityRegistry"),
            0x7677ac510b853691f250873636359d7d7673c26ecc94050f9c8f5810c4b61e00
        );
    }

    function test_identityRegistryStorageDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.IdentityRegistryStorage"),
            0x8e8aa323647c3f2580137bf922482bdf62534082dec9617ddb5e7739bad03900
        );
    }

    function test_trustedIssuersRegistryDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.TrustedIssuersRegistry"),
            0x58a7ad278b8ace1eb0e9c3892258e09577cfdd8d75b47f8418fdf561b2770b00
        );
    }

    function test_claimTopicsRegistryDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.ClaimTopicsRegistry"),
            0xf733c3a0e1c477ac68147f80e659cc05e7e57f7c461b47d14f8d9811f4c72700
        );
    }

    function test_complianceDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.Compliance"),
            0x9a630f7fb5b68c9ca32ffeadfd0de30d50c23b603074e205ad3eb7046278f900
        );
    }

    /// @dev The T-REX domains. Each had to change when its struct did, because the standard bases
    ///  took over fields that used to sit at the head of these structs. Reusing a domain over a
    ///  changed struct silently relocates every field after the one removed.
    function test_trexTokenDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.TREXToken"),
            0x05378669fd58b6f9251e6d5461e60e18b8b3fdf11d70481ba6f9fc72a4bfc600
        );
    }

    function test_trexRegistryDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.TREXEligibility"),
            0xe60ad881f2e5dd9ad5e5fabfb6687133de1b3b6f4c77607e9031b076e00b7500
        );
    }

    function test_trexComplianceDomain() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.TREXCompliance"),
            0xbd2da5c5fcdced9ef28c358fe4e316978613e6ee5dda1f35de5eca5813787500
        );
    }

    /// @dev The namespaces the cross-chain layer adds on top of the suite. Both follow the same
    ///  lowercase `erc3643.storage.` rule as everything above.
    function test_transferValidationNamespace() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.TransferValidation"),
            0x518dcda4927033bd42da8dd6047b92b4a950cebbc5bdd8461a5e9bb9c0545400
        );
    }

    function test_trexMessagingNamespace() public pure {
        assertEq(
            Utils.erc7201("erc3643.storage.TREXMessaging"),
            0x2b7785d97e35cf618b41c256efdda42212baf2d424180e7d549907f2f911e900
        );
    }

    /// @dev The ERC-20 slot the token base reaches into for name and symbol. Declared by
    ///  `ERC20Upgradeable`, which keeps its own accessor private.
    function test_erc20DomainReachedByTokenBase() public pure {
        assertEq(
            Utils.erc7201("openzeppelin.storage.ERC20"),
            0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00
        );
    }

}
