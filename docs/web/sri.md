# Sub-Resource Integrity (SRI) for Flutter Web

This document describes the `flutter build web --sri` feature added on the
`sri-feature` branch and the open distribution question for shipping it.

> Implementation owner: simpleclub (Dennis). Tracked alongside the
> [`flutter_web_sri_tech_design`](../../../flutter/.cursor/plans/flutter_web_sri_tech_design_2d1a0a5b.plan.md)
> plan in the simpleclub product repo.

## Summary

A new opt-in `--sri` flag on `flutter build web`:

1. Computes a digest (default `sha384`, configurable via `--sri-algorithm`)
   for every same-origin `.js`, `.mjs`, `.css`, `.wasm` file in the build
   output directory, **including `flutter_bootstrap.js` itself**. A single
   hashing pass — no mutation, no re-hashing.
2. Stamps `integrity="<algo>-<base64>" crossorigin="anonymous"` onto every
   matching `<script src>` and `<link rel="stylesheet|preload|modulepreload"
   href>` tag in `index.html`.
3. Injects two inline blocks at the top of every `<head>`, in this order:
   - `<script type="importmap">{ "integrity": ... }</script>` — browser
     enforces SRI on dynamic `import()` of `canvaskit.js` / `skwasm.js` /
     `main.dart.mjs`. Baseline-newly-available since Firefox 138 (May 2025),
     Chrome 127 (Jun 2024), Safari 18 (Sep 2024).
   - `<script>window._flutter.integrityMap = {...}</script>` — read by the
     engine's `flutter.js` loader (`lookupIntegrity`) at runtime to stamp
     `integrity` on dynamically-injected classic `<script>` tags (notably
     `main.dart.js`). This script runs *before* `<script src="flutter_bootstrap.js">`,
     so the map is populated before the engine ever needs it.
4. Verifies wasm bytes against `_flutter.buildConfig.wasmHashes` (already
   present, but until now used only as a Cross-Origin-Storage cache key)
   before passing them to `WebAssembly.compile`. Import maps don't apply to
   `fetch()` + `WebAssembly.compileStreaming`, so this last bit stays as
   manual byte verification in `instantiate_wasm.js`.

`flutter_bootstrap.js` is **never rewritten** by `WebIntegrity`. Putting the
integrity data in `index.html` instead of inside the bootstrap removes the
chicken-and-egg hashing order the previous design needed (hash everything →
mutate bootstrap with the map → re-hash bootstrap to stamp `index.html`).

When `--sri` is not set, every code path is a no-op and the build is
byte-identical to before. The dev server (`flutter run -d chrome`) does not
populate the integrity map; the engine loader's `lookupIntegrity` returns
`null` and falls through to the existing behavior, and no import-map block
is emitted.

## Files touched

### Framework (`packages/flutter_tools/`)

- `lib/src/web/compile.dart` — adds `IntegrityConfig`, `kSriEnabled`,
  `kSriAlgorithm`, threads them through `WebBuilder.buildWeb`.
- `lib/src/commands/build_web.dart` — `--sri`, `--sri-algorithm` flags.
- `lib/src/build_system/targets/web.dart` — new `WebIntegrity` target,
  added as a dependency of `WebServiceWorker` so it runs after
  `WebReleaseBundle` and `WebBuiltInAssets`. Computes hashes in a single
  pass, then patches `index.html` once via `_patchIndexHtml`, which uses
  `package:html` to discover element positions (each `Element.sourceSpan`)
  and applies edits as in-place string splices in *descending* offset
  order so earlier offsets stay valid. The document is never re-serialized
  — quoting, attribute order and whitespace outside the inserted regions
  are preserved bit-for-bit. The patcher stamps `integrity` /
  `crossorigin` on `<script src>` and `<link rel="stylesheet|preload|
  modulepreload" href>`, and prepends `<script type="importmap">` plus
  the inline `window._flutter.integrityMap = {...}` block to `<head>`.
  **Does not mutate `flutter_bootstrap.js`.**
- `test/general.shard/build_system/targets/web_test.dart` — 13 tests under
  the `--sri` group: import-map emission, the inline integrity-map script,
  ordering, bootstrap-immutability, single-quoted attribute preservation,
  hand-stamped tags left alone, and `<link rel="icon">` skipped.

### Engine (`engine/src/flutter/lib/web_ui/flutter_js/`)

- `src/integrity.js` *(new)* — shared helpers: `lookupIntegrity` (reads
  `window._flutter.integrityMap.sameOrigin`, used by `entrypoint_loader.js`
  for the classic `main.dart.js` script tag), `lookupWasmHash`,
  `verifyAgainstWasmHash` (used by `instantiate_wasm.js`). No fetch/import
  shim: dynamic `import()` integrity is enforced natively by the browser
  via the import map.
- `src/entrypoint_loader.js` — stamps `integrity` on the
  `<script src="main.dart.js">` element returned by `_createScriptTag`.
- `src/canvaskit_loader.js` — uses plain `import(canvasKitUrl)` (with
  Trusted Types wrapping). The browser enforces SRI from the import map.
- `src/skwasm_loader.js` — same pattern for `${fileStem}.js`.
- `src/instantiate_wasm.js` — verifies the fetched bytes against
  `_flutter.buildConfig.wasmHashes` (hex SHA-256) before compile.
