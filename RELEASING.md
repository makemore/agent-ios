# Releasing `agent-ios`

The iOS library is distributed as **Swift Package Manager source**, straight from
the `makemore/agent-ios` repo. There is no binary artifact to upload — a release is
simply an **annotated, semver Git tag** that SwiftPM consumers resolve.

Two products ship from the one package (see [`Package.swift`](Package.swift)):

- `AgentFrontend` — full SwiftUI chat UI (depends on `AgentClient`)
- `AgentClient` — headless runtime/transport core

> **Audience:** library maintainers. If you are *consuming* the library in an app,
> see [`README.md`](README.md) / [`TEMPLATE_APP_SETUP.md`](TEMPLATE_APP_SETUP.md).

---

## Versioning

- Semantic versioning, tag form `MAJOR.MINOR.PATCH` (e.g. `0.8.0`) — **no** `v`
  prefix, matching the existing tag history (`0.4.0` … `0.8.0`).
- SwiftPM picks the highest tag satisfying a consumer's range (e.g.
  `from: "0.8.0"` → up to next major). Breaking API changes warrant a major bump.

---

## Release steps

1. **Make sure `main` is green.** Run the test suite locally:

   ```bash
   swift test
   ```

   (Or run the `AgentClientTests` / `AgentFrontendTests` schemes in Xcode.)

2. **Update version references in docs** so consumers copy the right number:
   - `README.md` (the `from: "X.Y.Z"` install snippets, both `AgentFrontend` and
     `AgentClient`)
   - `TEMPLATE_APP_SETUP.md` (the `from:` version in the install section)

3. **Commit** the doc bump (open a PR if branch protection requires it) and merge
   to `main`:

   ```bash
   git add README.md TEMPLATE_APP_SETUP.md
   git commit -m "Release 0.8.0"
   ```

4. **Tag the release commit and push the tag:**

   ```bash
   git tag -a 0.8.0 -m "0.8.0"
   git push origin 0.8.0
   ```

   That's the publish step — no registry upload. Consumers resolving
   `https://github.com/makemore/agent-ios.git` will see the new tag immediately.

5. **(Recommended) Create a GitHub Release** from the tag with brief notes, so the
   change history is visible on the repo's Releases page.

6. **Verify** by pointing a consuming app at the new tag and resolving packages
   (Xcode: **File → Packages → Update to Latest Package Versions**), or:

   ```bash
   swift package resolve
   ```

---

## Notes

- **Public repo:** the repository is public, so anyone (or any CI) can resolve the
  package with no SSH key, PAT, or Xcode account configuration. A failed resolve is
  almost always a tag/range problem rather than access.
- **Tags are the source of truth.** Avoid moving/retagging a published version;
  consumers may have cached the old commit for that tag. To fix a bad release,
  push a new patch tag instead.
- **Branch resolution (pre-release testing):** consumers can temporarily depend on
  a branch (`.package(url: …, branch: "main")`) to validate unreleased changes
  before you cut the tag.
