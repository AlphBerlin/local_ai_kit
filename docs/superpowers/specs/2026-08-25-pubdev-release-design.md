# Coordinated pub.dev Release Design

**Date:** 2026-08-25  
**Status:** Approved for implementation

## Goal

Publish all six LocalAI Kit packages as one coordinated `0.0.1` release under
the `alphberlin.com` pub.dev publisher, and provide a repeatable tagged-release
flow for future versions.

## Scope

The release set is:

1. `local_ai_core`
2. `local_ai_flutter`
3. `local_ai_gemma`
4. `local_ai_sherpa`
5. `local_ai_kit`
6. `local_ai_genkit`

All packages share one semantic version and one repository tag. Publication
still happens in dependency order because pub.dev stores and validates each
package independently.

The root workspace package remains unpublished. The existing uncommitted
`docs/model-registry.md` change is unrelated and must not be included in the
release commit.

## Package metadata

Each release package will:

- use version `0.0.1` for the first release;
- remove `publish_to: none`;
- point `repository` and `issue_tracker` metadata at the GitHub repository;
- use hosted `^0.0.1` constraints for internal package dependencies so the
  published package can resolve outside the workspace;
- include a package-local `README.md` and `CHANGELOG.md`.

The root workspace keeps `publish_to: none` and remains a development-only
container.

## Release script

`tool/publish.dart` is the single source of truth for release package order.
It will:

- accept `--dry-run` and `--publish` modes;
- validate that every package exists and has the same version;
- run package publication from each package directory in dependency order;
- stop on the first failure and return a non-zero exit code;
- avoid modifying package files or creating Git tags.

Version changes and tag creation stay explicit Git operations so a release can
be reviewed before it becomes immutable on pub.dev.

## GitHub Actions flow

`.github/workflows/publish.yml` will run only for tags matching `vX.Y.Z`.
The job will:

- check out the tagged commit;
- grant only the `id-token: write` permission required by pub.dev OIDC;
- install Flutter and dependencies;
- run the repository validation commands;
- invoke `dart run tool/publish.dart --publish`.

The same `v{{version}}` automated-publishing tag pattern must be enabled on
each package’s pub.dev Admin page for the `AlphBerlin/local_ai_kit` repository.
Future releases are then published by pushing one matching tag.

## First-publication constraint

pub.dev automated publishing is only available for an existing package. Each
new package’s first `0.0.1` upload must therefore be performed manually with
`dart pub publish` by an authenticated uploader. After upload, each package
must be transferred to the verified `alphberlin.com` publisher and have
automated publishing enabled. The repository cannot complete that browser
admin/transfer step itself.

## Verification

Before the first upload:

- run the workspace analyzer and tests;
- run the bundle policy check;
- run `dart run tool/publish.dart --dry-run`;
- inspect the package contents reported by pub.

After publication, verify each package URL and version on pub.dev. The release
workflow should be tested with the `v0.0.1` tag only after the manual first
publication and publisher setup are complete.

