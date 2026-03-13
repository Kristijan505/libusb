import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:libusb/src/hook_platform.dart';

const String _libusbVersion = '1.0.29';
const String _libusbArchiveName = 'libusb-$_libusbVersion.tar.bz2';
const String _libusbArchiveSha256 =
    '5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85';
const String _libusbArchiveUrl =
    'https://github.com/libusb/libusb/releases/download/v$_libusbVersion/$_libusbArchiveName';
const String _assetName = 'libusb.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    output.dependencies.add(Uri.file(Platform.script.toFilePath()));

    if (!input.config.buildCodeAssets) {
      return;
    }

    final targetOs = input.config.code.targetOS;
    final targetArchitecture = input.config.code.targetArchitecture;
    if (!isSupportedTarget(targetOs, targetArchitecture)) {
      throw UnsupportedError(
        'Unsupported target: $targetOs/$targetArchitecture. '
        'Supported targets are Android, Linux, macOS, Windows.',
      );
    }

    final sourceDir = await _prepareSourceTree(input, output);
    final builtLibrary = await _buildLibrary(
      targetOs: targetOs,
      targetArchitecture: targetArchitecture,
      input: input,
      sourceDir: sourceDir,
    );

    final bundledDir = Directory.fromUri(input.outputDirectory.resolve('asset/'))
      ..createSync(recursive: true);
    final bundledFile = File.fromUri(
      bundledDir.uri.resolve(outputLibraryFileName(targetOs)),
    );
    builtLibrary.copySync(bundledFile.path);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: bundledFile.absolute.uri,
      ),
    );
  });
}

Future<Directory> _prepareSourceTree(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  final cacheRoot = Directory.fromUri(
    input.outputDirectoryShared.resolve('libusb/v$_libusbVersion/'),
  )..createSync(recursive: true);
  final downloadsDir = Directory.fromUri(cacheRoot.uri.resolve('downloads/'))
    ..createSync(recursive: true);
  final sourceRoot = Directory.fromUri(cacheRoot.uri.resolve('source/'))
    ..createSync(recursive: true);
  final archiveFile = File.fromUri(downloadsDir.uri.resolve(_libusbArchiveName));
  final sourceDir = Directory.fromUri(
    sourceRoot.uri.resolve('libusb-$_libusbVersion/'),
  );
  final configureFile = File.fromUri(sourceDir.uri.resolve('configure'));

  if (!archiveFile.existsSync()) {
    await _download(Uri.parse(_libusbArchiveUrl), archiveFile);
  }
  final digest = await _sha256Hex(archiveFile);
  if (digest != _libusbArchiveSha256) {
    archiveFile.deleteSync();
    throw StateError(
      'Checksum mismatch for $_libusbArchiveName.\n'
      'Expected: $_libusbArchiveSha256\n'
      'Actual:   $digest',
    );
  }

  output.dependencies.add(archiveFile.absolute.uri);

  if (sourceDir.existsSync() && !configureFile.existsSync()) {
    sourceDir.deleteSync(recursive: true);
  }

  if (!sourceDir.existsSync()) {
    await _run(
      <String>[
        'tar',
        '-xjf',
        archiveFile.path,
        '-C',
        sourceRoot.path,
      ],
      workingDirectory: sourceRoot.path,
      runInShell: Platform.isWindows,
    );
  }

  if (!sourceDir.existsSync()) {
    throw StateError('Unable to prepare libusb source tree at ${sourceDir.path}');
  }
  return sourceDir;
}

Future<File> _buildLibrary({
  required OS targetOs,
  required Architecture targetArchitecture,
  required BuildInput input,
  required Directory sourceDir,
}) async {
  switch (targetOs) {
    case OS.android:
      return _buildAndroid(
        sourceDir: sourceDir,
        outputDirectory: Directory.fromUri(input.outputDirectory),
        architecture: targetArchitecture,
      );
    case OS.linux:
    case OS.macOS:
      return _buildPosix(
        sourceDir: sourceDir,
        outputDirectory: Directory.fromUri(input.outputDirectory),
        targetOs: targetOs,
      );
    case OS.windows:
      return _buildWindows(
        sourceDir: sourceDir,
        architecture: targetArchitecture,
      );
    default:
      throw UnsupportedError('Unsupported target OS: $targetOs');
  }
}

