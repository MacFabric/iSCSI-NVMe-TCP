# NVMeKit source snapshot

- Upstream: https://github.com/MacFabric/NVMeKit
- Base version: 0.1.0
- Base commit: `d09daac70407b469e2e24c1439dceca5c7039a19`
- Local snapshot commit: `b570a867a0b7bd1db92a218a642f5b8d00f53caf`
  on the companion repository's `codex/read-bench-logging` branch (not pushed).
- License: Apache-2.0; the upstream `LICENSE` is preserved here.

This snapshot includes the read-bench logging changes: optional diagnostics in
the block device, controller and queue; shared connection UUIDs in transport
traces and completions; received-byte accounting in diagnostic output; and
`NVMeReadLoggingTests` covering traced and untraced reads. The changes were
ported from the user's `nvmeof-initiator` working tree. The existing NVMeKit
error-description API is preserved.

Both the root Swift package and `apps/project.yml` reference this directory.
The source is checked in so CI and fresh clones can compile the logging API
without a sibling checkout, an editable dependency, or an unpublished tag.
The standalone package retains its upstream sources, tests, fuzz tools and
FabricKit lockfile. Its upstream README describes the original package;
this file records how this application consumes it.

## Updating

Make NVMeKit changes in this directory and run both the root suite and
`swift test --package-path Vendor/NVMeKit --no-parallel`. When importing an
upstream update, review the diff against the base commit, retain or reconcile
the diagnostics, update this provenance, and preserve the upstream license.

To return to a released upstream package once it contains these APIs, update
`Package.swift`, `Package.resolved` and the NVMeKit entry in `apps/project.yml`
together, regenerate the Xcode project with the pinned XcodeGen version, and
remove this snapshot and its dedicated CI test step. Verify a clean checkout
without editable package overrides before merging.
