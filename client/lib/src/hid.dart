/// USB HID keyboard usages (page 0x07) as sent in `{"t":"key"}` messages.
abstract final class Hid {
  static const enter = 0x70028;
  static const escape = 0x70029;
  static const backspace = 0x7002A;
  static const tab = 0x7002B;
  static const space = 0x7002C;
  static const right = 0x7004F;
  static const left = 0x70050;
  static const down = 0x70051;
  static const up = 0x70052;
  static const keyV = 0x70019;
  static const leftControl = 0x700E0;
  static const leftShift = 0x700E1;
  static const leftAlt = 0x700E2;
  static const leftMeta = 0x700E3;

  static const rightControl = 0x700E4;
  static const rightMeta = 0x700E7;

  static bool isKeyboardPage(int usage) => usage >> 16 == 0x07;

  /// A PC keyboard's Ctrl is the shortcut key (Ctrl+C/V/A), which on the Mac is ⌘: swap them
  /// (the Windows/Meta key becomes Control).
  static int ctrlAsCmd(int usage) => switch (usage) {
    leftControl => leftMeta,
    leftMeta => leftControl,
    rightControl => rightMeta,
    rightMeta => rightControl,
    _ => usage,
  };

  static bool isModifier(int usage) => usage >= 0x700E0 && usage <= 0x700E7;

  /// Keys that never produce text: editing, navigation, function keys.
  static bool isControlKey(int usage) {
    final code = usage & 0xFFFF;
    return (code >= 0x28 && code <= 0x2B) || // enter, escape, backspace, tab
        (code >= 0x3A && code <= 0x52) || // F1-F12, print..up
        (code >= 0x68 && code <= 0x6F); // F13-F20
  }

  /// HID usage for a character typed on the soft keyboard, so a sticky modifier can
  /// turn "c" into Cmd+C. Null for characters without a single US-layout key.
  static int? forCharacter(String character) {
    if (character.length != 1) return null;
    final c = character.toLowerCase().codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7A) return 0x70004 + (c - 0x61); // a-z
    if (c >= 0x31 && c <= 0x39) return 0x7001E + (c - 0x31); // 1-9
    const punctuation = {
      '0': 0x27, ' ': 0x2C, '-': 0x2D, '=': 0x2E, '[': 0x2F, ']': 0x30, '\\': 0x31,
      ';': 0x33, "'": 0x34, '`': 0x35, ',': 0x36, '.': 0x37, '/': 0x38,
    };
    final code = punctuation[character];
    return code == null ? null : 0x70000 | code;
  }
}
