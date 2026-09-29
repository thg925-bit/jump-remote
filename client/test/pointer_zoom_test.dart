import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:jump_viewer/src/pointer_input.dart';

void main() {
  const surface = Size(762, 352);
  final k = math.min(surface.width / 2560, surface.height / 1664);
  final video = Rect.fromLTWH((surface.width - 2560 * k) / 2, (surface.height - 1664 * k) / 2, 2560 * k, 1664 * k);

  PointerInput make() => PointerInput(send: (_) {}, onViewChanged: () {})
    ..surfaceSize = surface
    ..videoRect = video;

  Rect onScreen(PointerInput p) => Rect.fromLTRB(p.offset.dx + video.left * p.scale, p.offset.dy + video.top * p.scale,
      p.offset.dx + video.right * p.scale, p.offset.dy + video.bottom * p.scale);

  test('fill covers the whole phone screen, no black bars', () {
    final p = make()..setFill(true, const Offset(0.5, 0.5));
    final r = onScreen(p);
    expect(p.fill, isTrue);
    expect(r.left, lessThanOrEqualTo(0.01));
    expect(r.right, greaterThanOrEqualTo(surface.width - 0.01));
    expect(r.top, lessThanOrEqualTo(0.01));
    expect(r.bottom, greaterThanOrEqualTo(surface.height - 0.01));
  });

  test('fill follows the cursor to the bottom of the Mac screen', () {
    final p = make()..setFill(true, const Offset(0.5, 0.1));
    p.follow(const Offset(0.5, 0.98));
    final cursorY = p.offset.dy + (video.top + 0.98 * video.height) * p.scale;
    expect(cursorY, lessThanOrEqualTo(surface.height));
    expect(onScreen(p).bottom, greaterThanOrEqualTo(surface.height - 0.01)); // still no bar
  });

  test('back to fit restores the letterboxed view', () {
    final p = make()..setFill(true, const Offset(0.5, 0.5));
    p.setFill(false, const Offset(0.5, 0.5));
    expect(p.fill, isFalse);
    expect(p.scale, 1);
    expect(p.offset, Offset.zero);
  });
}
