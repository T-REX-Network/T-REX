# T-REX : Token for Regulated EXchanges

![GitHub](https://img.shields.io/github/license/T-REX-Network/T-REX?color=green)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/T-REX-Network/T-REX)
![GitHub Workflow Status (branch)](https://img.shields.io/github/actions/workflow/status/T-REX-Network/T-REX/test.yml?branch=develop)
![GitHub repo size](https://img.shields.io/github/repo-size/T-REX-Network/T-REX)
![GitHub Release Date](https://img.shields.io/github/release-date/T-REX-Network/T-REX)

---

<br><br>

<p align="center">
  <a href="./docs/TREX-WhitePaper.pdf">
  <img src="./docs/img/T-REX.png" width="150" title="t-rex">
  </a>
</p>

## Overview

The T-REX (Token for Regulated EXchanges) protocol is a comprehensive suite of Solidity smart contracts,
implementing the [ERC-3643 standard](https://eips.ethereum.org/EIPS/eip-3643) and designed to enable the issuance, management, and transfer of security
tokens in
compliance with regulations. It ensures secure and compliant transactions for all parties involved in the token exchange.

## Key Components

The T-REX protocol consists of several key components:

- **[ONCHAINID](https://github.com/onchain-id/solidity)**: A smart contract deployed by a user to interact with the security token or any other application
  where an on-chain identity may be relevant. It stores keys and claims related to a specific identity.

- **Trusted Issuers Registry**: This contract houses the addresses of all trusted claim issuers associated with a specific token.

- **Claim Topics Registry**: This contract maintains a list of all trusted claim topics related to the security token.

- **Identity Registry**: This contract holds the identity contract addresses of all eligible users authorized to hold the token. It is responsible for claim verification.

- **Compliance Smart Contract**: This contract independently operates to check whether a transfer is in compliance with the established rules for the token.

- **Security Token Contract**: This contract interacts with the Identity Registry to check the eligibility status of investors, enabling token holding and transactions.

## Getting Started

1. Clone the repository: `git clone https://github.com/T-REX-Network/T-REX.git`
2. Install [Foundry](https://getfoundry.sh/) if you haven't already
3. Install dependencies: `forge soldeer install`
4. Compile the contracts: `forge build`
5. Run tests: `forge test`

## Development

This project uses **Foundry** for development and testing.

### Prerequisites

- **Foundry** - Install from [getfoundry.sh](https://getfoundry.sh/)

### Installation

```bash
# Install Foundry dependencies via Soldeer
forge soldeer install
```

### Build Commands

```bash
forge build              # Compile contracts
```

### Testing

```bash
forge test               # Run tests
forge test --gas-report  # Run tests with gas report
```

#### Fork tests

The fork tests run the full deterministic deployment (`scripts/deploy/`, see [deploy/README.md](deploy/README.md))
on a fork of **Base Sepolia** (or Ethereum mainnet with `TREX_FORK_ENV=mainnet`): Genesis, protocol, configuration and handover to the Safes, then what can happen
after launch (upgrades and rollbacks, incident response, governance changes, months of activity, a new chain
joining at the same addresses). Every contract, ONCHAINID v3 included, is deployed fresh from the build, so nothing
already deployed on the chain is reused. Build the ONCHAINID profile first (`deploy/README.md`, step 0).

They are opt-in and not part of CI. Plain `forge test` skips them. To run them:

```bash
# ALCHEMY_KEY (from .env) selects the foundry.toml `baseSepolia` endpoint
TREX_FORK_TESTS=true forge test --match-path "test/fork/*" --threads 1

# or any Base Sepolia RPC that serves historical state
TREX_FORK_TESTS=true TREX_FORK_RPC_URL=https://base-sepolia.g.alchemy.com/v2/<key> \
  forge test --match-path "test/fork/*" --threads 1

# the same suite on an Ethereum mainnet fork (needs a mainnet RPC that serves historical state)
TREX_FORK_TESTS=true TREX_FORK_ENV=mainnet TREX_FORK_RPC_URL=<mainnet RPC> \
  forge test --match-path "test/fork/*" --threads 1

# one file, with logs
TREX_FORK_TESTS=true forge test --match-path test/fork/ForkLongRun.t.sol -vv
```

| Variable | Meaning |
|---|---|
| `TREX_FORK_TESTS` | `true` enables the fork tests |
| `ALCHEMY_KEY` | used for the `baseSepolia` RPC endpoint when `TREX_FORK_RPC_URL` is not set |
| `TREX_FORK_ENV` | `baseSepolia` (default) or `mainnet`: the chain and its `deploy/config/<env>.json` |
| `TREX_FORK_RPC_URL` | any RPC for that chain; overrides `ALCHEMY_KEY` |
| `TREX_FORK_BLOCK` | fork block (default: the block pinned in `test/fork/ForkBase.sol`) |

`--threads 1` runs one suite at a time: RPC free tiers, Alchemy's included, answer parallel suites with
HTTP 429. The deployment-tooling unit tests (`test/unit/deploy/`) need no RPC and run with plain `forge test` once
the ONCHAINID profile is built; without it they skip and say which command to run (CI builds it and refuses the
skip).

### Coverage

```bash
npm run coverage         # terminal summary
npm run coverage:report  # LCOV + HTML report, then opens it
```

`npm run coverage` prints a terminal summary with coverage percentages. Tests, dependencies,
scripts and vendored code are excluded from the report.

`npm run coverage:report` additionally writes an LCOV report to `coverage/lcov.info` for CI/CD
integration and an HTML report to `coverage/report/index.html` for interactive viewing.

**Note:** The HTML report needs `lcov` installed:

```bash
brew install lcov  # macOS
```

### Flatten Contracts

```bash
forge flatten <contract-path>  # Flatten a contract
```

### Project Structure

```
├── contracts/             # Solidity contracts
├── test/                 # Foundry tests (Solidity)
├── foundry.toml          # Foundry configuration
├── soldeer.lock          # Dependency lock file
└── docs/                 # Documentation files
```

## Documentation

For a detailed understanding of the T-REX protocol, please refer to the [whitepaper](./docs/TREX-WhitePaper.pdf).
All functions of T-REX smart contracts are described in the [T-REX documentation](https://docs.t-rex.network)

## Contributing

We welcome contributions from the community. Please refer to the [CONTRIBUTING](./CONTRIBUTING.md) guide for more details.

## Security and audits

T-REX v5 has been audited by OpenZeppelin. The audit report will be linked here once published.

Please report security vulnerabilities responsibly to security@t-rex.network rather than opening a public issue.

## License

Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network").

This project is licensed under the GNU General Public License v3.0. See [LICENSE.md](./LICENSE.md) for the full license text and [NOTICE.md](./NOTICE.md) for copyright, provenance, and trademark information.

