import 'package:code_assets/code_assets.dart';

const Set<OS> supportedTargetOs = <OS>{
  OS.android,
  OS.linux,
  OS.macOS,
  OS.windows,
};

bool isSupportedTarget(OS targetOs, Architecture targetArchitecture) {
  if (!supportedTargetOs.contains(targetOs)) {
    return false;
  }
  switch (targetOs) {
    case OS.android:
      return targetArchitecture == Architecture.arm ||
          targetArchitecture == Architecture.arm64 ||
          targetArchitecture == Architecture.ia32 ||
          targetArchitecture == Architecture.x64;
    case OS.linux:
      return targetArchitecture == Architecture.arm ||
          targetArchitecture == Architecture.arm64 ||
          targetArchitecture == Architecture.ia32 ||
          targetArchitecture == Architecture.x64;
    case OS.macOS:
      return targetArchitecture == Architecture.arm64 ||
          targetArchitecture == Architecture.x64;
    case OS.windows:
      return targetArchitecture == Architecture.arm64 ||
          targetArchitecture == Architecture.ia32 ||
          targetArchitecture == Architecture.x64;
    default:
      return false;
  }
}

String outputLibraryFileName(OS targetOs) {
  switch (targetOs) {
    case OS.android:
    case OS.linux:
      return 'libusb-1.0.so';
    case OS.macOS:
      return 'libusb-1.0.dylib';
    case OS.windows:
      return 'libusb-1.0.dll';
    default:
      throw UnsupportedError('Unsupported target OS: $targetOs');
  }
}

String androidAbiForArchitecture(Architecture architecture) {
  switch (architecture) {
    case Architecture.arm:
      return 'armeabi-v7a';
    case Architecture.arm64:
      return 'arm64-v8a';
    case Architecture.ia32:
      return 'x86';
    case Architecture.x64:
      return 'x86_64';
    default:
      throw UnsupportedError('Unsupported Android architecture: $architecture');
  }
}

String windowsPlatformForArchitecture(Architecture architecture) {
  switch (architecture) {
    case Architecture.arm64:
      return 'ARM64';
    case Architecture.ia32:
      return 'Win32';
    case Architecture.x64:
      return 'x64';
    default:
      throw UnsupportedError('Unsupported Windows architecture: $architecture');
  }
}
