---
name: release
description: Release a new labvpn version end to end - changelog, version bump, dry run, notarized build, GitHub release and Homebrew cask. Use when the owner asks to release, ship or publish a version.
---

# Release labvpn

The owner doesn't read Swift. Report in plain language and ask before anything public.

1. **Pick the version.** Read the commits since the last tag (`git log $(git describe --tags --abbrev=0)..HEAD --oneline`).
   Bug fixes only: raise the patch number. New features: the minor number. Say which and why.
2. **Changelog.** Make sure `CHANGELOG.md` has a `## Unreleased` section that covers every
   change a user would notice, written for users, like the existing entries. Internal changes
   (tests, lint, docs) don't go in. If the helper, its scripts or `HelperProtocol` changed,
   end with "The helper updates itself." and check `HelperConstants.version` went up since
   the last tag.
3. `scripts/bump-version.sh X.Y.Z`, then commit as `labvpn X.Y.Z`.
4. `scripts/release.sh --dry-run`. Fix anything it stops on.
5. **Ask the owner to confirm**: show the version and the notes. Mention any live checks from
   `docs/testing.md` the changes touch that nobody has run. Publishing is public and can't
   be fully undone.
6. On a yes, `scripts/release.sh` (notarization takes a few minutes: run it in the background).
7. Report the release link, and that the Homebrew cask was updated.

If it fails after tagging, `docs/releasing.md` says how to finish by hand.
