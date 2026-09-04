# Releasing to pub.dev

LocalAI Kit publishes eight packages as one coordinated release, all sharing
one version number. Uploads run in dependency order:

1. [`local_ai_core`](https://pub.dev/packages/local_ai_core)
2. [`local_ai_flutter`](https://pub.dev/packages/local_ai_flutter)
3. [`local_ai_gemma`](https://pub.dev/packages/local_ai_gemma)
4. [`local_ai_llama_cpp`](https://pub.dev/packages/local_ai_llama_cpp)
5. [`local_ai_sherpa`](https://pub.dev/packages/local_ai_sherpa)
6. [`local_ai_kit`](https://pub.dev/packages/local_ai_kit)
7. [`local_ai_genkit`](https://pub.dev/packages/local_ai_genkit)
8. [`bedge_ai`](https://pub.dev/packages/bedge_ai)

Current release: **0.0.3** (`bedge_ai` is the renamed `local_ai_kit_all`,
published for the first time under this name at 0.0.2; `local_ai_kit_all`
0.0.1 remains on pub.dev but will not receive further releases).

## First release: `0.0.1`

pub.dev requires the first version of a new package to be uploaded manually.
Authenticate first, then run the publisher dry-run:

```sh
dart pub token list
dart run tool/publish.dart --dry-run
```

Upload the packages in order:

```sh
(cd packages/local_ai_core && dart pub publish)
(cd packages/local_ai_flutter && flutter pub publish)
(cd packages/local_ai_gemma && flutter pub publish)
(cd packages/local_ai_llama_cpp && flutter pub publish)
(cd packages/local_ai_sherpa && flutter pub publish)
(cd packages/local_ai_kit && flutter pub publish)
(cd packages/local_ai_genkit && flutter pub publish)
(cd packages/bedge_ai && flutter pub publish)
```

After each upload, confirm the package is available at
`https://pub.dev/packages/<package-name>`. Transfer every package to the
verified `alphberlin.com` publisher from its pub.dev Admin page.

## Enabling automated publishing (outstanding)

The repo ships a tag-triggered GitHub Actions workflow
(`.github/workflows/publish.yml`) meant to publish on `git push` of a
`v{{version}}` tag using pub.dev's GitHub OIDC integration. As of the 0.0.2
release this has **not actually been enabled on pub.dev**, so the tag-push
workflow fails immediately with "publishing from github is not enabled."

For each package, enable it from that package's pub.dev Admin page ("Automated
publishing" section):

- Repository: `AlphBerlin/local_ai_kit`
- Tag pattern: `v{{version}}`

Until this is done for all eight packages, releases must be published
manually (see below) even though a matching tag/GitHub release already
exists.

## Manual releases (current process)

For a new coordinated release, update the `version:` and `## <version>` entry
in all eight package pubspec/changelog files (and any internal
`local_ai_*: ^x.y.z` cross-package constraints), then run:

```sh
dart pub get
melos run analyze
melos run test
melos run verify:bundle-policy
dart run tool/publish.dart --dry-run
```

Commit the version change, create one matching tag, and push it (this also
triggers the CI workflow above, which will fail until automated publishing
is enabled — that failure is harmless, nothing gets uploaded by it):

```sh
git tag v0.0.3
git push origin v0.0.3
gh release create v0.0.3 --title v0.0.3 --notes-file /path/to/notes.md
```

Then publish each package manually, in the dependency order listed above:

```sh
(cd packages/local_ai_core && dart pub publish --force)
(cd packages/local_ai_flutter && flutter pub publish --force)
(cd packages/local_ai_gemma && flutter pub publish --force)
(cd packages/local_ai_llama_cpp && flutter pub publish --force)
(cd packages/local_ai_sherpa && flutter pub publish --force)
(cd packages/local_ai_kit && flutter pub publish --force)
(cd packages/local_ai_genkit && flutter pub publish --force)
(cd packages/bedge_ai && flutter pub publish --force)
```

## Automated releases (once enabled above)

Once every package has automated publishing enabled, a tag push alone is
enough — the workflow validates the tagged commit and invokes
`dart run tool/publish.dart --publish` with temporary pub.dev OIDC
credentials. The workflow stops if any package fails, so later packages are
never uploaded from an invalid release.
