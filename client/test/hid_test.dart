import 'package:flutter_test/flutter_test.dart';
import 'package:jump_viewer/src/hid.dart';

void main() {
  test('PC keyboards: Ctrl goes to the Mac as ⌘ and the Windows key as Control', () {
    expect(Hid.ctrlAsCmd(Hid.leftControl), Hid.leftMeta);
    expect(Hid.ctrlAsCmd(Hid.rightControl), Hid.rightMeta);
    expect(Hid.ctrlAsCmd(Hid.leftMeta), Hid.leftControl);
    expect(Hid.ctrlAsCmd(Hid.keyV), Hid.keyV);
    expect(Hid.ctrlAsCmd(Hid.leftShift), Hid.leftShift);
  });
}