Future<File> _buildPosix({
  required Directory sourceDir,
  required Directory outputDirectory,
  required OS targetOs,
}) async {
  if ((targetOs == OS.linux && !Platform.isLinux) ||
      (targetOs == OS.macOS && !Platform.isMacOS)) {
    throw UnsupportedError(
      'Cross-OS desktop builds are not supported in this hook. '
      'Target $targetOs must be built on the same host OS.',
    );
  }

  final buildDir = Directory.fromUri(outputDirectory.uri.resolve('libusb-build/'))
    ..createSync(recursive: true);
  final installDir = Directory.fromUri(buildDir.uri.resolve('install/'))
    ..createSync(recursive: true);
  final configureScript = sourceDir.uri.resolve('configure').toFilePath();

  final configureArgs = <String>[
    configureScript,
    '--enable-shared',
    '--disable-static',
    '--disable-examples-build',
    '--disable-tests-build',
    '--disable-udev',
    '--disable-timerfd',
    '--prefix=${installDir.path}',
  ];
  await _run(configureArgs, workingDirectory: buildDir.path);
  await _run([
    'make',
    '-j${Platform.numberOfProcessors > 0 ? Platform.numberOfProcessors : 1}',
  ], workingDirectory: buildDir.path);
  await _run(['make', 'install'], workingDirectory: buildDir.path);

  final libDir = Directory.fromUri(installDir.uri.resolve('lib/'));
  final desired = outputLibraryFileName(targetOs);
  final direct = File.fromUri(libDir.uri.resolve(desired));
  if (direct.existsSync()) {
    return direct;
  }

  final fallback = _findFirstFile(
    libDir,
    (file) => file.path.contains('libusb-1.0.') && !file.path.endsWith('.la'),
  );
  if (fallback != null) {
    return fallback;
  }
  throw StateError('Unable to find built libusb library in ${libDir.path}.');
}

Future<File> _buildAndroid({
  required Directory sourceDir,
  required Directory outputDirectory,
  required Architecture architecture,
}) async {
  final ndkBuild = _resolveNdkBuild();
  if (ndkBuild == null) {
    throw StateError(
      'Android NDK not found. Set ANDROID_NDK/ANDROID_NDK_HOME/'
      'ANDROID_NDK_ROOT (or provide ndk-build in PATH).',
    );
  }

  final abi = androidAbiForArchitecture(architecture);
  final androidDir = Directory.fromUri(sourceDir.uri.resolve('android/'));
  final jniDir = Directory.fromUri(androidDir.uri.resolve('jni/'));
  final appBuildScript = jniDir.uri.resolve('libusb.mk').toFilePath();

  await _run(
    <String>[
      ndkBuild,
      'NDK_PROJECT_PATH=${androidDir.path}',
      'APP_BUILD_SCRIPT=$appBuildScript',
      'APP_ABI=$abi',
      'USE_PC_NAME=1',
    ],
    workingDirectory: jniDir.path,
    runInShell: true,
  );

  final preferred = File.fromUri(androidDir.uri.resolve('libs/$abi/libusb-1.0.so'));
  if (preferred.existsSync()) {
    return preferred;
  }
  final legacy = File.fromUri(androidDir.uri.resolve('libs/$abi/libusb1.0.so'));
  if (legacy.existsSync()) {
    final normalized = File.fromUri(
      outputDirectory.uri.resolve('android-libusb-1.0.so'),
    );
    legacy.copySync(normalized.path);
    return normalized;
  }
  throw StateError('Unable to find Android libusb output for ABI $abi.');
}

