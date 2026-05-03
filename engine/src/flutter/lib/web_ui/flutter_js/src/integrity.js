// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/**
 * Sub-Resource Integrity helpers used by the Flutter web loader.
 *
 * The framework emits SRI metadata in three forms when `flutter build web
 * --sri` is used. Each form is consumed by a different runtime path:
 *
 * 1. `<script type="importmap">{ "integrity": { url -> "<algo>-<base64>" } }</script>`
 *    Inserted at the top of `<head>` by the `WebIntegrity` build target.
 *    The browser uses this to enforce SRI on dynamic `import()` calls
 *    (canvaskit.js, skwasm.js, main.dart.mjs). No JS in this file is
 *    involved — the browser handles verification natively.
 *
 * 2. `window._flutter.integrityMap = { algorithm, sameOrigin: { url -> "<algo>-<base64>" } }`
 *    Set by an inline `<script>` injected at the top of `<head>` by the
 *    `WebIntegrity` build target, immediately after the import map and
 *    before `<script src="flutter_bootstrap.js">`. Powers SRI on
 *    dynamically-injected classic `<script>` tags (currently `main.dart.js`,
 *    which is not loaded as an ES module). Consumed by `lookupIntegrity`
 *    below, called from `entrypoint_loader.js`.
 *
 * 3. `_flutter.buildConfig.wasmHashes = { url -> "<hex sha256>" }`
 *    Already populated regardless of `--sri` (originally a Cross-Origin
 *    Storage cache key). We piggy-back on it in `instantiate_wasm.js` to
 *    actually verify wasm bytes before passing them to `WebAssembly.compile`,
 *    because import maps don't apply to `fetch()`+`compileStreaming` and
 *    SRI on wasm is not yet a thing.
 *
 * None of these helpers throws on a missing entry — they return `null` so
 * callers can degrade gracefully when SRI is off or a particular asset is
 * not in the integrity map.
 */

/**
 * Returns the SRI integrity string for `url`, or `null` if there is no
 * entry in `_flutter.integrityMap.sameOrigin`. The lookup is keyed by the
 * URL's pathname (without any leading `/` or query string) AND by the
 * basename, so absolute, relative, and cache-busted URLs all resolve.
 *
 * @param {string|URL} url
 * @returns {string|null}
 */
export const lookupIntegrity = (url) => {
  const integrity = window._flutter?.integrityMap;
  if (!integrity?.sameOrigin) {
    return null;
  }
  const map = integrity.sameOrigin;
  let resolved;
  try {
    resolved = new URL(url, location.href);
  } catch (_) {
    return null;
  }
  // Only allow same origin
  if (resolved.origin !== location.origin) {
    return null;
  }
  const path = resolved.pathname.replace(/^\//, "").split("?")[0].split("#")[0];
  return map[path] || map[path.split("/").pop()] || null;
};

/**
 * Hex-encodes a Uint8Array.
 *
 * @param {Uint8Array} bytes
 * @returns {string}
 */
const toHex = (bytes) => {
  const out = new Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    out[i] = bytes[i].toString(16).padStart(2, "0");
  }
  return out.join("");
};

/**
 * Verifies `buffer` against a HEX SHA-256 string from
 * `_flutter.buildConfig.wasmHashes`. Throws if the digest does not match.
 * No-op when `expectedHex` is null/undefined.
 *
 * @param {ArrayBuffer} buffer
 * @param {string|null|undefined} expectedHex
 * @param {string} debugUrl
 * @returns {Promise<void>}
 */
export const verifyAgainstWasmHash = async (buffer, expectedHex, debugUrl) => {
  if (!expectedHex) {
    return;
  }
  const actualBuffer = await crypto.subtle.digest("SHA-256", buffer);
  const actual = new Uint8Array(actualBuffer);
  const actualHex = toHex(actual);
  if (actualHex !== expectedHex) {
    throw new Error(`Wasm hash check failed for ${debugUrl}: expected ${expectedHex}, got ${actualHex}.`);
  }
};
