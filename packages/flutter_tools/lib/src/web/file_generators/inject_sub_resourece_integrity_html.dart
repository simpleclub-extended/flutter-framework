import 'package:crypto/crypto.dart' as crypto;
import 'package:html/dom.dart' show Document, Element;
import 'package:html/parser.dart' show parse;
import 'package:source_span/source_span.dart';

import '../../base/file_system.dart';
import '../../convert.dart';

/// `<link rel="…">` values that name a subresource the browser can SRI-check.
const Set<String> _kSriProtectedLinkRels = <String>{
  'stylesheet',
  'preload',
  'modulepreload'
};

/// Pending HTML edit recorded against the original (un-mutated) source.
class _HtmlEdit {
  const _HtmlEdit(this.offset, this.text);

  /// Insert position in the original source string.
  final int offset;

  /// Text to insert at [offset].
  final String text;
}

/// Result of [injectSubresourceIntegrity].
/// The patched HTML string and the set of inline script hashes of the HTML.
class PatchedHtml {
  const PatchedHtml(this.html, this.userInlineScriptHashes) : isModified = true;

  PatchedHtml.unmodified(this.html)
      : isModified = false,
        userInlineScriptHashes = const {};

  /// Whether the [html] string was patched.
  final bool isModified;

  /// The patched HTML string with integrity attributes injected.
  final String html;

  /// Hashes in the format `<algo>-<base64>` of inline `<script>` tags included
  /// in the [html] string.
  /// Can be used to populate a CSP `script-src` allow-list for user-authored
  /// inline scripts.
  final Set<String> userInlineScriptHashes;
}

String generateIntegrityHash(List<int> input, {required String algorithm}) {
  final crypto.Hash digest = _digestForAlgorithm(algorithm);
  return _formatIntegrity(algorithm: algorithm, digest: digest.convert(input));
}

