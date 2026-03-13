import 'package:code_assets/code_assets.dart';
import 'package:libusb/src/hook_platform.dart';
import 'package:test/test.dart';

void main() {
  test('supported targets include desktop and android', () {
    expect(
      isSupportedTarget(OS.linux, Architecture.x64),
      isTrue,
    );
    expect(
      isSupportedTarget(OS.macOS, Architecture.arm64),
      isTrue,
    );
    expect(
      isSupportedTarget(OS.windows, Architecture.x64),
      isTrue,
    );
    expect(
      isSupportedTarget(OS.android, Architecture.arm64),
      isTrue,
    );
    expect(
      isSupportedTarget(OS.iOS, Architecture.arm64),
      isFalse,
    );
  });

  test('library filenames are stable per target OS', () {
    expect(outputLibraryFileName(OS.android), 'libusb-1.0.so');
    expect(outputLibraryFileName(OS.linux), 'libusb-1.0.so');
    expect(outputLibraryFileName(OS.macOS), 'libusb-1.0.dylib');
    expect(outputLibraryFileName(OS.windows), 'libusb-1.0.dll');
  });

  test('android abi mapping', () {
    expect(androidAbiForArchitecture(Architecture.arm), 'armeabi-v7a');
    expect(androidAbiForArchitecture(Architecture.arm64), 'arm64-v8a');
    expect(androidAbiForArchitecture(Architecture.ia32), 'x86');
    expect(androidAbiForArchitecture(Architecture.x64), 'x86_64');
  });
}
