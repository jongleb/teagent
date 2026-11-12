# Releasing

A package is released when CHANGES.md lists unreleased changes for it.

1. **Version.** Bump `packages/NAME/VERSION` by semantic versioning, from the largest change:
   a change that breaks code using the package (something removed or renamed, a changed
   signature) is major; a new feature is minor; anything else is a patch. A major bump resets
   minor and patch to 0; a minor bump resets patch.
2. **Pins.** `packages/NAME/deps` pins each dependency as `dep ^MAJOR.MINOR`. When a dependency
   gets a new major version, pin `^NEW_MAJOR.0` in every package that depends on it. That alone
   is a patch for the depending package, which is then released too.
3. **Changelog.** In CHANGES.md, move the package's entries from `## Unreleased` to a new
   section `## NAME VERSION` right below `## Unreleased`, one section per released package, in
   the order core, api, cli, web. Leave `## Unreleased` in place, even when it becomes empty.
