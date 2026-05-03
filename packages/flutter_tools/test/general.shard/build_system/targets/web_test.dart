// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:file_testing/file_testing.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/depfile.dart';
import 'package:flutter_tools/src/build_system/targets/web.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/isolated/mustache_template.dart';
import 'package:flutter_tools/src/web/compile.dart';
import 'package:flutter_tools/src/web/file_generators/flutter_service_worker_js.dart';
import 'package:flutter_tools/src/web_template.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../../../src/common.dart';
import '../../../src/fake_process_manager.dart';
import '../../../src/package_config.dart';
import '../../../src/testbed.dart';
import '../../../src/throwing_pub.dart';

const _kDart2jsLinuxArgs = <String>[
  'Artifact.engineDartBinary.TargetPlatform.web_javascript',
  'compile',
  'js',
  '--platform-binaries=HostArtifact.webPlatformKernelFolder',
  '--invoker=flutter_tool',
];

const _kStandardFlutterWebDefines = <String>[
  '-DFLUTTER_WEB_USE_SKIA=true',
  '-DFLUTTER_WEB_USE_SKWASM=false',
  '-DFLUTTER_WEB_CANVASKIT_URL=https://www.gstatic.com/flutter-canvaskit/abcdefghijklmnopqrstuvwxyz/',
];

const _kDart2WasmLinuxArgs = <String>[
  'Artifact.engineDartBinary.TargetPlatform.web_javascript',
  'compile',
  'wasm',
  '--packages=/.dart_tool/package_config.json',
  '--extra-compiler-option=--platform=HostArtifact.webPlatformKernelFolder/dart2wasm_platform.dill',
];

