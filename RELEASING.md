# Releasing `@zyncbase/client`

Publishing runs through one GitHub Actions workflow:`.github/workflows/release-sdk.yml`
(`Release SDK`, manual trigger). It builds, runs the SDK test suite, bumps the
version, publishes to npm with provenance, and pushes the version commit plus a
`sdk-v<version>` tag.

Tags use the `sdk-v<version>` scheme because plain `v0.1.0`/`v0.2.0` tags already
exist in this repo for pre-SDK milestones, and `v*` tags trigger the server binary
release workflow (`.github/workflows/release.yml`) — `sdk-v*` tags must not.

## One-time setup

1. **npm scope.** Create the `@zyncbase` organization on npmjs.com (or confirm
   ownership). Both `@zyncbase/client` and `zyncbase` are currently unpublished
   on the public registry. If `@zyncbase` is not yours, pick a different scope
   before the first publish — scoped names cannot be transferred easily.
2. **First publish.** npm trusted publishing is configured on the package
   settings page, so the very first publish may need to be manual:
   ```bash
   cd sdk/typescript
   bun run build
   npm login
   npm publish        # publishConfig.access=public
   ```
   (If npmjs.com lets you attach the trusted publisher before the first publish,
   skip this and use the workflow directly.)
3. **Trusted publisher.** On npmjs.com → package settings → Trusted Publisher:
   GitHub owner `mstdokumaci`, repository `zyncbase`, workflow `release-sdk.yml`,
   environment blank. No `NPM_TOKEN` secret is needed after this.

## Cutting a release

GitHub → Actions → **Release SDK** → Run workflow, from `main`:

| Input | Effect |
|---|---|
| `patch` / `minor` / `major` | semver bump via `npm version` |
| exact `0.3.0` | sets that version (must not already exist on npm) |

The workflow publishes *before* pushing the commit and tag. If publishing
succeeds but the tag step fails, push the tag manually:

```bash
git tag -a sdk-v<version> -m "@zyncbase/client v<version>"
git push origin sdk-v<version>
```

If the npm version already exists, the run fails at publish — bump again; npm
versions are immutable.

## Local dry runs

```bash
cd sdk/typescript
bun run build
npm publish --dry-run   # verifies tarball contents and metadata, publishes nothing
```

## Versions and changelogs — decision log

- **No changesets while there is one publishable package.** The React layer is a
  `/react` subpath of `@zyncbase/client`, so there is no version graph to
  coordinate. Changelog lives in GitHub Releases for the `sdk-v*` tags.
- **Upgrade trigger:** add [changesets](https://github.com/changesets/changesets)
  when a second publishable package appears (e.g., a split React package or a
  server SDK) or when external contributors need an automated changeset flow.
- The workflow assumes `main` is the release branch; run dispatches from there.
