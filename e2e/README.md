# ExTurso E2E Tests

This directory is a downstream Mix project that consumes `ex_turso` the same
way an application would. It is intentionally separate from the package unit
tests so release-artifact and Hex-package verification can run the same suite.

## Local package source

```sh
./e2e/scripts/run-local.sh
```

By default this uses the repository root as a path dependency. Override it with:

```sh
EX_TURSO_PATH=/path/to/ex_turso ./e2e/scripts/run-local.sh
```

## GitHub Release source artifact

```sh
./e2e/scripts/run-release.sh 0.1.1
```

The script downloads `ex_turso-<version>-source.tar.gz` from the matching GitHub
Release unless `EX_TURSO_PATH` already points at an unpacked package source.

## Turso Cloud sync

Cloud sync tests are skipped by default. Run them explicitly with:

```sh
TURSO_E2E_DATABASE_URL=libsql://... \
TURSO_E2E_AUTH_TOKEN=... \
./e2e/scripts/run-cloud-sync.sh
```

The cloud suite writes rows under a unique `run_id` and then deletes them before
the test exits. Use a disposable Turso database for this suite.

## Coverage

The suite covers the features ExTurso currently exposes:

- local file databases and in-memory databases
- query/execute result shapes and parameter binding
- transactions and pooled concurrent access
- structured error classes
- Turso vector SQL functions available in the bundled `turso` crate
- Turso Cloud sync when credentials are provided

Upstream Rust SDK features that ExTurso does not expose yet, such as prepared
statements, encryption builder options, sync stats/checkpoint, and direct remote
`libsql` access, are intentionally not asserted here.
