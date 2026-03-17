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
      // This package can exist transitively in apps that also target
      // unsupported platforms (for example iOS). In that case we skip
      // producing a native asset instead of failing the whole app build.
      stdout.writeln(
        '[libusb hook] Skipping native asset build for unsupported target '
        '$targetOs/$targetArchitecture. Supported targets are Android, '
        'Linux, macOS, Windows.',
      );
      return;
    }

    final sourceDir = await _prepareSourceTree(input, output);
    final builtLibrary = await _buildLibrary(
      targetOs: targetOs,
      targetArchitecture: targetArchitecture,
      input: input,
      sourceDir: sourceDir,
    );

    final bundledDir = Directory.fromUri(
      input.outputDirectory.resolve('asset/'),
    )..createSync(recursive: true);
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
  final archiveFile = File.fromUri(
    downloadsDir.uri.resolve(_libusbArchiveName),
  );
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
      <String>['tar', '-xjf', archiveFile.path, '-C', sourceRoot.path],
      workingDirectory: sourceRoot.path,
      runInShell: Platform.isWindows,
    );
  }

  if (!sourceDir.existsSync()) {
    throw StateError(
      'Unable to prepare libusb source tree at ${sourceDir.path}',
    );
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
        input: input,
      );
    case OS.linux:
    case OS.macOS:
      return _buildPosix(
        sourceDir: sourceDir,
        outputDirectory: Directory.fromUri(input.outputDirectory),
        targetOs: targetOs,
        targetArchitecture: targetArchitecture,
        input: input,
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
  required Architecture targetArchitecture,
  required BuildInput input,
}) async {
  if ((targetOs == OS.linux && !Platform.isLinux) ||
      (targetOs == OS.macOS && !Platform.isMacOS)) {
    throw UnsupportedError(
      'Cross-OS desktop builds are not supported in this hook. '
      'Target $targetOs must be built on the same host OS.',
    );
  }

  final buildDir = Directory.fromUri(
    outputDirectory.uri.resolve('libusb-build/'),
  )..createSync(recursive: true);
  final installDir = Directory.fromUri(buildDir.uri.resolve('install/'))
    ..createSync(recursive: true);
  final configureScript = sourceDir.uri.resolve('configure').toFilePath();
  final env = <String, String>{};
  if (targetOs == OS.macOS) {
    final arch = switch (targetArchitecture) {
      Architecture.arm64 => 'arm64',
      Architecture.x64 => 'x86_64',
      _ => throw UnsupportedError(
        'Unsupported macOS target architecture: $targetArchitecture',
      ),
    };
    final minVersion = input.config.code.macOS.targetVersion;
    final archAndVersionFlags = '-arch $arch -mmacosx-version-min=$minVersion';
    var compileAndLinkFlags = archAndVersionFlags;
    final sdkRoot = await _resolveMacOsSdkRoot();
    if (sdkRoot != null) {
      final sysrootFlag = '-isysroot $sdkRoot';
      compileAndLinkFlags = '$archAndVersionFlags $sysrootFlag';
      env['SDKROOT'] = sdkRoot;
      env['CPPFLAGS'] = sysrootFlag;
    }
    env['CFLAGS'] = compileAndLinkFlags;
    env['CXXFLAGS'] = compileAndLinkFlags;
    env['LDFLAGS'] = compileAndLinkFlags;
    stdout.writeln('[libusb hook] macOS build flags: $compileAndLinkFlags');
  }

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
  await _run(
    configureArgs,
    workingDirectory: buildDir.path,
    environment: env.isEmpty ? null : env,
  );
  await _run(
    [
      'make',
      '-j${Platform.numberOfProcessors > 0 ? Platform.numberOfProcessors : 1}',
    ],
    workingDirectory: buildDir.path,
    environment: env.isEmpty ? null : env,
  );
  await _run(
    ['make', 'install'],
    workingDirectory: buildDir.path,
    environment: env.isEmpty ? null : env,
  );

  final libDir = Directory.fromUri(installDir.uri.resolve('lib/'));
  if (targetOs == OS.macOS) {
    return _mergeOrSelectMacOsDylib(
      libDir: libDir,
      outputDirectory: outputDirectory,
    );
  }

  final desired = outputLibraryFileName(targetOs);
  final direct = File.fromUri(libDir.uri.resolve(desired));
  if (direct.existsSync()) {
    return direct;
  }
  throw StateError('Unable to find built libusb library in ${libDir.path}.');
}

