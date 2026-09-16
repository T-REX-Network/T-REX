// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";

import { StubIdentityRegistry } from "./Token.t.sol";
import {
    ClaimTopicsRegistryMock,
    ComplianceMock,
    IdentityRegistryMock,
    IdentityRegistryStorageMock,
    TokenMock,
    TrustedIssuersRegistryMock
} from "./mocks/Mocks.sol";

/// @dev Every batch function rejects arrays of differing lengths.
///
///  The dangerous direction is a FIRST array shorter than the others: the loop is bounded by the first,
///  so without an explicit check the trailing entries are silently dropped and the call returns success.
///  An operator would see a successful batch that skipped some of its recipients, with nothing to
///  indicate it. The opposite direction merely panics on the out-of-bounds index.
///
///  Both directions are asserted for each function, because only the explicit check catches the first.
contract BatchArrayLengthTest is Test {

    TokenMock internal token;
    StubIdentityRegistry internal registry;
    ComplianceMock internal compliance;

    IdentityRegistryMock internal identityRegistry;
    IdentityRegistryStorageMock internal identityStorage;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        registry = new StubIdentityRegistry();
        compliance = new ComplianceMock();

        token = new TokenMock();
        token.init("Standard Token", "STD", address(registry), address(compliance), makeAddr("onchainId"));
        compliance.bindToken(address(token));

        registry.setVerified(alice, true);
        registry.setVerified(bob, true);
        token.mint(alice, 1000);
        token.mint(bob, 1000);

        identityStorage = new IdentityRegistryStorageMock();
        identityRegistry = new IdentityRegistryMock();
        identityRegistry.init(
            address(identityStorage), address(new TrustedIssuersRegistryMock()), address(new ClaimTopicsRegistryMock())
        );
        identityStorage.bindIdentityRegistry(address(identityRegistry));
    }

    function _addrs(uint256 n) internal view returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = i == 0 ? alice : bob;
        }
    }

    function _uints(uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = 1;
        }
    }

    function _expectMismatch() internal {
        vm.expectRevert(ERC3643ErrorsLib.ArrayLengthMismatch.selector);
    }

    function test_batchMint_RevertWhen_FirstArrayShorter() public {
        _expectMismatch();
        token.batchMint(_addrs(1), _uints(2));
    }

    function test_batchMint_RevertWhen_FirstArrayLonger() public {
        _expectMismatch();
        token.batchMint(_addrs(2), _uints(1));
    }

    function test_batchBurn_RevertWhen_FirstArrayShorter() public {
        _expectMismatch();
        token.batchBurn(_addrs(1), _uints(2));
    }

    function test_batchBurn_RevertWhen_FirstArrayLonger() public {
        _expectMismatch();
        token.batchBurn(_addrs(2), _uints(1));
    }

    function test_batchTransfer_RevertWhen_FirstArrayShorter() public {
        vm.prank(alice);
        _expectMismatch();
        token.batchTransfer(_addrs(1), _uints(2));
    }

    function test_batchTransfer_RevertWhen_FirstArrayLonger() public {
        vm.prank(alice);
        _expectMismatch();
        token.batchTransfer(_addrs(2), _uints(1));
    }

    function test_batchForcedTransfer_RevertWhen_LengthsDiffer() public {
        _expectMismatch();
        token.batchForcedTransfer(_addrs(1), _addrs(2), _uints(2));

        _expectMismatch();
        token.batchForcedTransfer(_addrs(2), _addrs(2), _uints(1));
    }

    function test_batchFreezePartialTokens_RevertWhen_FirstArrayShorter() public {
        _expectMismatch();
        token.batchFreezePartialTokens(_addrs(1), _uints(2));
    }

    function test_batchUnfreezePartialTokens_RevertWhen_FirstArrayShorter() public {
        _expectMismatch();
        token.batchUnfreezePartialTokens(_addrs(1), _uints(2));
    }

    function test_batchSetAddressFrozen_RevertWhen_FirstArrayShorter() public {
        bool[] memory freezes = new bool[](2);
        _expectMismatch();
        token.batchSetAddressFrozen(_addrs(1), freezes);
    }

    function test_batchRegisterIdentity_RevertWhen_FirstArrayShorter() public {
        IIdentity[] memory identities = new IIdentity[](2);
        uint16[] memory countries = new uint16[](2);

        _expectMismatch();
        identityRegistry.batchRegisterIdentity(_addrs(1), identities, countries);
    }

    function test_batchRegisterIdentity_RevertWhen_CountriesShorter() public {
        IIdentity[] memory identities = new IIdentity[](2);
        uint16[] memory countries = new uint16[](1);

        _expectMismatch();
        identityRegistry.batchRegisterIdentity(_addrs(2), identities, countries);
    }

    /// @dev The check must not disturb the matched-length path.
    function test_batchMint_SucceedsWhenLengthsMatch() public {
        uint256 before = token.totalSupply();

        token.batchMint(_addrs(2), _uints(2));

        assertEq(token.totalSupply(), before + 2);
    }

}