- `sources.gni` — adds `src/integrity.js` to the bundled JS source list.

## Why import maps?

The first revision of this design used a `fetch + verify + Blob.createObjectURL`
shim in JavaScript to cover dynamic `import()`, because browsers historically
did not enforce SRI on `import()` (see <https://github.com/whatwg/html/issues/2382>).
That shim has been removed in favor of native browser enforcement via
`<script type="importmap">{ "integrity": ... }</script>`.

Browser support snapshot:

| Browser  | First version | Released  |
|----------|---------------|-----------|
| Chrome   | 127           | Jun 2024  |
| Edge     | 127           | Jun 2024  |
| Safari   | 18.0          | Sep 2024  |
| Firefox  | 138           | May 2025  |

Older browsers parse the `<script type="importmap">` tag but ignore the
`integrity` key (Firefox previously logged a warning that it was an
"invalid top-level key"; that behavior was changed in 138). On those
older versions the dynamic-import path silently degrades to no-SRI, the
same outcome as not passing `--sri`. Static `<script integrity>` and
`main.dart.js` stamping continue to work everywhere.

## Why this is needed

Today (without `--sri`):

- `<script src="flutter_bootstrap.js">` in `index.html` has no `integrity`
  attribute even on builds where the team supplies `wasmHashes`.
- `main.dart.js` is created via `document.createElement("script")` in the
  engine's `_createScriptTag` with no `integrity`.
- `canvaskit.js` / `skwasm.js` are loaded via dynamic `import()`, which
  the browser never integrity-checks (the SRI spec doesn't apply to
  `import()` expressions).
- `canvaskit.wasm` / `skwasm.wasm` are fetched via `fetch()` then handed
  to `WebAssembly.compileStreaming`, which also never integrity-checks
  the bytes.

`--sri` closes all four gaps. It also unblocks the CSP follow-up
(replacing `'unsafe-inline'` with `'strict-dynamic'` + nonces / hashes)
because the loader-injected scripts now have a known `integrity` value
that satisfies the CSP source list.

## Open: engine rebuild

The engine source files under `flutter_js/src/` are bundled by `esbuild`
into a minified `flutter.js` distributed via the host artifacts. The
framework's `WebTemplatedFiles` reads that **prebuilt** bundle, so changes
to the engine sources do not take effect at runtime until the engine is
rebuilt and the framework is rolled to point at the new engine version.

Local engine rebuild:

```bash
cd engine/src
gclient sync -D
gn gen out/host_debug_unopt
ninja -C out/host_debug_unopt flutter/lib/web_ui:flutter_js
# host_debug_unopt/flutter_web_sdk/flutter_js/flutter.js is the new bundle.
```

Until that bundle is rolled, only the framework half (the `WebIntegrity`
target stamping `<script integrity>` on the static bootstrap tag and
emitting the import-map block) is observable; the engine half
(loader-injected `main.dart.js`, dynamic `import()` of canvaskit/skwasm,
wasm hash verification) requires the fresh `flutter.js`. The
`app/tool/sri/inject_sri.dart` post-build script (Approach 1) gives us
the same coverage today and remains shipped.

## Distribution decision (deferred)

Three sub-options were sketched in the tech-design plan:

- **2a. Upstream to flutter/flutter.** Open a draft PR to
  [flutter/flutter](https://github.com/flutter/flutter/) referencing the
  long-standing SRI request. Engine PR (`flutter/flutter` engine
  directory) lands first, then a Flutter framework roll wires `--sri`
  on. The data model (`_flutter.buildConfig.wasmHashes`) is already
  upstream, so the design fit is good. The import-map approach makes the
  engine diff much smaller (no Blob shim, no fetch+verify dance) which
  should make review faster.

- **2b. Maintain a `simpleclub-extended/flutter` fork** pinned via FVM
  (`.fvmrc`). Mechanically the simplest path to deploy: push `sri-feature`
  to a fork, point `.fvmrc` at it, ship. Cost: rebasing
  `engine/src/flutter/lib/web_ui/flutter_js/` and the build_system targets
  on every Flutter SDK upgrade. The engine sources change rarely and our
  diff is small (~6 files), so rebases should usually be clean.

- **2c. Cherry-pick at FVM install time.** A post-install script in
  `flutter/jarvis/` or similar applies the patch to the FVM-resolved
  Flutter SDK. Same engine-rebuild constraint as 2b but without
  hosting a public fork. Fragile across Flutter version bumps and
  reproducibility-hostile (CI machines vs dev machines).

**Current state:** branch `sri-feature` exists on
`/Users/dennis/develop/flutter-framework`, contains the changes listed
above, and is **not** pushed. All `web_test.dart` (632),
`build_web_test.dart` (24), and `web_template_test.dart` (16) tests pass.

**Recommended next step:** open a draft PR upstream (option 2a) AND
publish the same diff to a `simpleclub-extended/flutter` branch as a
backup (option 2b). Use option 2b for an initial production deploy if
upstream review stalls past ~6 weeks. Approach 1 (the post-build script
in the simpleclub product repo) covers the same threat surface in the
meantime, with the wasm-hash verification gap.
