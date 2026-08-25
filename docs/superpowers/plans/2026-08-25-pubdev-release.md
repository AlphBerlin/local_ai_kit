# Coordinated pub.dev Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all six LocalAI Kit packages publishable as version `0.0.1`, provide one dependency-ordered publisher script and one tag-triggered GitHub Actions flow, and complete the first pub.dev publication when authentication and publisher setup permit it.

**Architecture:** Keep the root as an unpublished Dart workspace. Store the release package order in one typed Dart script, validate shared versions before any upload, and invoke `dart pub publish` for the pure-Dart package or `flutter pub publish` for Flutter packages. Use one `vX.Y.Z` Git tag to trigger a custom OIDC-enabled workflow that runs the same script sequentially.

**Tech Stack:** Dart 3.6+, Flutter 3.27+, Pub workspaces, Melos 6.3, GitHub Actions, pub.dev OIDC automated publishing.

**Spec:** `docs/superpowers/specs/2026-08-25-pubdev-release-design.md`

## Global Constraints

- Publish exactly these packages in this order: `local_ai_core`, `local_ai_flutter`, `local_ai_gemma`, `local_ai_sherpa`, `local_ai_kit`, `local_ai_genkit`.
- Every release package uses version `0.0.1` for the first release and the same version on every future coordinated tag.
- The root workspace remains `publish_to: none`.
- Internal hosted dependencies use `^0.0.1` for the first release.
- The existing user edits outside release files remain unstaged and unchanged.
- The first upload must be manual because pub.dev automated publishing only supports existing packages; later uploads use GitHub OIDC on a matching tag.

### Task 1: Make package metadata publishable

**Files:**
- Modify: `packages/local_ai_core/pubspec.yaml`
- Modify: `packages/local_ai_flutter/pubspec.yaml`
- Modify: `packages/local_ai_gemma/pubspec.yaml`
- Modify: `packages/local_ai_sherpa/pubspec.yaml`
- Modify: `packages/local_ai_kit/pubspec.yaml`
- Modify: `packages/local_ai_genkit/pubspec.yaml`
- Create: `packages/local_ai_core/README.md`
- Create: `packages/local_ai_flutter/README.md`
- Create: `packages/local_ai_gemma/README.md`
- Create: `packages/local_ai_sherpa/README.md`
- Create: `packages/local_ai_kit/README.md`
- Create: `packages/local_ai_genkit/README.md`
- Create: `packages/local_ai_core/LICENSE`
- Create: `packages/local_ai_flutter/LICENSE`
- Create: `packages/local_ai_gemma/LICENSE`
- Create: `packages/local_ai_sherpa/LICENSE`
- Create: `packages/local_ai_kit/LICENSE`
- Create: `packages/local_ai_genkit/LICENSE`
- Create: `packages/local_ai_core/CHANGELOG.md`
- Create: `packages/local_ai_flutter/CHANGELOG.md`
- Create: `packages/local_ai_gemma/CHANGELOG.md`
- Create: `packages/local_ai_sherpa/CHANGELOG.md`
- Create: `packages/local_ai_kit/CHANGELOG.md`
- Create: `packages/local_ai_genkit/CHANGELOG.md`

**Interfaces:**
- Consumes: The existing public library files and workspace dependency graph.
- Produces: Six independently valid hosted packages with version `0.0.1`, repository metadata, package pages, and resolvable hosted internal dependencies.

- [ ] **Step 1: Write the package metadata validation check first.**

Run this command before changing metadata and record the current failure set:

```bash
(cd packages/local_ai_core && dart pub publish --dry-run)
for package in packages/local_ai_flutter packages/local_ai_gemma packages/local_ai_sherpa packages/local_ai_kit packages/local_ai_genkit; do
  (cd "$package" && flutter pub publish --dry-run)
done
```

Expected: the command reports unpublished-package metadata warnings/errors, including `publish_to: none`, missing package-local documentation, and workspace-only dependency constraints where applicable.

- [ ] **Step 2: Update all six pubspecs.**

For each package, set:

```yaml
version: 0.0.1
repository: https://github.com/AlphBerlin/local_ai_kit
issue_tracker: https://github.com/AlphBerlin/local_ai_kit/issues
```

Remove `publish_to: none` from the six package pubspecs. Keep `resolution: workspace` so the monorepo continues to resolve locally. Change internal package dependencies to hosted constraints:

```yaml
# local_ai_flutter, local_ai_gemma, local_ai_sherpa
local_ai_core: ^0.0.1

# local_ai_kit
local_ai_core: ^0.0.1
local_ai_flutter: ^0.0.1

# local_ai_genkit
local_ai_core: ^0.0.1
local_ai_kit: ^0.0.1
```

Do not change third-party dependency versions or the root `pubspec.yaml`.

- [ ] **Step 3: Add package-local page content.**

Each package must include the repository’s Apache-2.0 `LICENSE` text at its package root because package archives do not include files from the workspace root. Each README must identify the package’s role, include its primary import, link to the repository and relevant root documentation, and state whether it is pure Dart, Flutter platform, adapter, facade, or optional orchestration. Each changelog must contain:

