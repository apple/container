<!--
SPDX-FileCopyrightText: 2026 Christian Semmelmann
SPDX-License-Identifier: Apache-2.0
-->

# The `ocx-package` branch

This branch builds the OCX package `ocx.sh/extra-code/container`.
The package is a temporary patched build of [apple/container](https://github.com/apple/container) for Parbake.
It goes away once Apple ships the patches in a release.

The branch is one commit on top of `parbake`.
It adds only `ocx/`, `scripts/ocx-package.sh` and `.github/workflows/ocx-package.yml`.

## What is here

- `ocx/source-revision` names the 40-hex fork revision to build.
- `ocx/metadata.json` puts `bin` on `PATH` and declares `container` and `container-apiserver`.
- `scripts/ocx-package.sh` checks the tag, builds the revision, verifies signatures and creates the archive.
- `.github/workflows/ocx-package.yml` runs those steps on an `ocx-*` tag and pushes a signed package.
- `.github/workflows/ocx-claim.yml` claims the package in the OCX index. It runs by hand only.

The JSON file and `ocx/source-revision` carry no license header by design.
Neither format has a comment syntax.

## Cut a release

1. Set `ocx/source-revision` to the revision Parbake pins.
   It must be on `parbake`.
   The upstream tag `X.Y.Z` must be its highest apple/container tag.
2. Commit the change on `ocx-package` and push the branch.
3. Tag that commit `ocx-X.Y.Z_NN` and push the tag.

Push the branch before the tag.
The workflow refuses a tag whose commit is not yet on `ocx-package`.

`NN` is a two-digit counter.
It starts at `01` and resets for each new upstream version.
For example, the first build of upstream 1.6.1 is `ocx-1.6.1_01`.

The `check` step fetches the tags of apple/container itself.
It ignores the tags in this fork, because anyone with push access can write them.

The workflow publishes `ghcr.io/extra-code/container:X.Y.Z_NN`.
It also moves the rolling tags `X.Y.Z`, `X.Y` and `X`.

## Announce to the OCX index

Run `ocx-claim.yml` once by hand, after the package is public.
It never runs on its own.

The publish job pushes with `--tags-file tags.txt` and passes the tags it wrote to the announce job.
The announce job writes them back to `tags.txt` and announces exactly those tags as ephemeral.
It never lists the registry, so tags that were not announced yet stay out of the index.

Both workflows need the `OCX_ANNOUNCE_TOKEN` secret and the `OCX_INDEX_FORK` variable in the `release` environment.
The announce job also needs the repository variable `OCX_INDEX_ANNOUNCE` set to `true`.
Use a fine-grained personal access token with read and pull-request write on `ocx-sh/index` and the owner's index fork.
A classic token with the `repo` scope is the fallback.

To retire the package, run `ocx package prune`.
It deletes only the tags the index marks ephemeral.
Then run `ocx package announce --tags-file` to update the index.

## Verify changes

Run these two commands before you push:

```bash
shellcheck scripts/ocx-package.sh
scripts/ocx-package.sh --self-test
```

The self-test runs offline and leaves no file behind.

A local dry run of `check` needs the refs `origin/parbake` and `origin/ocx-package`.
Set `OCX_PACKAGE_BASE_REF` and `OCX_PACKAGE_BRANCH_REF` to use other refs.
It also needs network access to apple/container on GitHub.
It stores those tags under `refs/upstream-tags/`, not under `refs/tags/`.

`create` writes the archive and its metadata to `out/`, the local output directory.