Future<File> _mergeOrSelectMacOsDylib({
  required Directory libDir,
  required Directory outputDirectory,
}) async {
  final candidates = <File>[
    File.fromUri(libDir.uri.resolve('libusb-1.0.dylib')),
    ...libDir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.dylib') && f.path.contains('libusb-1.0'),
    ),
  ];
  final existingCandidates = candidates.where((f) => f.existsSync()).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (existingCandidates.isEmpty) {
    throw StateError('Unable to find built libusb dylib in ${libDir.path}.');
  }

  final byArch = <String, File>{};
  for (final file in existingCandidates) {
    final archs = await _readMachOArchitectures(file);
    stdout.writeln(
      '[libusb hook] macOS dylib candidate ${file.path} -> ${archs.join(",")}',
    );
    for (final arch in archs) {
      byArch.putIfAbsent(arch, () => file);
    }
  }
  if (byArch.isEmpty) {
    throw StateError(
      'Unable to detect architecture for macOS dylib candidates.',
    );
  }

  final selectedByArch = byArch.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final lipoInputs = <File>[];
  for (final entry in selectedByArch) {
    if (!lipoInputs.any((f) => f.path == entry.value.path)) {
      lipoInputs.add(entry.value);
    }
  }
  stdout.writeln(
    '[libusb hook] macOS selected lipo inputs: ${lipoInputs.map((f) => f.path).join(",")}',
  );

  if (lipoInputs.length == 1) {
    return lipoInputs.single;
  }

  final merged = File.fromUri(
    outputDirectory.uri.resolve('libusb-1.0.universal.dylib'),
  );
  await _run(<String>[
    'lipo',
    '-create',
    ...lipoInputs.map((f) => f.path),
    '-output',
    merged.path,
  ], workingDirectory: outputDirectory.path);
  return merged;
}

Future<List<String>> _readMachOArchitectures(File dylib) async {
  final result = await Process.run('lipo', <String>['-archs', dylib.path]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'lipo',
      <String>['-archs', dylib.path],
      result.stderr.toString(),
      result.exitCode,
    );
  }
  return result.stdout
      .toString()
      .trim()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .toList();
}

