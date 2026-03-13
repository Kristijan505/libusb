## 1.0.0

- **BREAKING**: Migrated bindings to `@Native` (`ffigen` `ffi-native` mode).
- **BREAKING**: Removed class-based `DynamicLibrary` lookup pattern from generated API.
- Added build hook (`hook/build.dart`) with code assets integration.
- Added Android target to supported platforms.
- Updated libusb header to upstream `1.0.29` (`LIBUSB_API_VERSION 0x0100010B`).
- Removed committed prebuilt desktop binaries from `libusb-1.0/`.
- Fixed `ssize_t` ABI mapping for `windowsIA32` (`Int32`).
- Updated dependencies and SDK constraints (Dart 3.11+, latest core dev packages).

## 0.4.23-dev.1+1

- Move example/listdevs.dart to example/main.dart

## 0.4.23-dev.0

- Refactor with ffigen 5.0.0+
- Support ABI-specific `ssize_t` and `timeval`

## 0.3.23+2

- Update generated code with ffigen 3.0.0

## 0.3.23+1

- Update `platforms` according to https://dart.dev/tools/pub/pubspec#platforms

## 0.3.23-nullsafety.0

- Migerate to `Null safety`

## 0.2.23+1

- Fix example typo & README

## 0.2.23

- **BREAKING CHANGE**: Refactor `libusb_xxx.dart` to `libusb32.dart` & `libusb64.dart`

## 0.1.23+3

- Optimize generated dart

## 0.1.23+2

- Add `@Deprecated('inline')` for unavailable inline C functions

## 0.1.23+1

- Add support for Windows

## 0.1.23

- Wrap libusb-1.0.23 for macOS/Linux
