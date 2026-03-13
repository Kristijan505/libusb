# libusb

Dart wrapper for [libusb](https://github.com/libusb/libusb) using `dart:ffi`.

This package uses Flutter/Dart build hooks and code assets:
- bindings are generated as `@Native` externals (`ffigen` `ffi-native` mode)
- native library is built from libusb source on the consumer machine
- no manual `DynamicLibrary.open(...)` is required by package users

## Supported targets

- Android
- Linux
- macOS
- Windows

Out of scope:
- iOS
- Web (use app-level stubs/fallback package)

## Requirements

General:
- Flutter 3.41+ (or compatible SDK with hooks/code assets)
- Dart 3.11+
- LLVM/Clang for running `ffigen`

Build toolchain by target:
- Linux: `make`, C compiler toolchain, autotools-compatible environment
- macOS: Xcode Command Line Tools (`xcode-select --install`), `make`
- Windows: MSBuild + Visual Studio C++ workload
- Android: Android NDK (`ndk-build` available via env vars or `PATH`)

## Package behavior

`hook/build.dart` does the following:
1. Downloads `libusb-1.0.29.tar.bz2` from the official release URL.
2. Verifies SHA-256 checksum.
3. Builds libusb for the current target.
4. Registers the built library as a bundled code asset for
   `package:libusb/libusb.dart`.

## Regenerate bindings

```bash
flutter pub get
flutter pub run ffigen
```

Bindings are generated from `libusb-1.0/libusb.h` into `lib/src/libusb.ffigen.dart`.

## Development checks

```bash
flutter analyze
flutter test
```
