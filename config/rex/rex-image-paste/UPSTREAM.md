# rex-image-paste provenance

- Upstream: https://github.com/pablasso/rex-image-paste
- Revision: `1d883efb5d348477796733555306f2e445a3593e`
- Plugin version: `0.1.0`
- License: MIT, copyright 2026 Pablo Ortiz; see `LICENSE`.
- Vendored unchanged: `init.lua`, `test/e2e.lua`, `LICENSE`.
- Integrity: `checksums.sha256`, verified by `./dot rex config` before installation.

Updates are deliberate: review a new upstream revision, replace the vendored
files and their checksums, update this revision, and rerun the tests. Do not
`git pull` into the live Rex configuration.

This plugin reads the Mac clipboard only when its action is invoked. For a
remote pane it sends the image through the existing Rex connection, not to an
external upload service. Installing it grants that action clipboard access;
review source changes before upgrading.
