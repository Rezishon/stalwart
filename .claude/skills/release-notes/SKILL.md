---
name: release-notes
description: Step-by-step workflow for tagging and releasing Stalwart / MailiaM single-binary and Docker builds via CI.
---

# Release Notes & Release Workflow

## Full release workflow for future versions

1. **Stamp version suffix**:
   Update `resources/RL_VERSION` (Cargo version stays `0.16.25`, display version appends suffix, e.g. `rl1.0.20`):
   ```bash
   echo "rl1.0.20" > resources/RL_VERSION
   ```

2. **Update changelog**:
   Add release notes header and summary in `CHANGELOG.md`:
   ```markdown
   ## [0.16.25-rl1.0.20] - 2026-10-18
   ```

3. **Commit and tag**:
   ```bash
   git commit -am "chore(release): stamp --version 0.16.25-rl1.0.20"
   git tag -a v0.16.25-rl1.0.20 -m "0.16.25-rl1.0.20"
   ```

4. **Push commit and tag to trigger CI**:
   ```bash
   git push origin main
   git push origin v0.16.25-rl1.0.20
   ```

CI in `.github/workflows/ci.yml` will:
- Build Linux musl (x86_64, aarch64, armv7), Windows x64, and FreeBSD x64 binaries.
- Build and push multi-arch Docker image to GHCR (`ghcr.io/rezishon/mailiam`).
- Create GitHub release with changelog body and publish once all builds succeed.
