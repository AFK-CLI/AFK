# Sparkle SHA256 Pinning for Agent Releases

The agent release CI workflow (`.github/workflows/agent-release.yml`) downloads the Sparkle `generate_appcast` binary to build the auto-update feed. To prevent supply-chain attacks, the download is pinned to a specific version with SHA256 integrity verification.

## How It Works

The workflow has two env vars in the "Generate appcast" step:

```yaml
env:
  SPARKLE_VERSION: "2.9.0"
  SPARKLE_SHA256: "<sha256-hash-here>"
```

When `SPARKLE_SHA256` is set, the workflow verifies the download:

```bash
echo "${SPARKLE_SHA256}  ${RUNNER_TEMP}/sparkle.tar.xz" | shasum -a 256 -c -
```

If the hash doesn't match, the step fails and the release is aborted.

## Getting the SHA256 Hash

### Option 1: Download and hash locally

```bash
# Download the specific version
curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-2.tar.xz" -o /tmp/sparkle.tar.xz

# Compute SHA256
shasum -a 256 /tmp/sparkle.tar.xz
```

Copy the hex string (first column) and paste it as the `SPARKLE_SHA256` value.

### Option 2: Use GitHub API checksums

```bash
# Get the release assets and their checksums
gh release view 2.9.0 --repo sparkle-project/Sparkle --json assets
```

Some releases include `.sha256` files alongside the archives.

## Updating Sparkle Version

When upgrading to a new Sparkle release:

1. Update `SPARKLE_VERSION` to the new version tag
2. Download the new archive and compute its SHA256 (see above)
3. Update `SPARKLE_SHA256` with the new hash
4. Test the workflow with a dry run or on a branch before merging

## Current Status

| Version | SHA256 | Status |
|---------|--------|--------|
| 2.9.0 | *needs to be set* | Verification infrastructure ready, hash not yet populated |

> **Before the next agent release**, run the download+hash command above and update `SPARKLE_SHA256` in `agent-release.yml`.
