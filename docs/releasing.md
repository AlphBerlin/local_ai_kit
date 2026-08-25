# Releasing to pub.dev

LocalAI Kit publishes six packages as one coordinated release. The repository
tag is shared, while uploads run in dependency order:

1. `local_ai_core`
2. `local_ai_flutter`
3. `local_ai_gemma`
4. `local_ai_sherpa`
5. `local_ai_kit`
6. `local_ai_genkit`

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
(cd packages/local_ai_sherpa && flutter pub publish)
(cd packages/local_ai_kit && flutter pub publish)
(cd packages/local_ai_genkit && flutter pub publish)
```

After each upload, confirm the package is available at
`https://pub.dev/packages/<package-name>`. Transfer every package to the
verified `alphberlin.com` publisher from its pub.dev Admin page.

For each package, enable automated publishing with:

- Repository: `AlphBerlin/local_ai_kit`
- Tag pattern: `v{{version}}`

The first manual `0.0.1` upload is the bootstrap release. Do not push a
`v0.0.1` tag to the publishing workflow after those uploads because it would
attempt to upload the same versions again. Use `v0.0.2` for the first
automated release.

## Automated releases

For a new coordinated release, update the `version:` and `## <version>` entry
in all six package pubspec/changelog files, then run:

```sh
melos bootstrap
melos run analyze
melos run test
melos run verify:bundle-policy
dart run tool/publish.dart --dry-run
```

Commit the version change, create one matching tag, and push it:

```sh
git tag v0.0.2
git push origin v0.0.2
```

The tag-only GitHub Actions workflow validates the tagged commit and invokes
`dart run tool/publish.dart --publish` with temporary pub.dev OIDC credentials.
The workflow stops if any package fails, so later packages are never uploaded
from an invalid release.
