// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { Version, VersionLib } from "contracts/libraries/VersionLib.sol";

/// @title VersionLib coverage
/// @notice Pins the bit layout of the packed `Version` word before the authority's archive depends on it:
///         the three components must round-trip independently, equal triples must compare equal under `==`,
///         and distinct triples must never collide as mapping keys.
contract VersionLibUnitTest is Test {

    mapping(Version version => uint256 marker) private _markers;

    function test_pack_RoundTripsAKnownTriple() public pure {
        Version version = VersionLib.pack(5, 0, 1);

        assertEq(version.major(), 5);
        assertEq(version.minor(), 0);
        assertEq(version.patch(), 1);
    }

    function test_pack_RoundTripsTheLowestTriple() public pure {
        Version version = VersionLib.pack(0, 0, 0);

        assertEq(version.major(), 0);
        assertEq(version.minor(), 0);
        assertEq(version.patch(), 0);
        assertEq(Version.unwrap(version), 0);
    }

    function test_pack_RoundTripsTheHighestTriple() public pure {
        Version version = VersionLib.pack(255, 255, 255);

        assertEq(version.major(), 255);
        assertEq(version.minor(), 255);
        assertEq(version.patch(), 255);
        assertEq(Version.unwrap(version), type(uint24).max);
    }

    function testFuzz_pack_RoundTripsEveryComponent(uint8 major, uint8 minor, uint8 patch) public pure {
        Version version = VersionLib.pack(major, minor, patch);

        assertEq(version.major(), major, "major must not depend on minor or patch");
        assertEq(version.minor(), minor, "minor must not depend on major or patch");
        assertEq(version.patch(), patch, "patch must not depend on major or minor");
    }

    function test_eq_HoldsForTheSameTriple() public pure {
        assertTrue(VersionLib.pack(5, 0, 0) == VersionLib.pack(5, 0, 0));
    }

    function test_eq_FailsOnEveryDifferingComponent() public pure {
        Version version = VersionLib.pack(5, 0, 0);

        assertFalse(version == VersionLib.pack(4, 0, 0));
        assertFalse(version == VersionLib.pack(5, 1, 0));
        assertFalse(version == VersionLib.pack(5, 0, 1));
    }

    function test_gt_RanksMajorBeforeMinorBeforePatch() public pure {
        assertTrue(VersionLib.pack(5, 0, 1) > VersionLib.pack(5, 0, 0), "patch must break a major/minor tie");
        assertTrue(VersionLib.pack(5, 1, 0) > VersionLib.pack(5, 0, 255), "minor must outrank any patch");
        assertTrue(VersionLib.pack(6, 0, 0) > VersionLib.pack(5, 255, 255), "major must outrank any minor");
    }

    function test_gt_FailsOnEqualAndLowerTriples() public pure {
        Version version = VersionLib.pack(5, 0, 0);

        assertFalse(version > version, "a version must not outrank itself");
        assertFalse(VersionLib.pack(4, 255, 255) > version);
        assertFalse(VersionLib.pack(5, 0, 0) > VersionLib.pack(5, 0, 1));
    }

    function testFuzz_gt_MatchesTheComponentOrdering(uint8 majorA, uint8 minorA, uint8 majorB, uint8 minorB)
        public
        pure
    {
        Version a = VersionLib.pack(majorA, minorA, 0);
        Version b = VersionLib.pack(majorB, minorB, 0);

        bool expected = majorA > majorB || (majorA == majorB && minorA > minorB);

        assertEq(a > b, expected, "the packed order must match the component order");
    }

    function test_version_KeysAMappingWithoutColliding() public {
        _markers[VersionLib.pack(5, 0, 0)] = 1;
        _markers[VersionLib.pack(5, 0, 1)] = 2;

        assertEq(_markers[VersionLib.pack(5, 0, 0)], 1);
        assertEq(_markers[VersionLib.pack(5, 0, 1)], 2);
        assertEq(_markers[VersionLib.pack(0, 5, 0)], 0, "an unwritten triple must stay empty");
    }

}