/// Injects Subresource Integrity (SRI) checks into a `.html` source file by
/// adding:
///
///   * `integrity="…"` and `crossorigin="anonymous"` on every same-origin
///     `<script src="…">` and `<link rel="stylesheet|preload|modulepreload"
///     href="…">`.
///   * `integrity="…"` on every executable inline `<script>` to enable
///     Content Security Policies (CSP) with a `script-src 'sha384-…' allowlist.
///     (the hash is computed over the raw text between the start- and end-tag).
///   * A `<script type="importmap" integrity="…">…</script>` block, as first
///     script in the `<head>` to allow validating dynamically imported scripts.
///   * A `<script integrity="…">window._flutter.integrityMap = {…}</script>`
///     block, as second script after the import map to allow
///     flutter_bootstrap.js to add script elements with integrity hashes.
///
/// The HTML is parsed with `package:html` only to *discover* tag positions;
/// the document is never re-serialized. All edits are applied as in-place
/// string splices on the original source so quoting, attribute order, and
/// whitespace are preserved bit-for-bit outside of the inserted regions.
///
/// Idempotent: re-running on already-patched HTML is a no-op for any
/// element that already has `integrity` set, and the head-prepend block
/// detects existing `<script type="importmap">` / `window._flutter.integrityMap`
/// markers.
PatchedHtml injectSubresourceIntegrity({
  required File htmlFile,
  required Directory outputDir,
  required Map<String, String> integrityMap,
  required FileSystem fileSystem,
  required String algorithm,
}) {
  final String html = htmlFile.readAsStringSync();
  final Directory htmlFileDir = htmlFile.parent;
  final inlineScriptHashes = <String>{};

  // Pre-render the bodies of the two scripts we inject into <head>, then
  // hash them so we can stamp `integrity` on the wrapping <script> tag.
  // Browsers spec-wise ignore `integrity` on inline <script>, but the same
  // hash is what a CSP `script-src 'sha384-…'` allow-list consumes; the
  // attribute is harmless in browsers that don't honor it and informative
  // for tooling that does.
  String wrapInlineScript(String body, {String? type}) {
    if (body.isEmpty) {
      return '';
    }
    final String hash = generateIntegrityHash(
        utf8.encode(body), algorithm: algorithm);
    inlineScriptHashes.add(hash);
    final typeAttr = type == null ? '' : ' type="$type"';
    return '<script$typeAttr integrity="$hash">$body</script>';
  }

  final String integrityMapJs = _renderIntegrityMapJs(
    algorithm: algorithm,
    sameOrigin: integrityMap,
  );
  final String importMapJson = _renderImportMapJson(integrityMap);
  final String importMapTag = wrapInlineScript(
      importMapJson, type: 'importmap');
  final String integrityMapScriptTag = wrapInlineScript(integrityMapJs);

  // Parse the HTML using `package:html` to discover tag positions and existing
  // attributes. Keep track of the edits to be done to the HTML, so we can apply
  // them all in one pass at the end.
  final Document doc = parse(html, generateSpans: true);
  final edits = <_HtmlEdit>[];

  // Generate edits for inline and external <script> tags.
  for (final Element script in doc.querySelectorAll('script')) {
    if (script.attributes.containsKey('src')) {
      final _HtmlEdit? edit = _attrInjectionEdit(
        html: html,
        htmlFileDir: htmlFileDir,
        element: script,
        url: script.attributes['src'],
        outputDir: outputDir,
        integrityMap: integrityMap,
        fileSystem: fileSystem,
      );
      if (edit != null) {
        edits.add(edit);
      }
    } else {
      final ({_HtmlEdit edit, String hash})? stamp = _inlineScriptStampEdit(
        html: html,
        element: script,
        algorithm: algorithm,
      );
      if (stamp != null) {
        edits.add(stamp.edit);
        inlineScriptHashes.add(stamp.hash);
      }
    }
  }

  // Generated edits for `<link rel="stylesheet|preload|modulepreload" href="…">` tags.
  for (final Element link in doc.querySelectorAll('link[rel][href]')) {
    final String rel = (link.attributes['rel'] ?? '').toLowerCase();
    if (!_kSriProtectedLinkRels.contains(rel)) {
      continue;
    }
    final _HtmlEdit? edit = _attrInjectionEdit(
      html: html,
      htmlFileDir: htmlFileDir,
      element: link,
      url: link.attributes['href'],
      outputDir: outputDir,
      integrityMap: integrityMap,
      fileSystem: fileSystem,
    );
    if (edit != null) {
      edits.add(edit);
    }
  }

  // Generate edits for inserting importmap + integrity-map script into <head> tag.
  final _HtmlEdit? headEdit = _headPrependEdit(
    doc: doc,
    importMapTag: importMapTag,
    integrityMapScriptTag: integrityMapScriptTag,
  );
  if (headEdit != null) {
    edits.add(headEdit);
  }

  if (edits.isEmpty) {
    return PatchedHtml.unmodified(html);
  }

  // Apply in reverse offset order so earlier offsets stay valid as we insert
  // integrity hashes into the HTML file.
  edits.sort((_HtmlEdit a, _HtmlEdit b) => b.offset.compareTo(a.offset));
  var patched = html;
  for (final edit in edits) {
    patched =
    '${patched.substring(0, edit.offset)}${edit.text}${patched.substring(
        edit.offset)}';
  }
  return PatchedHtml(patched, inlineScriptHashes);
}

String _escapeOpeningCaretInJs(String input) => input.replaceAll('<', '√');

/// Renders JS snippet to populate `window._flutter.integrityMap` so the
/// engine's `lookupIntegrity` can find it at runtime.
String _renderIntegrityMapJs(
    {required String algorithm, required Map<String, String> sameOrigin}) {
  final String json = _escapeOpeningCaretInJs(
      jsonEncode(<String, Object?>{
        'algorithm': algorithm,
        'sameOrigin': sameOrigin,
      })
    );
  return 'window._flutter = window._flutter || {}; '
      'window._flutter.integrityMap = $json;';
}