void main() {
  late TestBed testbed;
  late Environment environment;
  late FakeProcessManager processManager;

  final Platform linux = FakePlatform(environment: <String, String>{});
  final Platform windows = FakePlatform(
    operatingSystem: 'windows',
    environment: <String, String>{},
  );

  setUp(() {
    testbed = TestBed(
      setup: () {
        globals.fs.currentDirectory.childFile('pubspec.yaml').writeAsStringSync('''
name: foo
''');

        writePackageConfigFiles(
          directory: globals.fs.currentDirectory,
          mainLibName: 'my_app',
          packages: <String, String>{'foo': 'foo/'},
          languageVersions: <String, String>{'foo': '2.7'},
        );
        globals.fs.currentDirectory.childDirectory('bar').createSync();
        processManager = FakeProcessManager.empty();
        globals.fs
            .file('bin/cache/flutter_web_sdk/flutter_js/flutter.js')
            .createSync(recursive: true);

        environment = Environment.test(
          globals.fs.currentDirectory,
          projectDir: globals.fs.currentDirectory.childDirectory('foo'),
          outputDir: globals.fs.currentDirectory.childDirectory('bar'),
          defines: <String, String>{
            kTargetFile: globals.fs.path.join('foo', 'lib', 'main.dart'),
            kBuildMode: BuildMode.debug.cliName,
          },
          artifacts: Artifacts.test(),
          processManager: processManager,
          logger: globals.logger,
          fileSystem: globals.fs,
        );
        environment.buildDir.createSync(recursive: true);
      },
      overrides: <Type, Generator>{Platform: () => linux},
    );
  });

  test(
    'WebEntrypointTarget generates an entrypoint with plugins and init platform',
    () => testbed.run(
      () async {
        final File mainFile = globals.fs.file(globals.fs.path.join('foo', 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}');
        environment.defines[kTargetFile] = mainFile.path;
        environment.defines[kHasWebPlugins] = 'true';
        await const WebEntrypointTarget().build(environment);

        final String generated = environment.buildDir.childFile('main.dart').readAsStringSync();

        // Plugins
        expect(generated, contains("import 'web_plugin_registrant.dart' as pluginRegistrant;"));
        expect(generated, contains('pluginRegistrant.registerPlugins();'));

        // Import.
        expect(generated, contains("import 'package:foo/main.dart' as entrypoint;"));

        // Main
        expect(generated, contains('ui_web.bootstrapEngine('));
        expect(generated, contains('entrypoint.main as _'));
      },
      overrides: <Type, Generator>{
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        Pub: ThrowingPub.new,
      },
    ),
  );

  test(
    'version.json is created after release build',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('index.html').createSync(recursive: true);
      environment.buildDir.childFile('main.dart.js').createSync();
      await WebReleaseBundle(<WebCompilerConfig>[
        const JsCompilerConfig(),
      ], const NoOpAnalytics()).build(environment);

      expect(environment.outputDir.childFile('version.json'), exists);
    }),
  );

  test(
    'override version values',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      environment.defines[kBuildName] = '2.0.0';
      environment.defines[kBuildNumber] = '22';
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('index.html').createSync(recursive: true);
      environment.buildDir.childFile('main.dart.js').createSync();
      await WebReleaseBundle(<WebCompilerConfig>[
        const JsCompilerConfig(),
      ], const NoOpAnalytics()).build(environment);

      final String versionFile = environment.outputDir.childFile('version.json').readAsStringSync();
      expect(versionFile, contains('"version":"2.0.0"'));
      expect(versionFile, contains('"build_number":"22"'));
    }),
  );

  test(
    'Base href is created in index.html with given base-href after release build',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      environment.defines[kBaseHref] = '/basehreftest/';
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('index.html').createSync(recursive: true);
      webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><base href="$kBaseHrefPlaceholder"><head></head></html>
    ''');
      environment.buildDir.childFile('main.dart.js').createSync();
      await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

      expect(
        environment.outputDir.childFile('index.html').readAsStringSync(),
        contains('/basehreftest/'),
      );
    }),
  );

  test(
    'WebTemplatedFiles emits useLocalCanvasKit in flutter_bootstrap.js when environment specifies',
    () => testbed.run(() async {
      environment.defines[kUseLocalCanvasKitFlag] = 'true';
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('index.html').createSync(recursive: true);
      webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><base href="$kBaseHrefPlaceholder"><head></head></html>
    ''');
      environment.buildDir.childFile('main.dart.js').createSync();
      await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

      expect(
        environment.outputDir.childFile('flutter_bootstrap.js').readAsStringSync(),
        contains('"useLocalCanvasKit":true'),
      );
    }),
  );

  test(
    'WebTemplatedFiles includes serviceWorkerSettings in flutter_bootstrap.js by default',
    () => testbed.run(() async {
      final Directory webResources = environment.projectDir.childDirectory('web');
      environment.defines[kServiceWorkerStrategy] = 'none';
      webResources.childFile('index.html').createSync(recursive: true);
      environment.buildDir.childFile('main.dart.js').createSync();
      await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

      expect(
        environment.outputDir.childFile('flutter_bootstrap.js').readAsStringSync(),
        contains('_flutter.loader.load();'),
      );
    }),
  );

  test(
    'WebTemplatedFiles omits serviceWorkerSettings in flutter_bootstrap.js when environment specifies',
    () => testbed.run(() async {
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('index.html').createSync(recursive: true);
      environment.buildDir.childFile('main.dart.js').createSync();
      await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

      expect(
        environment.outputDir.childFile('flutter_bootstrap.js').readAsStringSync(),
        stringContainsInOrder(<String>[
          '_flutter.loader.load({',
          'serviceWorkerSettings',
          'serviceWorkerVersion',
        ]),
      );
    }),
  );

  test(
    'null base href does not override existing base href in index.html',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('index.html').createSync(recursive: true);
      webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href='/basehreftest/'></head></html>
    ''');
      environment.buildDir.childFile('main.dart.js').createSync();
      await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

      expect(
        environment.outputDir.childFile('index.html').readAsStringSync(),
        contains('/basehreftest/'),
      );
    }),
  );

  group('--sri', () {
    String expectedIntegrity(List<int> bytes, {String algo = 'sha384'}) {
      final crypto.Hash hash = switch (algo) {
        'sha256' => crypto.sha256,
        'sha384' => crypto.sha384,
        'sha512' => crypto.sha512,
        _ => throw ArgumentError(algo),
      };
      return '$algo-${base64.encode(hash.convert(bytes).bytes)}';
    }

    Future<void> runFullPipeline() async {
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('index.html').createSync(recursive: true);
      webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="$kBaseHrefPlaceholder">
<script src="flutter_bootstrap.js" async></script>
</head><body></body></html>
''');
      environment.buildDir.childFile('main.dart.js').createSync();
      environment.buildDir.childFile('main.dart.js').writeAsStringSync(
        '// fake main.dart.js\n',
      );

      await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);
      await WebReleaseBundle(<WebCompilerConfig>[
        const JsCompilerConfig(),
      ], const NoOpAnalytics()).build(environment);
      await WebIntegrity(globals.fs, <WebCompilerConfig>[
        const JsCompilerConfig(),
      ], const NoOpAnalytics()).build(environment);
    }

    test(
      'WebIntegrity is a no-op when SRI is disabled',
      () => testbed.run(() async {
        await runFullPipeline();
        expect(
          environment.outputDir.childFile('integrity_manifest.json').existsSync(),
          isFalse,
        );
        final String html = environment.outputDir.childFile('index.html').readAsStringSync();
        expect(html, isNot(contains('integrity=')));
        expect(html, isNot(contains('type="importmap"')));
        expect(html, isNot(contains("type='importmap'")));
      }),
    );

    test(
      'WebIntegrity injects SRI on <script src=flutter_bootstrap.js> when --sri is on',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        environment.defines[kSriAlgorithm] = 'sha384';
        await runFullPipeline();

        final File bootstrap = environment.outputDir.childFile('flutter_bootstrap.js');
        expect(bootstrap.existsSync(), isTrue);
        final String expectedHash = expectedIntegrity(bootstrap.readAsBytesSync());
        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();
        expect(html, contains('integrity="$expectedHash"'));
        expect(html, contains('crossorigin="anonymous"'));
      }),
    );

    test(
      'WebIntegrity injects <script type="importmap"> with module integrity',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        environment.defines[kSriAlgorithm] = 'sha384';
        await runFullPipeline();

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();
        final List<RegExpMatch> matches = RegExp(
          r'<script[^>]*type="importmap"',
          caseSensitive: false,
        ).allMatches(html).toList();
        expect(matches, hasLength(1));

        // The map is anchored at the very top of <head>, before any other
        // <script>/<link> tag, so it is parsed before any module load.
        final int importMapIdx = html.indexOf(
          RegExp(r'<script[^>]*type="importmap"', caseSensitive: false),
        );
        final int firstScriptIdx = html.indexOf(
          RegExp(r'<script\s+src=', caseSensitive: false),
        );
        expect(
          importMapIdx,
          lessThan(firstScriptIdx),
          reason: 'import map must precede any module-loading script',
        );

        // Extract the JSON body and verify it carries the same hash for
        // main.dart.js as the engine-side `_flutter.buildConfig.integrity`.
        final RegExpMatch? body = RegExp(
          r'<script[^>]*type="importmap"[^>]*>(.+?)</script>',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(html);
        expect(body, isNotNull);
        final Map<String, Object?> decoded =
            jsonDecode(body!.group(1)!) as Map<String, Object?>;
        final Map<String, Object?> integrityMap =
            decoded['integrity']! as Map<String, Object?>;
        expect(integrityMap, contains('main.dart.js'));
        expect(integrityMap, contains('flutter_bootstrap.js'));
        expect(integrityMap['main.dart.js'], startsWith('sha384-'));
      }),
    );

    test(
      'WebIntegrity is idempotent — re-running does not double-inject the import map',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        await runFullPipeline();
        // Second pass on the same output dir.
        await WebIntegrity(globals.fs, <WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();
        final int matches = RegExp(
          r'<script[^>]*type="importmap"',
          caseSensitive: false,
        ).allMatches(html).length;
        expect(matches, equals(1));
      }),
    );

    test(
      'WebIntegrity injects inline window._flutter.integrityMap script',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        await runFullPipeline();

        final String html = environment.outputDir
            .childFile('index.html')
            .readAsStringSync();
        expect(html, contains('window._flutter.integrityMap = '));
        expect(html, contains('"sameOrigin":'));
        expect(html, contains('"main.dart.js":"sha384-'));
        // The integrity map covers flutter_bootstrap.js itself, because the
        // single-pass design hashes its on-disk bytes directly.
        expect(html, contains('"flutter_bootstrap.js":"sha384-'));
        // Engine reads from window._flutter.integrityMap (NOT from the
        // bootstrap's _flutter.buildConfig.integrity).
        final String bootstrap = environment.outputDir
            .childFile('flutter_bootstrap.js')
            .readAsStringSync();
        expect(bootstrap, isNot(contains('"integrity":')));
      }),
    );

    test(
      'inline integrityMap script runs before flutter_bootstrap.js',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        await runFullPipeline();

        final String html = environment.outputDir
            .childFile('index.html')
            .readAsStringSync();
        final int integrityIdx = html.indexOf('window._flutter.integrityMap');
        final int bootstrapIdx = html.indexOf(
          RegExp(r'<script\s+[^>]*src="flutter_bootstrap\.js"',
              caseSensitive: false),
        );
        expect(integrityIdx, isNonNegative);
        expect(bootstrapIdx, isNonNegative);
        expect(
          integrityIdx,
          lessThan(bootstrapIdx),
          reason: 'The integrity map must be visible to the engine loader '
              'before the bootstrap kicks off main.dart.js loading.',
        );
      }),
    );

    test(
      'WebIntegrity emits an integrity_manifest.json sidecar',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        environment.defines[kSriAlgorithm] = 'sha512';
        await runFullPipeline();

        final File manifest =
            environment.outputDir.childFile('integrity_manifest.json');
        expect(manifest.existsSync(), isTrue);
        final Map<String, Object?> decoded =
            jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
        expect(decoded['algorithm'], equals('sha512'));
        final Map<String, Object?> sameOrigin =
            decoded['sameOrigin']! as Map<String, Object?>;
        expect(sameOrigin, contains('main.dart.js'));
        expect(sameOrigin, contains('flutter_bootstrap.js'));
      }),
    );

    test(
      'IntegrityConfig.fromDefines reads SRI knobs out of Environment.defines',
      () {
        const IntegrityConfig disabled = IntegrityConfig.disabled;
        expect(disabled.enabled, isFalse);

        final IntegrityConfig fromDefinesOff =
            IntegrityConfig.fromDefines(<String, String>{});
        expect(fromDefinesOff.enabled, isFalse);

        final IntegrityConfig fromDefinesOn =
            IntegrityConfig.fromDefines(<String, String>{
          kSriEnabled: 'true',
        });
        expect(fromDefinesOn.enabled, isTrue);
        expect(fromDefinesOn.algorithm, equals('sha384'));

        final IntegrityConfig withAlgo =
            IntegrityConfig.fromDefines(<String, String>{
          kSriEnabled: 'true',
          kSriAlgorithm: 'sha512',
        });
        expect(withAlgo.algorithm, equals('sha512'));
      },
    );

    test(
      'WebIntegrity preserves single-quoted attributes when stamping',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        // Single-quoted src — the regex-based stamper used to copy whatever
        // quote style it found; the parse-based one always emits double
        // quotes for the new attributes but must not touch the existing
        // src=' …' bytes.
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="$kBaseHrefPlaceholder">
<script src='flutter_bootstrap.js' async></script>
</head><body></body></html>
''');
        environment.buildDir.childFile('main.dart.js').createSync();
        environment.buildDir.childFile('main.dart.js').writeAsStringSync('// fake\n');

        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);
        await WebReleaseBundle(<WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);
        await WebIntegrity(globals.fs, <WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();
        // Original src kept its single quotes …
        expect(html, contains("src='flutter_bootstrap.js'"));
        // … and the new attributes were inserted as double-quoted.
        expect(html, contains('integrity="sha384-'));
        expect(html, contains('crossorigin="anonymous"'));
      }),
    );

    test(
      'WebIntegrity does not double-stamp tags that already have integrity',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        // User has hand-stamped a fake integrity (e.g. for a vendored
        // bootstrap) — we must leave it alone.
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="$kBaseHrefPlaceholder">
<script src="flutter_bootstrap.js" integrity="sha384-USERSUPPLIED" async></script>
</head><body></body></html>
''');
        environment.buildDir.childFile('main.dart.js').createSync();
        environment.buildDir.childFile('main.dart.js').writeAsStringSync('// fake\n');

        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);
        await WebReleaseBundle(<WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);
        await WebIntegrity(globals.fs, <WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();
        expect(html, contains('integrity="sha384-USERSUPPLIED"'));
        // The hand-stamped <script src> is left untouched: exactly one
        // `integrity="…"` on it (no second one spliced in).
        final RegExpMatch? bootstrapTag = RegExp(
          r'<script\b[^>]*src="flutter_bootstrap\.js"[^>]*>',
          caseSensitive: false,
        ).firstMatch(html);
        expect(bootstrapTag, isNotNull);
        final int integrityCount =
            'integrity='.allMatches(bootstrapTag!.group(0)!).length;
        expect(integrityCount, equals(1),
            reason: 'auto-stamping must skip tags that already have integrity');
      }),
    );

    test(
      'WebIntegrity skips link rels we do not protect (e.g. icon)',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        // We hash icon.png (it's a wasm-extension match would be wrong here;
        // .css is hashed, .png is not). The point is: even if the file were
        // hashable, `<link rel="icon">` is not an SRI-protected rel.
        webResources.childFile('icon.css').createSync(recursive: true);
        webResources.childFile('icon.css').writeAsStringSync('body{}\n');
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="$kBaseHrefPlaceholder">
<link rel="icon" href="icon.css">
<link rel="stylesheet" href="icon.css">
<script src="flutter_bootstrap.js" async></script>
</head><body></body></html>
''');
        environment.buildDir.childFile('main.dart.js').createSync();
        environment.buildDir.childFile('main.dart.js').writeAsStringSync('// fake\n');

        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);
        await WebReleaseBundle(<WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);
        await WebIntegrity(globals.fs, <WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();
        // The stylesheet got stamped, the icon did not.
        final RegExpMatch? iconLink =
            RegExp(r'<link\b[^>]*rel="icon"[^>]*>').firstMatch(html);
        expect(iconLink, isNotNull);
        expect(iconLink!.group(0), isNot(contains('integrity=')));
        final RegExpMatch? styleLink =
            RegExp(r'<link\b[^>]*rel="stylesheet"[^>]*>').firstMatch(html);
        expect(styleLink, isNotNull);
        expect(styleLink!.group(0), contains('integrity="sha384-'));
      }),
    );

    test(
      'WebIntegrity stamps integrity on the injected importmap and integrityMap script',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        environment.defines[kSriAlgorithm] = 'sha384';
        await runFullPipeline();

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();

        String hashOf(String body) {
          final crypto.Digest d = crypto.sha384.convert(utf8.encode(body));
          return 'sha384-${base64.encode(d.bytes)}';
        }

        // The importmap tag carries an integrity matching its own JSON body.
        final RegExpMatch? importMapMatch = RegExp(
          r'<script[^>]*type="importmap"[^>]*integrity="([^"]+)"[^>]*>(.+?)</script>',
          dotAll: true,
        ).firstMatch(html);
        expect(importMapMatch, isNotNull,
            reason: 'importmap must be stamped with `integrity`');
        expect(importMapMatch!.group(1), equals(hashOf(importMapMatch.group(2)!)));

        // The integrityMap script is stamped too.
        final RegExpMatch? integrityScriptMatch = RegExp(
          r'<script integrity="([^"]+)">(window\._flutter[^<]*)</script>',
        ).firstMatch(html);
        expect(integrityScriptMatch, isNotNull,
            reason: 'integrityMap script must be stamped with `integrity`');
        expect(
          integrityScriptMatch!.group(1),
          equals(hashOf(integrityScriptMatch.group(2)!)),
        );
      }),
    );

    test(
      'WebIntegrity stamps integrity on user-authored inline <script>',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        environment.defines[kSriAlgorithm] = 'sha384';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="$kBaseHrefPlaceholder">
<script>console.log("hello, world");</script>
<script src="flutter_bootstrap.js" async></script>
</head><body></body></html>
''');
        environment.buildDir.childFile('main.dart.js').createSync();
        environment.buildDir.childFile('main.dart.js').writeAsStringSync('// fake\n');

        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);
        await WebReleaseBundle(<WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);
        await WebIntegrity(globals.fs, <WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();

        const String body = 'console.log("hello, world");';
        final crypto.Digest d = crypto.sha384.convert(utf8.encode(body));
        final String expected = 'sha384-${base64.encode(d.bytes)}';
        expect(
          html,
          contains('<script integrity="$expected">$body</script>'),
        );

        // …and the same hash makes it into the manifest's `inlineScripts`.
        final Map<String, Object?> manifest = jsonDecode(
          environment.outputDir
              .childFile('integrity_manifest.json')
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final List<Object?> inlineScripts =
            manifest['inlineScripts']! as List<Object?>;
        expect(inlineScripts, contains(expected));
        // The two framework-injected inline scripts (importmap +
        // _flutter.integrityMap) are also recorded.
        expect(inlineScripts.length, greaterThanOrEqualTo(3));
      }),
    );

    test(
      'WebIntegrity does not double-stamp inline <script integrity="…">',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="$kBaseHrefPlaceholder">
<script integrity="sha384-USERSUPPLIED">/* hand-pinned */</script>
<script src="flutter_bootstrap.js" async></script>
</head><body></body></html>
''');
        environment.buildDir.childFile('main.dart.js').createSync();
        environment.buildDir.childFile('main.dart.js').writeAsStringSync('// fake\n');

        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);
        await WebReleaseBundle(<WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);
        await WebIntegrity(globals.fs, <WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();
        // The hand-pinned tag survives untouched: the start tag still has
        // exactly one `integrity="…"` and it's the user's value.
        final RegExpMatch? userOpen = RegExp(
          r'<script[^>]*integrity="sha384-USERSUPPLIED"[^>]*>',
        ).firstMatch(html);
        expect(userOpen, isNotNull,
            reason: 'auto-stamping must skip inline scripts that already '
                'carry an `integrity` attribute');
        expect(
          'integrity='.allMatches(userOpen!.group(0)!).length,
          equals(1),
        );
        // And the body and closing tag are still in place.
        expect(html, contains('/* hand-pinned */</script>'));
      }),
    );

    test(
      'WebIntegrity skips empty inline <script></script>',
      () => testbed.run(() async {
        environment.defines[kSriEnabled] = 'true';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="$kBaseHrefPlaceholder">
<script></script>
<script src="flutter_bootstrap.js" async></script>
</head><body></body></html>
''');
        environment.buildDir.childFile('main.dart.js').createSync();
        environment.buildDir.childFile('main.dart.js').writeAsStringSync('// fake\n');

        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);
        await WebReleaseBundle(<WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);
        await WebIntegrity(globals.fs, <WebCompilerConfig>[
          const JsCompilerConfig(),
        ], const NoOpAnalytics()).build(environment);

        final String html =
            environment.outputDir.childFile('index.html').readAsStringSync();
        // The empty script remains exactly `<script></script>` — no integrity
        // attribute (CSP doesn't allow inline-script hashes for empty bodies
        // and stamping would just be noise).
        expect(html, contains('<script></script>'));
      }),
    );
  });

  group('--static-assets-url', () {
    test(
      'WebTemplatedFiles replaces placeholder with given value',
      () => testbed.run(() async {
        environment.defines[kStaticAssetsUrl] = 'https://static.example.com/example-app/';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><body><script>const staticAssetsUrl = "$kStaticAssetsUrlPlaceholder";</script></body></html>
    ''');
        environment.buildDir.childFile('main.dart.js').createSync();
        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

        expect(
          environment.outputDir.childFile('index.html').readAsStringSync(),
          contains('https://static.example.com/example-app/'),
        );
      }),
    );

    test(
      'WebTemplatedFiles replaces placeholder with / when not set',
      () => testbed.run(() async {
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><body><script>const staticAssetsUrl = "$kStaticAssetsUrlPlaceholder";</script></body></html>
    ''');
        environment.buildDir.childFile('main.dart.js').createSync();
        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

        expect(
          environment.outputDir.childFile('index.html').readAsStringSync(),
          contains('staticAssetsUrl = "/"'),
        );
      }),
    );
  });

  group('--web-define', () {
    test(
      'WebTemplatedFiles substitutes web-define variables in index.html',
      () => testbed.run(() async {
        environment.defines['${kWebDefinePrefix}VERSION'] = 'v1.2.3';
        environment.defines['${kWebDefinePrefix}API_URL'] = 'https://api.example.com';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="/"></head><body>
<script>
  const version = '{{VERSION}}';
  const apiUrl = '{{API_URL}}';
</script>
</body></html>
    ''');
        environment.buildDir.childFile('main.dart.js').createSync();
        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

        final String outputHtml = environment.outputDir.childFile('index.html').readAsStringSync();
        expect(outputHtml, contains("const version = 'v1.2.3'"));
        expect(outputHtml, contains("const apiUrl = 'https://api.example.com'"));
      }),
    );

    test(
      'WebTemplatedFiles substitutes web-define variables in flutter_bootstrap.js',
      () => testbed.run(() async {
        environment.defines['${kWebDefinePrefix}APP_VERSION'] = 'test-build-42';
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        webResources.childFile('flutter_bootstrap.js').createSync(recursive: true);
        webResources.childFile('flutter_bootstrap.js').writeAsStringSync('''
const appVersion = '{{APP_VERSION}}';
_flutter.loader.load();
''');
        environment.buildDir.childFile('main.dart.js').createSync();
        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

        final String outputBootstrap = environment.outputDir
            .childFile('flutter_bootstrap.js')
            .readAsStringSync();
        expect(outputBootstrap, contains("const appVersion = 'test-build-42'"));
      }),
    );

    test(
      'WebTemplatedFiles works with no web-define variables',
      () => testbed.run(() async {
        final Directory webResources = environment.projectDir.childDirectory('web');
        webResources.childFile('index.html').createSync(recursive: true);
        webResources.childFile('index.html').writeAsStringSync('''
<!DOCTYPE html><html><head><base href="/"></head><body></body></html>
    ''');
        environment.buildDir.childFile('main.dart.js').createSync();
        await WebTemplatedFiles(<Map<String, Object?>>[]).build(environment);

        expect(
          environment.outputDir.childFile('index.html').readAsStringSync(),
          contains('<base href="/">'),
        );
      }),
    );
  });

  test(
    'WebReleaseBundle copies dart2js output and resource files to output directory',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('foo.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('A');
      environment.buildDir.childFile('main.dart.js').createSync();
      environment.buildDir.childFile('main.dart.js.info.json').createSync();
      environment.buildDir.childFile('main.dart.js.map').createSync();
      environment.buildDir.childFile('main.dart.js_1.part.js').createSync();
      environment.buildDir.childFile('main.dart.js_1.part.js.map').createSync();

      await WebReleaseBundle(<WebCompilerConfig>[
        const JsCompilerConfig(dumpInfo: true),
      ], const NoOpAnalytics()).build(environment);

      expect(environment.outputDir.childFile('foo.txt').readAsStringSync(), 'A');
      expect(environment.outputDir.childFile('main.dart.js').existsSync(), true);
      expect(environment.outputDir.childFile('main.dart.js.info.json').existsSync(), true);
      expect(environment.outputDir.childFile('main.dart.js.map').existsSync(), true);
      expect(environment.outputDir.childFile('main.dart.js_1.part.js').existsSync(), true);
      expect(environment.outputDir.childFile('main.dart.js_1.part.js.map').existsSync(), true);
      expect(
        environment.outputDir
            .childDirectory('assets')
            .childFile('AssetManifest.bin.json')
            .existsSync(),
        true,
      );

      // Update to arbitrary resource file triggers rebuild.
      webResources.childFile('foo.txt').writeAsStringSync('B');

      await WebReleaseBundle(<WebCompilerConfig>[
        const JsCompilerConfig(),
      ], const NoOpAnalytics()).build(environment);

      expect(environment.outputDir.childFile('foo.txt').readAsStringSync(), 'B');
    }),
  );

  test(
    'WebReleaseBundle copies over output files when they change',
    () => testbed.run(() async {
      final Directory webResources = environment.projectDir.childDirectory('web');
      webResources.childFile('foo.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('A');

      environment.buildDir.childFile('main.dart.wasm')
        ..createSync()
        ..writeAsStringSync('old wasm');
      environment.buildDir.childFile('main.dart.mjs')
        ..createSync()
        ..writeAsStringSync('old mjs');
      await WebReleaseBundle(<WebCompilerConfig>[
        const WasmCompilerConfig(),
      ], const NoOpAnalytics()).build(environment);
      expect(environment.outputDir.childFile('main.dart.wasm').readAsStringSync(), 'old wasm');
      expect(environment.outputDir.childFile('main.dart.mjs').readAsStringSync(), 'old mjs');

      environment.buildDir.childFile('main.dart.wasm')
        ..createSync()
        ..writeAsStringSync('new wasm');
      environment.buildDir.childFile('main.dart.mjs')
        ..createSync()
        ..writeAsStringSync('new mjs');

      await WebReleaseBundle(<WebCompilerConfig>[
        const WasmCompilerConfig(),
      ], const NoOpAnalytics()).build(environment);

      expect(environment.outputDir.childFile('main.dart.wasm').readAsStringSync(), 'new wasm');
      expect(environment.outputDir.childFile('main.dart.mjs').readAsStringSync(), 'new mjs');
    }),
  );

  test(
    'WebEntrypointTarget generates an entrypoint for a file outside of main',
    () => testbed.run(
      () async {
        final File mainFile = globals.fs.file(globals.fs.path.join('other', 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}');
        environment.defines[kTargetFile] = mainFile.path;
        await const WebEntrypointTarget().build(environment);

        final String generated = environment.buildDir.childFile('main.dart').readAsStringSync();

        // Import.
        expect(generated, contains("import 'file:///other/lib/main.dart' as entrypoint;"));
      },
      overrides: <Type, Generator>{
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        Pub: ThrowingPub.new,
      },
    ),
  );

  test(
    'WebEntrypointTarget generates a plugin registrant for a file outside of main',
    () => testbed.run(
      () async {
        final File mainFile = globals.fs.file(globals.fs.path.join('other', 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}');
        environment.defines[kTargetFile] = mainFile.path;
        environment.defines[kHasWebPlugins] = 'true';
        await const WebEntrypointTarget().build(environment);

        final String generated = environment.buildDir.childFile('main.dart').readAsStringSync();

        // Import.
        expect(generated, contains("import 'file:///other/lib/main.dart' as entrypoint;"));
        expect(generated, contains("import 'web_plugin_registrant.dart' as pluginRegistrant;"));
      },
      overrides: <Type, Generator>{
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        Pub: ThrowingPub.new,
      },
    ),
  );

  test(
    'WebEntrypointTarget generates an entrypoint with plugins and init platform on windows',
    () => testbed.run(
      () async {
        final File mainFile = globals.fs.file(globals.fs.path.join('foo', 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}');
        environment.defines[kTargetFile] = mainFile.path;

        environment.defines[kHasWebPlugins] = 'true';
        await const WebEntrypointTarget().build(environment);

        final String generated = environment.buildDir.childFile('main.dart').readAsStringSync();

        // Plugins
        expect(generated, contains("import 'web_plugin_registrant.dart' as pluginRegistrant;"));
        expect(generated, contains('pluginRegistrant.registerPlugins();'));

        // Import.
        expect(generated, contains("import 'package:foo/main.dart' as entrypoint;"));

        // Main
        expect(generated, contains('ui_web.bootstrapEngine('));
        expect(generated, contains('entrypoint.main as _'));
      },
      overrides: <Type, Generator>{
        Platform: () => windows,
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        Pub: ThrowingPub.new,
      },
    ),
  );

  test(
    'WebEntrypointTarget generates an entrypoint without plugins and init platform',
    () => testbed.run(
      () async {
        final File mainFile = globals.fs.file(globals.fs.path.join('foo', 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}');
        environment.defines[kTargetFile] = mainFile.path;
        environment.defines[kHasWebPlugins] = 'false';
        await const WebEntrypointTarget().build(environment);

        final String generated = environment.buildDir.childFile('main.dart').readAsStringSync();

        // Plugins (the generated file is a noop)
        expect(generated, contains("import 'web_plugin_registrant.dart' as pluginRegistrant;"));
        expect(generated, contains('pluginRegistrant.registerPlugins();'));

        // Import.
        expect(generated, contains("import 'package:foo/main.dart' as entrypoint;"));

        // Main
        expect(generated, contains('ui_web.bootstrapEngine('));
        expect(generated, contains('entrypoint.main as _'));
      },
      overrides: <Type, Generator>{
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        Pub: ThrowingPub.new,
      },
    ),
  );

  test(
    'WebEntrypointTarget generates an entrypoint with a language version',
    () => testbed.run(
      () async {
        final File mainFile = globals.fs.file(globals.fs.path.join('foo', 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('// @dart=2.8\nvoid main() {}');
        environment.defines[kTargetFile] = mainFile.path;
        await const WebEntrypointTarget().build(environment);

        final String generated = environment.buildDir.childFile('main.dart').readAsStringSync();

        // Language version
        expect(generated, contains('// @dart=2.8'));
      },
      overrides: <Type, Generator>{
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        Pub: ThrowingPub.new,
      },
    ),
  );

  test(
    'WebEntrypointTarget generates an entrypoint with a language version from a package config',
    () => testbed.run(
      () async {
        final File mainFile = globals.fs.file(globals.fs.path.join('foo', 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}');
        globals.fs.file(globals.fs.path.join('pubspec.yaml')).writeAsStringSync('name: foo\n');
        environment.defines[kTargetFile] = mainFile.path;
        await const WebEntrypointTarget().build(environment);

        final String generated = environment.buildDir.childFile('main.dart').readAsStringSync();

        // Language version
        expect(generated, contains('// @dart=2.7'));
      },
      overrides: <Type, Generator>{
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        Pub: ThrowingPub.new,
      },
    ),
  );

  test(
    'WebEntrypointTarget generates an entrypoint without plugins and without init platform',
    () => testbed.run(
      () async {
        final File mainFile = globals.fs.file(globals.fs.path.join('foo', 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}');
        environment.defines[kTargetFile] = mainFile.path;
        environment.defines[kHasWebPlugins] = 'false';
        await const WebEntrypointTarget().build(environment);

        final String generated = environment.buildDir.childFile('main.dart').readAsStringSync();

        // Plugins
        expect(generated, contains("import 'web_plugin_registrant.dart' as pluginRegistrant;"));
        expect(generated, contains('pluginRegistrant.registerPlugins();'));

        // Import.
        expect(generated, contains("import 'package:foo/main.dart' as entrypoint;"));

        // Main
        expect(generated, contains('ui_web.bootstrapEngine('));
        expect(generated, contains('entrypoint.main as _'));
      },
      overrides: <Type, Generator>{
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        Pub: ThrowingPub.new,
      },
    ),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args with csp',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'profile';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.profile=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--no-minify',
        '--csp',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(csp: true, sourceMaps: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args with minify false',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.product=true',
        ..._kStandardFlutterWebDefines,
        '-O4',
        '--no-minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(minify: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget ignores frontend server starter path option when calling dart2js',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'profile';
      environment.defines[kFrontendServerStarterPath] = 'path/to/frontend_server_starter.dart';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.profile=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--no-minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(sourceMaps: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args with enabled experiment',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'profile';
      environment.defines[kExtraFrontEndOptions] = '--enable-experiment=non-nullable';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '--enable-experiment=non-nullable',
        '-Ddart.vm.profile=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--no-minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(sourceMaps: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args in profile mode',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'profile';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.profile=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--no-minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(sourceMaps: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args in release mode',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.product=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(sourceMaps: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args in release mode with native null assertions',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.product=true',
        ..._kStandardFlutterWebDefines,
        '--native-null-assertions',
        '--no-source-maps',
        '-O4',
        '--minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(
        const JsCompilerConfig(nativeNullAssertions: true, sourceMaps: false),
      ).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args in release with dart2js optimization override',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.product=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O3',
        '--minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(
        const JsCompilerConfig(optimizationLevel: 3, sourceMaps: false),
      ).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget produces expected depfile',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.product=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
          onRun: (_) {
            environment.buildDir.childFile('app.dill.deps').writeAsStringSync('file:///a.dart');
          },
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(sourceMaps: false)).build(environment);

      expect(environment.buildDir.childFile('dart2js.d'), exists);
      final Depfile depfile = environment.depFileService.parse(
        environment.buildDir.childFile('dart2js.d'),
      );

      expect(depfile.inputs.single.path, globals.fs.path.absolute('a.dart'));
      expect(
        depfile.outputs.single.path,
        environment.buildDir.childFile('main.dart.js').absolute.path,
      );
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with Dart defines in release mode',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      environment.defines[kDartDefines] = encodeDartDefines(<String>['FOO=bar', 'BAZ=qux']);
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.product=true',
        '-DFOO=bar',
        '-DBAZ=qux',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(sourceMaps: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget can enable source maps',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'release';
      environment.defines[WebCompilerConfig.kSourceMapsEnabled] = 'true';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.product=true',
        ..._kStandardFlutterWebDefines,
        '-O4',
        '--minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig()).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with Dart defines in profile mode',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'profile';
      environment.defines[kDartDefines] = encodeDartDefines(<String>['FOO=bar', 'BAZ=qux']);
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.profile=true',
        '-DFOO=bar',
        '-DBAZ=qux',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--no-minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(sourceMaps: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with Dart defines in debug mode',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'debug';
      environment.defines[kDartDefines] = encodeDartDefines(<String>['FOO=bar', 'BAZ=qux']);
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-DFOO=bar',
        '-DBAZ=qux',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '--enable-asserts',
        '-O1',
        '--no-minify',
        '-o',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(const JsCompilerConfig(sourceMaps: false)).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args with dump-info',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'profile';
      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.profile=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--no-minify',
      ];
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            '-o',
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            '--stage=dump-info-all',
            '-o',
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(
        const JsCompilerConfig(dumpInfo: true, sourceMaps: false),
      ).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  test(
    'Dart2JSTarget calls dart2js with expected args with no-frequency-based-minification',
    () => testbed.run(() async {
      environment.defines[kBuildMode] = 'profile';

      final common = <String>[
        ..._kDart2jsLinuxArgs,
        '-Ddart.vm.profile=true',
        ..._kStandardFlutterWebDefines,
        '--no-source-maps',
        '-O4',
        '--no-minify',
        '--no-frequency-based-minification',
        '-o',
      ];

      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('app.dill').absolute.path,
            '--packages=/.dart_tool/package_config.json',
            '--cfe-only',
            environment.buildDir.childFile('main.dart').absolute.path,
          ],
        ),
      );
      processManager.addCommand(
        FakeCommand(
          command: <String>[
            ...common,
            environment.buildDir.childFile('main.dart.js').absolute.path,
            environment.buildDir.childFile('app.dill').absolute.path,
          ],
        ),
      );

      await Dart2JSTarget(
        const JsCompilerConfig(useFrequencyBasedMinification: false, sourceMaps: false),
      ).build(environment);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
  );

  for (final renderer in <WebRendererMode>[WebRendererMode.canvaskit, WebRendererMode.skwasm]) {
    for (final level in <int?>[null, 0, 1, 2, 3, 4]) {
      for (final strip in <bool>[true, false]) {
        for (final defines in const <List<String>>[
          <String>[],
          <String>['FOO=bar', 'BAZ=qux'],
        ]) {
          for (final buildMode in const <String>['profile', 'release', 'debug']) {
            for (final sourceMaps in const <bool>[true, false]) {
              for (final minify in const <bool>[true, false]) {
                test(
                  'Dart2WasmTarget invokes dart2wasm with renderer=$renderer, -O$level, stripping=$strip, defines=$defines, modeMode=$buildMode sourceMaps=$sourceMaps minify=$minify',
                  () => testbed.run(() async {
                    final int expectedLevel =
                        level ??
                        switch (buildMode) {
                          'debug' => 0,
                          'profile' || 'release' => 2,
                          _ => throw UnimplementedError(),
                        };
                    environment.defines[kBuildMode] = buildMode;
                    environment.defines[kDartDefines] = encodeDartDefines(defines);

                    final File depFile = environment.buildDir.childFile('dart2wasm.d');

                    final File outputJsFile = environment.buildDir.childFile('main.dart.mjs');
                    processManager.addCommand(
                      FakeCommand(
                        command: <String>[
                          ..._kDart2WasmLinuxArgs,
                          '-Ddart.vm.profile=${buildMode == 'profile'}',
                          '-Ddart.vm.product=${buildMode == 'release'}',
                          if (buildMode != 'debug') ...<String>[
                            '--extra-compiler-option=--delete-tostring-package-uri=dart:ui',
                            '--extra-compiler-option=--delete-tostring-package-uri=package:flutter',
                          ],
                          if (renderer == WebRendererMode.skwasm) ...<String>[
                            '--extra-compiler-option=--import-shared-memory',
                            '--extra-compiler-option=--shared-memory-max-pages=32768',
                          ],
                          ...defines.map((String define) => '-D$define'),
                          if (renderer == WebRendererMode.skwasm) ...<String>[
                            '-DFLUTTER_WEB_USE_SKIA=false',
                            '-DFLUTTER_WEB_USE_SKWASM=true',
                          ],
                          if (renderer == WebRendererMode.canvaskit) ...<String>[
                            '-DFLUTTER_WEB_USE_SKIA=true',
                            '-DFLUTTER_WEB_USE_SKWASM=false',
                          ],
                          '-DFLUTTER_WEB_CANVASKIT_URL=https://www.gstatic.com/flutter-canvaskit/abcdefghijklmnopqrstuvwxyz/',
                          '--extra-compiler-option=--depfile=${depFile.absolute.path}',
                          '-O$expectedLevel',
                          if (strip && buildMode == 'release')
                            '--strip-wasm'
                          else
                            '--no-strip-wasm',
                          if (!sourceMaps) '--no-source-maps',
                          if (minify) '--minify' else '--no-minify',
                          if (buildMode == 'debug') '--extra-compiler-option=--enable-asserts',
                          '-o',
                          environment.buildDir.childFile('main.dart.wasm').absolute.path,
                          environment.buildDir.childFile('main.dart').absolute.path,
                        ],
                        onRun: (_) => outputJsFile
                          ..createSync()
                          ..writeAsStringSync('foo'),
                      ),
                    );

                    await Dart2WasmTarget(
                      WasmCompilerConfig(
                        optimizationLevel: level,
                        stripWasm: strip,
                        renderer: renderer,
                        sourceMaps: sourceMaps,
                        minify: minify,
                      ),
                      const NoOpAnalytics(),
                    ).build(environment);

                    expect(outputJsFile.existsSync(), isTrue);
                  }, overrides: <Type, Generator>{ProcessManager: () => processManager}),
                );
              }
            }
          }
        }
      }
    }
  }

  test('Dart2JSTarget has unique build keys for compiler configurations', () {
    const testConfigs = <JsCompilerConfig>[
      // Default values
      JsCompilerConfig(),

      // Each individual property being made non-default
      JsCompilerConfig(csp: true),
      JsCompilerConfig(dumpInfo: true),
      JsCompilerConfig(nativeNullAssertions: true),
      JsCompilerConfig(optimizationLevel: 0),
      JsCompilerConfig(useFrequencyBasedMinification: false),
      JsCompilerConfig(sourceMaps: false),
      JsCompilerConfig(minify: false),

      // All properties non-default
      JsCompilerConfig(
        csp: true,
        dumpInfo: true,
        nativeNullAssertions: true,
        optimizationLevel: 0,
        useFrequencyBasedMinification: false,
        sourceMaps: false,
      ),
    ];

    final Iterable<String> buildKeys = testConfigs.map((JsCompilerConfig config) {
      final target = Dart2JSTarget(config);
      return target.buildKey;
    });

    // Make sure all the build keys are unique.
    expect(buildKeys.toSet().length, buildKeys.length);
  });

  test('Dart2Wasm has unique build keys for compiler configurations', () {
    const testConfigs = <WasmCompilerConfig>[
      // Default values
      WasmCompilerConfig(),

      // Each individual property being made non-default
      WasmCompilerConfig(optimizationLevel: 0),
      WasmCompilerConfig(renderer: WebRendererMode.canvaskit),
      WasmCompilerConfig(stripWasm: false),
      WasmCompilerConfig(minify: false),
      WasmCompilerConfig(dryRun: true),

      // All properties non-default
      WasmCompilerConfig(
        optimizationLevel: 0,
        stripWasm: false,
        renderer: WebRendererMode.canvaskit,
        dryRun: true,
      ),
    ];

    final Iterable<String> buildKeys = testConfigs.map((WasmCompilerConfig config) {
      final target = Dart2WasmTarget(config, const NoOpAnalytics());
      return target.buildKey;
    });

    // Make sure all the build keys are unique.
    expect(buildKeys.toSet().length, buildKeys.length);
  });

  test('JsCompilerConfig minification based on release mode', () {
    // Explicit `minify: true` should always result in `--minify` in all modes.
    expect(
      const JsCompilerConfig(minify: true).toCommandOptions(BuildMode.debug),
      contains('--minify'),
    );
    expect(
      const JsCompilerConfig(minify: true).toCommandOptions(BuildMode.profile),
      contains('--minify'),
    );
    expect(
      const JsCompilerConfig(minify: true).toCommandOptions(BuildMode.release),
      contains('--minify'),
    );

    // Explicit `minify: false` should always result in `--no-minify` in all modes.
    expect(
      const JsCompilerConfig(minify: false).toCommandOptions(BuildMode.debug),
      contains('--no-minify'),
    );
    expect(
      const JsCompilerConfig(minify: false).toCommandOptions(BuildMode.profile),
      contains('--no-minify'),
    );
    expect(
      const JsCompilerConfig(minify: false).toCommandOptions(BuildMode.release),
      contains('--no-minify'),
    );

    // Default `minify` should result in `--minify` only in release mode.
    expect(const JsCompilerConfig().toCommandOptions(BuildMode.debug), contains('--no-minify'));
    expect(const JsCompilerConfig().toCommandOptions(BuildMode.profile), contains('--no-minify'));
    expect(const JsCompilerConfig().toCommandOptions(BuildMode.release), contains('--minify'));
  });

  test('WasmCompilerConfig minification based on release mode', () {
    // Explicit `minify: true` should always result in `--minify` in all modes.
    expect(
      const WasmCompilerConfig(minify: true).toCommandOptions(BuildMode.debug),
      contains('--minify'),
    );
    expect(
      const WasmCompilerConfig(minify: true).toCommandOptions(BuildMode.profile),
      contains('--minify'),
    );
    expect(
      const WasmCompilerConfig(minify: true).toCommandOptions(BuildMode.release),
      contains('--minify'),
    );

    // Explicit `minify: false` should always result in `--no-minify` in all modes.
    expect(
      const WasmCompilerConfig(minify: false).toCommandOptions(BuildMode.debug),
      contains('--no-minify'),
    );
    expect(
      const WasmCompilerConfig(minify: false).toCommandOptions(BuildMode.profile),
      contains('--no-minify'),
    );
    expect(
      const WasmCompilerConfig(minify: false).toCommandOptions(BuildMode.release),
      contains('--no-minify'),
    );

    // Default `minify` should result in `--minify` only in release mode.
    expect(const WasmCompilerConfig().toCommandOptions(BuildMode.debug), contains('--no-minify'));
    expect(const WasmCompilerConfig().toCommandOptions(BuildMode.profile), contains('--no-minify'));
    expect(const WasmCompilerConfig().toCommandOptions(BuildMode.release), contains('--minify'));
  });

  test(
    'Generated service worker is empty with none-strategy',
    () => testbed.run(() {
      final String fileGeneratorsPath = environment.artifacts.getArtifactPath(
        Artifact.flutterToolsFileGenerators,
      );
      final String result = generateServiceWorker(
        fileGeneratorsPath,
        serviceWorkerStrategy: ServiceWorkerStrategy.none,
      );

      expect(result, '');
    }),
  );

  test(
    'WebBuiltInAssets copies over canvaskit again if the web sdk changes',
    () => testbed.run(() async {
      final File canvasKitInput = globals.fs.file(
        'bin/cache/flutter_web_sdk/canvaskit/canvaskit.wasm',
      )..createSync(recursive: true);
      canvasKitInput.writeAsStringSync('foo', flush: true);

      await WebBuiltInAssets(globals.fs).build(environment);

      final File canvasKitOutputBefore = environment.outputDir
          .childDirectory('canvaskit')
          .childFile('canvaskit.wasm');
      expect(canvasKitOutputBefore.existsSync(), true);
      expect(canvasKitOutputBefore.readAsStringSync(), 'foo');

      canvasKitInput.writeAsStringSync('bar', flush: true);

      await WebBuiltInAssets(globals.fs).build(environment);

      final File canvasKitOutputAfter = environment.outputDir
          .childDirectory('canvaskit')
          .childFile('canvaskit.wasm');
      expect(canvasKitOutputAfter.existsSync(), true);
      expect(canvasKitOutputAfter.readAsStringSync(), 'bar');
    }),
  );
}
