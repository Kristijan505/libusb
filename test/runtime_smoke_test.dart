import 'package:libusb/libusb.dart';
import 'package:test/test.dart';

void main() {
  test('libusb_get_version resolves via code asset', () {
    final version = libusb_get_version();
    expect(version.address, isNonZero);
  });
}