```markdown
# Changelog

## 0.0.1

- Initial public release.
```

The `local_ai_kit` README should include the basic initialization example from the root README; adapter READMEs should show their plugin registration; `local_ai_core` should state that it has no Flutter/native runtime dependency. Add `local_ai_sherpa: ^0.0.1` to `local_ai_kit`’s `dev_dependencies` because its existing Flutter test imports that adapter package; do not add it to runtime dependencies.

- [ ] **Step 4: Re-run the metadata validation.**

Run the dry-run command from Step 1. Expected: each package reaches pub validation without a fatal error. Record any warning that requires a metadata correction before moving on.

- [ ] **Step 5: Commit the metadata-only change.**

```bash
git add packages/*/pubspec.yaml packages/*/README.md packages/*/CHANGELOG.md
git commit -m "chore: prepare packages for pub.dev"
```

### Task 2: Add a tested dependency-ordered publisher script

**Files:**
- Create: `tool/release_config.dart`
- Create: `tool/publish.dart`
- Create: `tool/release_config_test.dart`
- Modify: `pubspec.yaml`

**Interfaces:**
- Consumes: Package directories and pubspec metadata from Task 1.
- Produces: `releasePackages`, `validateReleaseVersion`, and a CLI with `--dry-run` or `--publish`.

- [ ] **Step 1: Add the failing release configuration tests.**

Add `test: ^1.25.0` to the root `dev_dependencies`, then create tests with these exact behaviors:

```dart
import 'package:test/test.dart';
import 'release_config.dart';

void main() {
  test('release packages stay in dependency order', () {
    expect(
      releasePackages.map((package) => package.name).toList(),
      <String>[
        'local_ai_core',
        'local_ai_flutter',
        'local_ai_gemma',
        'local_ai_sherpa',
        'local_ai_kit',
        'local_ai_genkit',
      ],
    );
  });

  test('release version validation rejects a mismatch', () {
    expect(
      () => validateReleaseVersion(<String, String>{
        'local_ai_core': '0.0.1',
        'local_ai_kit': '0.0.2',
      }),
      throwsA(isA<ReleaseValidationException>()),
    );
  });

  test('release version validation accepts one shared version', () {
    expect(
      validateReleaseVersion(<String, String>{
        'local_ai_core': '0.0.1',
        'local_ai_kit': '0.0.1',
      }),
      '0.0.1',
    );
  });
}
```

- [ ] **Step 2: Run the focused test to verify it fails for the missing implementation.**

Run:

```bash
dart test tool/release_config_test.dart
```

Expected: FAIL because `release_config.dart`, `releasePackages`, `validateReleaseVersion`, and `ReleaseValidationException` do not exist yet.

- [ ] **Step 3: Implement the minimal release configuration.**

Define a `ReleasePackage` value with `name`, `directory`, and `usesFlutter`; define `releasePackages` in the six-package order above; define `ReleaseValidationException`; and make `validateReleaseVersion` return the shared version or throw when the map is empty or contains more than one version.

- [ ] **Step 4: Run the focused test to verify it passes.**

```bash
dart test tool/release_config_test.dart
```

Expected: all three tests PASS.

- [ ] **Step 5: Implement the CLI around the tested configuration.**

`tool/publish.dart` must:

1. accept exactly one of `--dry-run` and `--publish`, plus `--help`;
2. read each package’s `version:` line and validate one shared version;
3. reject a version different from the Git tag when `GITHUB_REF_NAME` is set to `vX.Y.Z`;
4. run `dart pub publish --dry-run` or `flutter pub publish --dry-run` for each package, using `--force` only in publish mode;
5. use `Process.run` with `workingDirectory` set to each package directory;
6. forward each command’s stdout/stderr;
7. stop immediately on a non-zero exit code and return that code;
8. print the package name before every command so CI logs identify the upload.

Do not add a second package order or a version-mutating command to the script.

- [ ] **Step 6: Verify CLI failure and success paths.**

Run:

```bash
dart run tool/publish.dart --help
dart run tool/publish.dart --dry-run
dart analyze tool/release_config.dart tool/publish.dart tool/release_config_test.dart
```

Expected: help exits zero, the dry run invokes all six packages in order, and focused analysis exits zero.

- [ ] **Step 7: Commit the publisher script.**

```bash
git add pubspec.yaml tool/release_config.dart tool/publish.dart tool/release_config_test.dart
git commit -m "ci: add coordinated pub.dev publisher"
```

### Task 3: Add the tag-triggered GitHub Actions release flow

