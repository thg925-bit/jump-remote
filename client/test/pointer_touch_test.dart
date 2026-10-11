import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jump_viewer/src/pointer_input.dart';

void main() {
  const surface = Size(1000, 650);
  final video = Rect.fromLTWH(0, 0, surface.width, surface.height);

  late List<String> sent;
  late Offset cursor;
  late Offset moved;

  PointerInput make(TouchMode mode) {
    sent = [];
    cursor = const Offset(0.5, 0.5);
    moved = Offset.zero;
    return PointerInput(
      send: (m) {
        final t = m['t'];
        if (t == 'move') {
          cursor = Offset(m['x'] as double, m['y'] as double);
          sent.add('move');
        } else if (t == 'scroll') {
          sent.add('scroll');
        } else {
          sent.add('$t b${m['b']}${m['c'] != null ? ' c${m['c']}' : ''} @${(m['x'] as double).toStringAsFixed(2)},${(m['y'] as double).toStringAsFixed(2)}');
        }
      },
      onViewChanged: () {},
      cursor: () => cursor,
      moveCursorBy: (points) => moved += points,
    )
      ..mode = mode
      ..surfaceSize = surface
      ..videoRect = video
      ..displayPoints = const Size(1470, 956);
  }

  var stamp = Duration.zero;
  Duration tick([int ms = 16]) => stamp += Duration(milliseconds: ms);
  void down(PointerInput p, int id, Offset at) =>
      p.pointerDown(PointerDownEvent(pointer: id, position: at, kind: PointerDeviceKind.touch, timeStamp: tick()));
  void move(PointerInput p, int id, Offset at) =>
      p.pointerMove(PointerMoveEvent(pointer: id, position: at, kind: PointerDeviceKind.touch, timeStamp: tick()));
  void up(PointerInput p, int id, Offset at) =>
      p.pointerUp(PointerUpEvent(pointer: id, position: at, kind: PointerDeviceKind.touch, timeStamp: tick()));
  Future<void> hold() => Future<void>.delayed(const Duration(milliseconds: 560));

  group('바로 클릭 (direct)', () {
    test('tap clicks where touched', () {
      final p = make(TouchMode.direct);
      down(p, 1, const Offset(500, 325));
      up(p, 1, const Offset(500, 325));
      expect(sent, ['move', 'down b0 @0.50,0.50', 'up b0 @0.50,0.50']);
    });

    test('a quick second tap close by lands exactly on the first (double click)', () {
      final p = make(TouchMode.direct);
      down(p, 1, const Offset(300, 200));
      up(p, 1, const Offset(300, 200));
      down(p, 1, const Offset(312, 205));
      up(p, 1, const Offset(312, 205));
      expect(sent.where((s) => s.startsWith('down')).toList(), ['down b0 @0.30,0.31', 'down b0 @0.30,0.31']);
    });

    test('hold, then drag = drag from where the finger is', () async {
      final p = make(TouchMode.direct);
      down(p, 1, const Offset(400, 300));
      await hold();
      move(p, 1, const Offset(450, 300));
      up(p, 1, const Offset(450, 300));
      expect(sent.first, 'move');
      expect(sent[1], 'down b0 c1 @0.40,0.46');
      expect(sent.last, 'up b0 @0.45,0.46');
    });

    test('one-finger drag scrolls the window under the finger', () {
      final p = make(TouchMode.direct);
      down(p, 1, const Offset(600, 400));
      move(p, 1, const Offset(600, 380));
      move(p, 1, const Offset(600, 360));
      up(p, 1, const Offset(600, 360));
      expect(sent, ['move', 'scroll', 'scroll']);
      expect(cursor, const Offset(0.6, 400 / 650));
    });

    test('one-finger drag moves the view while zoomed in, and sends nothing', () {
      final p = make(TouchMode.direct)..setFill(false, Offset.zero);
      p.scale = 2;
      p.offset = const Offset(-500, -325);
      down(p, 1, const Offset(600, 400));
      move(p, 1, const Offset(550, 400));
      up(p, 1, const Offset(550, 400));
      expect(sent, isEmpty);
      expect(p.offset.dx, -550);
    });
  });

  group('트랙패드 (trackpad)', () {
    test('drag moves the cursor, faster strokes further', () {
      final p = make(TouchMode.trackpad);
      down(p, 1, const Offset(100, 300));
      for (var i = 1; i <= 20; i++) {
        move(p, 1, Offset(100 + 4.0 * i, 300));
      }
      up(p, 1, const Offset(180, 300));
      final slow = moved.dx;
      expect(slow, greaterThan(0));
      expect(sent, isEmpty);

      moved = Offset.zero;
      down(p, 1, const Offset(100, 400));
      for (var i = 1; i <= 5; i++) {
        move(p, 1, Offset(100 + 16.0 * i, 400));
      }
      up(p, 1, const Offset(180, 400));
      expect(moved.dx, greaterThan(slow * 1.5));
    });

    test('tap clicks at the cursor, not at the finger', () {
      final p = make(TouchMode.trackpad);
      cursor = const Offset(0.2, 0.7);
      down(p, 1, const Offset(900, 100));
      up(p, 1, const Offset(900, 100));
      expect(sent, ['down b0 @0.20,0.70', 'up b0 @0.20,0.70']);
    });

    test('hold, then drag = drag at the cursor', () async {
      final p = make(TouchMode.trackpad);
      down(p, 1, const Offset(500, 300));
      await hold();
      move(p, 1, const Offset(530, 300));
      up(p, 1, const Offset(530, 300));
      expect(sent.first, 'down b0 c1 @0.50,0.50');
      expect(sent.last, 'up b0 @0.50,0.50');
      expect(moved.dx, greaterThan(0));
    });
  });

  test('two-finger tap = right click, three-finger tap = middle click (both modes)', () {
    for (final mode in TouchMode.values) {
      final p = make(mode);
      down(p, 1, const Offset(500, 300));
      down(p, 2, const Offset(540, 300));
      up(p, 2, const Offset(540, 300));
      up(p, 1, const Offset(500, 300));
      expect(sent.where((s) => s.startsWith('down')).single, startsWith('down b1'), reason: '$mode');

      sent.clear();
      down(p, 1, const Offset(500, 300));
      down(p, 2, const Offset(540, 300));
      down(p, 3, const Offset(580, 300));
      up(p, 3, const Offset(580, 300));
      up(p, 2, const Offset(540, 300));
      up(p, 1, const Offset(500, 300));
      expect(sent.where((s) => s.startsWith('down')).single, startsWith('down b2'), reason: '$mode');
    }
  });

  test('leaving the app mid-drag lets go of the button', () async {
    final p = make(TouchMode.direct);
    down(p, 1, const Offset(400, 300));
    await hold();
    move(p, 1, const Offset(420, 300));
    p.cancelGesture();
    expect(sent.last, startsWith('up b0'));
  });
}