Future<File> _buildAndroid({
  required Directory sourceDir,
  required Directory outputDirectory,
  required Architecture architecture,
  required BuildInput input,
}) async {
  final ndkResolution = _resolveNdkBuild(input);
  final ndkBuild = ndkResolution.ndkBuildPath;
  if (ndkBuild == null) {
    throw StateError(
      'Android NDK not found.\n'
      'Checked locations:\n'
      '${ndkResolution.checkedPaths.map((p) => '- $p').join('\n')}',
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

  final preferred = File.fromUri(
    androidDir.uri.resolve('libs/$abi/libusb-1.0.so'),
  );
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
  final dll = _findNewestFile(
    buildRoot,
    (f) => f.path.endsWith('libusb-1.0.dll'),
  );
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
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    command.first,
    command.sublist(1),
    workingDirectory: workingDirectory,
    runInShell: runInShell,
    environment: environment,
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

Future<String?> _resolveMacOsSdkRoot() async {
  final result = await Process.run('xcrun', const <String>[
    '--sdk',
    'macosx',
    '--show-sdk-path',
  ]);
  if (result.exitCode != 0) {
    final stderrText = result.stderr.toString().trim();
    if (stderrText.isNotEmpty) {
      stdout.writeln('[libusb hook] xcrun SDK lookup failed: $stderrText');
    }
    return null;
  }
  final sdkRoot = result.stdout.toString().trim();
  if (sdkRoot.isEmpty) {
    return null;
  }
  stdout.writeln('[libusb hook] macOS SDKROOT: $sdkRoot');
  return sdkRoot;
}

final class _NdkResolution {
  const _NdkResolution({
    required this.ndkBuildPath,
    required this.checkedPaths,
  });

  final String? ndkBuildPath;
  final List<String> checkedPaths;
}

_NdkResolution _resolveNdkBuild(BuildInput input) {
  final checked = <String>[];

  for (final env in const <String>[
    'ANDROID_NDK',
    'ANDROID_NDK_HOME',
    'ANDROID_NDK_ROOT',
  ]) {
    final value = Platform.environment[env];
    if (value == null || value.isEmpty) {
      checked.add('$env is not set');
      continue;
    }
    final found = _findNdkBuildUnderDirectory(value, checked, context: env);
    if (found != null) {
      return _NdkResolution(ndkBuildPath: found, checkedPaths: checked);
    }
  }

  final localPropsCandidates = _localPropertiesCandidates(input);
  for (final propertiesFile in localPropsCandidates) {
    checked.add('local.properties candidate: ${propertiesFile.path}');
    if (!propertiesFile.existsSync()) {
      continue;
    }
    final props = _parseLocalProperties(propertiesFile);
    final ndkDirRaw = props['ndk.dir'];
    if (ndkDirRaw != null && ndkDirRaw.isNotEmpty) {
      final ndkDir = _resolvePropertyPath(
        value: ndkDirRaw,
        propertiesFile: propertiesFile,
      );
      final found = _findNdkBuildUnderDirectory(
        ndkDir,
        checked,
        context: '${propertiesFile.path}:ndk.dir',
      );
      if (found != null) {
        return _NdkResolution(ndkBuildPath: found, checkedPaths: checked);
      }
    }

    final sdkDirRaw = props['sdk.dir'];
    if (sdkDirRaw != null && sdkDirRaw.isNotEmpty) {
      final sdkDir = _resolvePropertyPath(
        value: sdkDirRaw,
        propertiesFile: propertiesFile,
      );
      final found = _findNdkBuildFromSdkRoot(
        sdkDir,
        checked,
        context: '${propertiesFile.path}:sdk.dir',
      );
      if (found != null) {
        return _NdkResolution(ndkBuildPath: found, checkedPaths: checked);
      }
    }
  }

  for (final env in const <String>['ANDROID_SDK_ROOT', 'ANDROID_HOME']) {
    final value = Platform.environment[env];
    if (value == null || value.isEmpty) {
      checked.add('$env is not set');
      continue;
    }
    final found = _findNdkBuildFromSdkRoot(value, checked, context: env);
    if (found != null) {
      return _NdkResolution(ndkBuildPath: found, checkedPaths: checked);
    }
  }

  final fromPath = _findNdkBuildInPath(checked);
  if (fromPath != null) {
    return _NdkResolution(ndkBuildPath: fromPath, checkedPaths: checked);
  }

  return _NdkResolution(ndkBuildPath: null, checkedPaths: checked);
}

List<File> _localPropertiesCandidates(BuildInput input) {
  final candidates = <String>{};
  final packageRoot = Directory.fromUri(input.packageRoot);
  candidates.add(
    File.fromUri(packageRoot.uri.resolve('android/local.properties')).path,
  );
  candidates.add(
    File.fromUri(packageRoot.uri.resolve('local.properties')).path,
  );

  final workspaceRoot = _findWorkspaceRootFromSharedOutput(input);
  if (workspaceRoot != null) {
    candidates.add(
      File.fromUri(workspaceRoot.uri.resolve('android/local.properties')).path,
    );
    candidates.add(
      File.fromUri(workspaceRoot.uri.resolve('local.properties')).path,
    );
  }
  final list = candidates.toList()..sort();
  return list.map(File.new).toList();
}

Directory? _findWorkspaceRootFromSharedOutput(BuildInput input) {
  var current = Directory.fromUri(input.outputDirectoryShared);
  while (true) {
    if (_basename(current.path) == '.dart_tool') {
      return current.parent;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      return null;
    }
    current = parent;
  }
}

Map<String, String> _parseLocalProperties(File file) {
  final result = <String, String>{};
  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final idx = line.indexOf('=');
    if (idx <= 0) {
      continue;
    }
    final key = line.substring(0, idx).trim();
    final value = line.substring(idx + 1).trim();
    result[key] = value;
  }
  return result;
}

String _resolvePropertyPath({
  required String value,
  required File propertiesFile,
}) {
  var normalized = value
      .replaceAll(r'\:', ':')
      .replaceAll(r'\=', '=')
      .replaceAll(r'\ ', ' ')
      .replaceAll(r'\\', r'\');
  if (_isAbsolutePath(normalized)) {
    return normalized;
  }
  return File.fromUri(
    propertiesFile.parent.uri.resolve(normalized),
  ).absolute.path;
}

bool _isAbsolutePath(String path) {
  if (path.startsWith('/')) {
    return true;
  }
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  if (index < 0) {
    return normalized;
  }
  return normalized.substring(index + 1);
}

String? _findNdkBuildFromSdkRoot(
  String sdkRoot,
  List<String> checked, {
  required String context,
}) {
  final ndkBundle = Directory('$sdkRoot${Platform.pathSeparator}ndk-bundle');
  checked.add('$context -> ${ndkBundle.path}');
  final fromBundle = _findNdkBuildUnderDirectory(
    ndkBundle.path,
    checked,
    context: '$context:ndk-bundle',
  );
  if (fromBundle != null) {
    return fromBundle;
  }

  final ndkRoot = Directory('$sdkRoot${Platform.pathSeparator}ndk');
  checked.add('$context -> ${ndkRoot.path}');
  if (!ndkRoot.existsSync()) {
    return null;
  }

  final versions = ndkRoot.listSync().whereType<Directory>().toList()
    ..sort(
      (a, b) => _compareVersionDirNames(_basename(b.path), _basename(a.path)),
    );

  for (final versionDir in versions) {
    final found = _findNdkBuildUnderDirectory(
      versionDir.path,
      checked,
      context: '$context:ndk/${_basename(versionDir.path)}',
    );
    if (found != null) {
      return found;
    }
  }
  return null;
}

int _compareVersionDirNames(String a, String b) {
  final aParts = RegExp(
    r'\d+',
  ).allMatches(a).map((m) => int.parse(m.group(0)!)).toList();
  final bParts = RegExp(
    r'\d+',
  ).allMatches(b).map((m) => int.parse(m.group(0)!)).toList();
  final max = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < max; i++) {
    final av = i < aParts.length ? aParts[i] : 0;
    final bv = i < bParts.length ? bParts[i] : 0;
    if (av != bv) {
      return av.compareTo(bv);
    }
  }
  return a.compareTo(b);
}

String? _findNdkBuildUnderDirectory(
  String directoryPath,
  List<String> checked, {
  required String context,
}) {
  final names = Platform.isWindows
      ? const <String>['ndk-build.cmd', 'ndk-build.bat', 'ndk-build']
      : const <String>['ndk-build'];
  for (final name in names) {
    final candidate = File('$directoryPath${Platform.pathSeparator}$name');
    checked.add('$context -> ${candidate.path}');
    if (candidate.existsSync()) {
      return candidate.path;
    }
  }
  return null;
}

String? _findNdkBuildInPath(List<String> checked) {
  final names = Platform.isWindows
      ? const <String>['ndk-build.cmd', 'ndk-build.bat', 'ndk-build']
      : const <String>['ndk-build'];
  final path = Platform.environment['PATH'] ?? '';
  final delimiter = Platform.isWindows ? ';' : ':';
  for (final segment in path.split(delimiter)) {
    if (segment.isEmpty) {
      continue;
    }
    for (final name in names) {
      final candidate = File('$segment${Platform.pathSeparator}$name');
      checked.add('PATH -> ${candidate.path}');
      if (candidate.existsSync()) {
        return candidate.path;
      }
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
