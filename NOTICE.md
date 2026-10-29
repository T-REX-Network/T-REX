# NOTICE

## T-REX Smart Contracts

Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")

T-REX is the open-source token suite of the T-REX ecosystem for compliant
tokenized assets. It implements the ERC-3643 standard: a permissioned token
whose holders are verified through ONCHAINID identities and whose transfers
are checked by a modular compliance contract, with a factory, a version
registry and cross-chain messaging around it.

Website: https://www.t-rex.network
Contact: legal@t-rex.network

## License

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License in
[LICENSE.md](./LICENSE.md) for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.

## Provenance and modifications

This repository originated as a fork of the T-REX reference implementation of
ERC-3643 published by Tokeny sàrl (https://github.com/TokenySolutions/T-REX),
released under the GNU General Public License v3.0. The `main` branch of this
repository holds the T-REX v4 line inherited from upstream.

The codebase has since been substantially rewritten and re-architected by and
for Digital Asset Operational Services ISAC Ltd. The current implementation
splits the ERC-3643 standard surface into base contracts over ERC-7201
namespaces, merges the eligibility registries into one T-REX registry, moves
access control to the OpenZeppelin AccessManager, replaces the proxy layer
with beacons and a version registry, adds a typed compliance ledger with
transfer validation, and adds ERC-7786 cross-chain messaging. It differs
materially from the original implementation in architecture, storage layout,
access model, compliance model and deployment model. These modifications were
made in 2025 and 2026. This statement constitutes the notice of modification
required by Section 5(a) of the GNU General Public License v3.

Copyright in any code originating from the upstream repository remains with
Tokeny sàrl and continues to be licensed under the GPL-3.0. Files that still
derive from the upstream code carry the line "Copyright (C) 2023, Tokeny sàrl."
in their header, next to the T-REX Network copyright line. Copyright in all
new and modified code in this repository is held by Digital Asset Operational
Services ISAC Ltd.

## Trademarks

"T-REX Network" is the trade name of Digital Asset Operational Services
ISAC Ltd. The GNU General Public License grants rights in the software only.
It does not grant permission to use any trade names, trademarks, service
marks, or logos appearing in this repository or associated with the T-REX
ecosystem, including "T-REX", "T-REX Network" and "ONCHAINID", except for
reasonable and customary use in describing the origin of the work. All
trademarks are the property of their respective owners. Use of the software
under the GPL-3.0 does not imply any endorsement by, or affiliation with,
Digital Asset Operational Services ISAC Ltd. or any other rights holder.

## Third-party components

This software depends on third-party components, including OpenZeppelin
Contracts and OpenZeppelin Contracts Upgradeable (MIT License), and on the
ONCHAINID contracts (GPL-3.0), also published by Digital Asset Operational
Services ISAC Ltd. The six `IERC3643*.sol` interface files directly under
`contracts/ERC-3643` are published under CC0-1.0, and
`contracts/vendor/IERC173.sol` under the MIT License. Third-party components
remain subject to their own license terms, which are unaffected by this
NOTICE.