/// Renders the JSON body of the import map used by the browser to enforce
/// SRI on dynamic `import()` calls.
///
/// Keys are emitted as relative URLs (e.g. `canvaskit/canvaskit.js`) so they
/// resolve against the document's base URL.
String _renderImportMapJson(Map<String, String> integrityMap) {
  if (integrityMap.isEmpty) {
    return '';
  }
  final String json = jsonEncode(<String, Object?>{'integrity': integrityMap});
  return _escapeOpeningCaretInJs(json);
}

/// Returns an edit that inserts ` integrity="…" crossorigin="anonymous"`
/// just before the closing `>` of [element]'s start tag, or null when no
/// edit is needed (cross-origin URL, missing hash, already stamped, no
/// source span available).
_HtmlEdit? _attrInjectionEdit({
  required String html,
  required Directory htmlFileDir,
  required Element element,
  required String? url,
  required Directory outputDir,
  required Map<String, String> integrityMap,
  required FileSystem fileSystem,
}) {
  if (url == null || url.isEmpty) {
    return null;
  }
  // Ignore already-stamped tags, e.g. re-runs or hand-stamped third-party tags.
  if (element.attributes.containsKey('integrity')) {
    return null;
  }
  final String? integrity = _resolveIntegrity(
    url: url,
    htmlFileDir: htmlFileDir,
    outputDir: outputDir,
    integrityMap: integrityMap,
    fileSystem: fileSystem,
  );
  if (integrity == null) {
    return null;
  }
  final FileSpan? span = element.sourceSpan;
  if (span == null) {
    return null;
  }
  // [span.end.offset] points one past the trailing `>` of the start tag.
  // Insert before that `>` (or before the `/` of a self-closing `/>`).
  int insertAt = span.end.offset - 1;
  if (insertAt > span.start.offset && html[insertAt - 1] == '/') {
    insertAt -= 1;
  }
  // Strip a redundant leading space when the original tag already has
  // whitespace before the closing `>` (so `<link href="…" />` stays single-
  // spaced after we splice in `integrity`).
  final bool needsLeadingSpace = insertAt == 0 ||
      !_isHtmlWhitespace(html.codeUnitAt(insertAt - 1));
  final attrs = StringBuffer();
  if (needsLeadingSpace) {
    attrs.write(' ');
  }
  attrs.write('integrity="$integrity"');
  if (!element.attributes.containsKey('crossorigin')) {
    attrs.write(' crossorigin="anonymous"');
  }
  return _HtmlEdit(insertAt, attrs.toString());
}

/// Computes the SRI hash of an inline `<script>` and returns the script hash
/// and an edit to insert the `integrity="<hash>"` into the inline <script> tag.
({_HtmlEdit edit, String hash})? _inlineScriptStampEdit({
  required String html,
  required Element element,
  required String algorithm,
}) {
  if (element.attributes.containsKey('src')) {
    return null;
  }
  if (element.attributes.containsKey('integrity')) {
    return null;
  }
  final FileSpan? span = element.sourceSpan;
  if (span == null) {
    return null;
  }
  // Empty `<script></script>` we don't want to generate any hashes for those.
  if (element.nodes.isEmpty) {
    return null;
  }
  final FileSpan? bodySpan = element.nodes.first.sourceSpan;
  if (bodySpan == null) {
    return null;
  }
  final String content = html.substring(
      bodySpan.start.offset, bodySpan.end.offset);
  if (content.isEmpty) {
    return null;
  }
  final String hash = generateIntegrityHash(
      utf8.encode(content), algorithm: algorithm);
  // [span.end.offset] points one past the trailing `>` of the start tag.
  // Insert before that `>`.
  int insertAt = span.end.offset - 1;
  if (insertAt > span.start.offset && html[insertAt - 1] == '/') {
    insertAt -= 1;
  }
  // Strip a redundant leading space when the original tag already has
  // whitespace before the closing `>` (so `<script type="module" >` stays single-
  // spaced after we splice in `integrity`).
  final bool needsLeadingSpace = insertAt == 0 ||
      !_isHtmlWhitespace(html.codeUnitAt(insertAt - 1));
  final attrs = StringBuffer();
  if (needsLeadingSpace) {
    attrs.write(' ');
  }
  attrs.write('integrity="$hash"');

  // Deliberately insert no `crossorigin` attribute here — inline scripts are
  // not fetched for inline scripts so the attribute would be meaningless.
  return (edit: _HtmlEdit(insertAt, attrs.toString()), hash: hash);
}