Future<File> _buildWindows({
  required Directory sourceDir,
  required Architecture architecture,
}) async {
  if (!Platform.isWindows) {
    throw UnsupportedError(
      'Windows target must be built on a Windows host with MSBuild.',
    );
  }

  final platform = windowsPlatformForArchitecture(architecture);
  await _run(
    <String>[
      'msbuild',
      'msvc\\libusb.sln',
      '/m',
      '/t:libusb_dll',
      '/p:Configuration=Release',
      '/p:Platform=$platform',
    ],
    workingDirectory: sourceDir.path,
    runInShell: true,
  );

  final buildRoot = Directory.fromUri(sourceDir.uri.resolve('build/'));
  final dll = _findNewestFile(buildRoot, (f) => f.path.endsWith('libusb-1.0.dll'));
  if (dll != null) {
    return dll;
  }
  throw StateError('Unable to find Windows libusb-1.0.dll after MSBuild.');
}

Future<void> _download(Uri uri, File file) async {
  file.parent.createSync(recursive: true);
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Failed to download $uri (HTTP ${response.statusCode}).',
        uri: uri,
      );
    }
    final sink = file.openWrite();
    await response.pipe(sink);
    await sink.close();
  } finally {
    client.close(force: true);
  }
}

Future<String> _sha256Hex(File file) async {
  final bytes = await file.readAsBytes();
  return sha256.convert(bytes).toString();
}

Future<void> _run(
  List<String> command, {
  required String workingDirectory,
  bool runInShell = false,
}) async {
  final result = await Process.run(
    command.first,
    command.sublist(1),
    workingDirectory: workingDirectory,
    runInShell: runInShell,
  );
  if (result.stdout is String && (result.stdout as String).isNotEmpty) {
    stdout.write(result.stdout as String);
  } else if (result.stdout is List<int>) {
    stdout.write(utf8.decode(result.stdout as List<int>));
  }
  if (result.stderr is String && (result.stderr as String).isNotEmpty) {
    stderr.write(result.stderr as String);
  } else if (result.stderr is List<int>) {
    stderr.write(utf8.decode(result.stderr as List<int>));
  }
  if (result.exitCode != 0) {
    throw ProcessException(
      command.first,
      command.sublist(1),
      'Command failed with exit code ${result.exitCode}.',
      result.exitCode,
    );
  }
}

String? _resolveNdkBuild() {
  final names = Platform.isWindows
      ? <String>['ndk-build.cmd', 'ndk-build.bat', 'ndk-build']
      : <String>['ndk-build'];
  final ndkEnvVars = <String>[
    'ANDROID_NDK',
    'ANDROID_NDK_HOME',
    'ANDROID_NDK_ROOT',
    'ANDROID_NDK_LATEST_HOME',
  ];

  for (final env in ndkEnvVars) {
    final value = Platform.environment[env];
    if (value == null || value.isEmpty) {
      continue;
    }
    for (final name in names) {
      final candidate = File('$value${Platform.pathSeparator}$name');
      if (candidate.existsSync()) {
        return candidate.path;
      }
    }
  }

  final pathValue = Platform.environment['PATH'] ?? '';
  final pathSeparator = Platform.isWindows ? ';' : ':';
  for (final segment in pathValue.split(pathSeparator)) {
    if (segment.isEmpty) {
      continue;
    }
    for (final name in names) {
      final candidate = File('$segment${Platform.pathSeparator}$name');
      if (candidate.existsSync()) {
        return candidate.path;
      }
    }
  }
  return null;
}

File? _findFirstFile(Directory root, bool Function(File file) predicate) {
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && predicate(entity)) {
      return entity;
    }
  }
  return null;
}

File? _findNewestFile(Directory root, bool Function(File file) predicate) {
  File? newest;
  DateTime? newestTime;
  if (!root.existsSync()) {
    return null;
  }
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !predicate(entity)) {
      continue;
    }
    final modified = entity.lastModifiedSync();
    if (newest == null || modified.isAfter(newestTime!)) {
      newest = entity;
      newestTime = modified;
    }
  }
  return newest;
}
