# Mutation testing (Gambit)

Two-step flow. Both commands are run from the **repository root**.

## Prerequisites

- [Gambit](https://github.com/Certora/gambit) on your `PATH` (`cargo install --path .` from a clone, or a prebuilt release binary).
- A `solc` 0.8.30 binary reachable as `solc8.30` (the name `gambit_conf.json` references). With `solc-select`:
  ```sh
  solc-select install 0.8.30
  ln -s "$HOME/.solc-select/artifacts/solc-0.8.30/solc-0.8.30" "$HOME/.local/bin/solc8.30"
  ```
- Foundry (`forge`) — the runner shells out to `FOUNDRY_PROFILE=mutation forge test`.

## Run

```sh
# 1. Generate mutants -> gambit_out/  (run from the repo root)
gambit mutate --json mutation/gambit_conf.json

# 2. Apply each mutant and run the test suite, scoring KILLED/SURVIVED
npm run test:mutation        # == bash mutation/run_mutation.sh
```

Results land in `.audit-cache/mutation-results/` (CSV + log + survivor list).

## Path-resolution note

Gambit resolves the paths inside `gambit_conf.json` **relative to the config file's own
directory** (`mutation/`), independent of your current directory — so the config uses
`..`-relative paths (`../contracts/...`, `../dependencies/...`) to reach the repo root.
`gambit_out/` is written to your current directory, so always invoke `gambit mutate` from
the repo root; `run_mutation.sh` then finds it there.