/// Returns an edit that prepends the [importMapTag] and [integrityMapScriptTag]
/// after the opening `<base>` or the `<head>` tag if there is no `<base<` tag.
///
/// Returns null when the document has no parseable `<head>` tag.
_HtmlEdit? _headPrependEdit({
  required Document doc,
  required String importMapTag,
  required String integrityMapScriptTag,
}) {
  final Element? base = doc.querySelector('base');
  final FileSpan? baseSpan = base?.sourceSpan;
  final Element? head = doc.querySelector('head');
  final FileSpan? headSpan = head?.sourceSpan;
  if (headSpan == null) {
    return null;
  }
  final List<Element> existingScripts = doc.querySelectorAll('script');
  final bool importmapPresent =
      importMapTag.isEmpty ||
          existingScripts.any(
                (Element s) =>
            (s.attributes['type'] ?? '').toLowerCase() == 'importmap',
          );
  final bool integrityMapScriptPresent =
      integrityMapScriptTag.isEmpty ||
          existingScripts.any((Element s) =>
              s.text.contains('window._flutter.integrityMap'));
  if (importmapPresent && integrityMapScriptPresent) {
    return null;
  }

  final block = StringBuffer();
  if (!importmapPresent) {
    block.write('\n');
    block.write(importMapTag);
  }
  if (!integrityMapScriptPresent) {
    block.write('\n');
    block.write(integrityMapScriptTag);
  }
  return _HtmlEdit(
    baseSpan?.end.offset ?? headSpan.end.offset,
    block.toString(),
  );
}

/// Returns the integrity entry for a same-origin URL relative to the output
/// directory of the build.
String? _resolveIntegrity({
  required String url,
  required Directory htmlFileDir,
  required Directory outputDir,
  required Map<String, String> integrityMap,
  required FileSystem fileSystem,
}) {
  if (url.startsWith('data:') || url.startsWith('blob:')) {
    // Ignore data: and blob: URLs — they are out of scope for SRI.
    return null;
  }
  final Uri parsed;
  try {
    parsed = Uri.parse(url);
  } on FormatException {
    return null;
  }
  // Only generate SRI for same-origin URLs.
  // Absolute http(s) URLs are out of scope here — applications should bring
  // their own SRI for vendor-hosted assets.
  if (parsed.hasScheme && parsed.scheme != 'file') {
    return null;
  }

  String relative = parsed.path;
  if (relative.startsWith('/')) {
    relative = relative.substring(1);
  } else {
    // Resolve a relative URL against the directory containing index.html.
    final String indexDir = fileSystem.path
        .relative(htmlFileDir.path, from: outputDir.path)
        .replaceAll(r'\', '/');
    if (indexDir.isNotEmpty && indexDir != '.') {
      relative = '$indexDir/$relative';
    }
  }
  relative = relative.replaceAll(r'\', '/');
  return integrityMap[relative] ?? integrityMap[relative
      .split('/')
      .last];
}

/// HTML5 whitespace per the spec: tab, LF, FF, CR, space.
bool _isHtmlWhitespace(int codeUnit) =>
    codeUnit == 0x09 ||
        codeUnit == 0x0a ||
        codeUnit == 0x0c ||
        codeUnit == 0x0d ||
        codeUnit == 0x20;

crypto.Hash _digestForAlgorithm(String algo) {
  switch (algo) {
    case 'sha256':
      return crypto.sha256;
    case 'sha384':
      return crypto.sha384;
    case 'sha512':
      return crypto.sha512;
    default:
      throw ArgumentError.value(algo, 'algo', 'Unsupported SRI algorithm');
  }
}

String _formatIntegrity(
    {required String algorithm, required crypto.Digest digest}) =>
    '$algorithm-${base64.encode(digest.bytes)}';