**Files:**
- Create: `.github/workflows/publish.yml`
- Modify: `docs/releasing.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `tool/publish.dart` and the package versions from Tasks 1–2.
- Produces: A tag-only OIDC release workflow and operator instructions for first and subsequent releases.

- [ ] **Step 1: Add the release documentation before the workflow.**

Create `docs/releasing.md` with these commands and requirements:

```bash
dart run tool/publish.dart --dry-run
git tag v0.0.2
git push origin v0.0.2
```

Document that the first upload for each package must be performed by an authenticated uploader with `flutter pub publish` (or `dart pub publish` for `local_ai_core`), then transferred to `alphberlin.com`. Document that each package’s pub.dev Admin page must enable automated publishing for repository `AlphBerlin/local_ai_kit` with tag pattern `v{{version}}`. Document that later releases update all six versions, commit them, and push one matching tag.

- [ ] **Step 2: Add a tag-only workflow.**

The workflow must contain the following behavior:

```yaml
on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'

permissions:
  contents: read

jobs:
  publish:
    permissions:
      contents: read
      id-token: write
```

Use `actions/checkout@v4`, `subosito/flutter-action@v2` on the stable channel, `dart-lang/setup-dart@v1`, and `dart pub global activate melos 6.3.0`. Run `dart pub get`, `melos run analyze`, `melos run test`, `melos run verify:bundle-policy`, and finally `dart run tool/publish.dart --publish`. Do not add a branch, pull-request, manual, or schedule trigger to the publishing job.

- [ ] **Step 3: Link the release guide from the root README.**

Add `docs/releasing.md` to the root README documentation list and mention that release tags publish all six packages together in dependency order.

- [ ] **Step 4: Validate workflow syntax and documentation references.**

Run:

```bash
rg -n "publish|v\[0-9\]|alphberlin|AlphBerlin/local_ai_kit" .github/workflows/publish.yml docs/releasing.md README.md
```

Expected: the workflow has only the tag trigger, uses OIDC permissions, and every documented repository/publisher/tag value matches the approved design.

- [ ] **Step 5: Commit the workflow and documentation.**

```bash
git add .github/workflows/publish.yml docs/releasing.md README.md
git commit -m "ci: publish packages from version tags"
```

### Task 4: Prepare and verify the `0.0.1` release

**Files:**
- Modify: all six `packages/*/pubspec.yaml` files only if their version is not already `0.0.1`.

**Interfaces:**
- Consumes: The validated package set and publisher script from Tasks 1–3.
- Produces: A clean release commit/tag candidate with six dry-run-valid package archives.

- [ ] **Step 1: Confirm the release tree excludes unrelated user edits.**

Run:

```bash
git status --short
git diff -- packages docs/superpowers tool .github pubspec.yaml README.md
```

Review that only release files are staged or committed; do not stage existing edits to `AGENTS.md`, root/docs files, or any unrelated package source.

- [ ] **Step 2: Run the complete local verification suite.**

```bash
melos bootstrap
melos run analyze
melos run test
melos run verify:bundle-policy
dart run tool/publish.dart --dry-run
```

Expected: every command exits zero and the publisher script reports six package dry runs in the required order.

- [ ] **Step 3: Perform the first manual uploads.**

After confirming `dart pub token list` shows an authenticated pub.dev session, upload each package in order:

```bash
(cd packages/local_ai_core && dart pub publish)
(cd packages/local_ai_flutter && flutter pub publish)
(cd packages/local_ai_gemma && flutter pub publish)
(cd packages/local_ai_sherpa && flutter pub publish)
(cd packages/local_ai_kit && flutter pub publish)
(cd packages/local_ai_genkit && flutter pub publish)
```

Confirm each package appears at `https://pub.dev/packages/<package-name>` before uploading the next package that depends on it. If authentication is missing, stop and report the exact command needed; never bypass authentication or use a stored secret.

- [ ] **Step 4: Complete publisher and automated-publishing setup.**

For each of the six package Admin pages, transfer the package to `alphberlin.com` and enable automated publishing for `AlphBerlin/local_ai_kit` with `v{{version}}`. Configure the GitHub `pub.dev` environment if the publisher admin page requires one.

- [ ] **Step 5: Create and push the first coordinated tag.**

After all six `0.0.1` packages exist and publisher automation is configured, use
the next version for the first automated tag so the workflow does not attempt
to upload an already-published version:

```bash
git tag v0.0.2
git push origin v0.0.2
```

Before pushing `v0.0.2`, update all six pubspec versions and changelogs to
`0.0.2`, commit them, and run the dry-run again. The tag workflow then runs the
same validation and publisher script and publishes the first automated release.

- [ ] **Step 6: Verify pub.dev results and release state.**

Check all six package pages report version `0.0.1`, the publisher is `alphberlin.com`, and the GitHub Actions run for the tag succeeded. Record the package URLs and workflow run URL in the final handoff.

### Self-review checklist

- [ ] The plan covers the metadata, package page content, publisher script, tests, workflow, docs, first manual upload, publisher transfer, tag, and post-publish verification in the approved spec.
- [ ] No task relies on an undefined file, function, command, or package order.
- [ ] The first publication constraint is explicit and does not claim the repository can complete pub.dev browser transfer/setup.
- [ ] Existing unrelated worktree edits are preserved and excluded from release commits.
