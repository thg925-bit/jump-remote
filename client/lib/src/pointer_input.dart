import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

typedef SendInput = void Function(Map<String, dynamic> message);

/// Turns raw pointer events on the viewer surface into input messages (tap = click where
/// touched, drag = drag, long press / two-finger tap = right click, two fingers = scroll or
/// pinch-zoom), and owns the client-side zoom (`screen = offset + scale * content`).
class PointerInput {
  PointerInput({required this.send, required this.onViewChanged});

  final SendInput send;

  /// Called when zoom/pan changes so the viewer repaints.
  final VoidCallback onViewChanged;

  /// Surface size and where the unzoomed video sits inside it (local coordinates).
  Size surfaceSize = Size.zero;
  Rect videoRect = Rect.zero;

  /// Mac display size in points, for converting finger travel into scroll distance.
  Size? displayPoints;

  double scale = 1;
  Offset offset = Offset.zero;


  static const _dragSlop = 8.0;
  static const _longPress = Duration(milliseconds: 500);
  static const _tapTimeout = Duration(milliseconds: 250);
  static const _maxScale = 6.0;

  final Map<int, Offset> _touches = {};
  _Gesture _gesture = const _Idle();
  Timer? _longPressTimer;

  int _mouseButtons = 0;

  bool get isZoomed => scale > 1.001;

  /// "꽉 채움": the video covers the whole surface (cropping one axis); the view then pans
  /// to keep the cursor in sight.
  bool fill = false;

  /// Scale at which the video covers the surface in both directions.
  double get fillScale => videoRect.isEmpty
      ? 1
      : math.max(1.0, math.max(surfaceSize.width / videoRect.width, surfaceSize.height / videoRect.height));

  void resetZoom() {
    fill = false;
    scale = 1;
    offset = Offset.zero;
    onViewChanged();
  }

  /// Switches fill on (centred on [focus], normalized) or back to fit.
  void setFill(bool on, Offset focus) {
    if (!on) {
      resetZoom();
      return;
    }
    fill = true;
    scale = fillScale;
    offset = _clampOffset(_offsetCentering(focus));
    onViewChanged();
  }

  /// Re-applies fill after a size change (rotation). No notification: called while building.
  void refit() {
    if (!fill || videoRect.isEmpty) return;
    scale = fillScale;
    offset = _clampOffset(offset);
  }

  /// When zoomed, pans so the cursor (normalized) stays at least a margin inside the screen.
  void follow(Offset cursor) {
    if (!isZoomed || videoRect.isEmpty) return;
    final screen = offset + (videoRect.topLeft + Offset(cursor.dx * videoRect.width, cursor.dy * videoRect.height)) * scale;
    const margin = 56.0;
    var shift = Offset.zero;
    if (screen.dx < margin) shift += Offset(margin - screen.dx, 0);
    if (screen.dx > surfaceSize.width - margin) shift += Offset(surfaceSize.width - margin - screen.dx, 0);
    if (screen.dy < margin) shift += Offset(0, margin - screen.dy);
    if (screen.dy > surfaceSize.height - margin) shift += Offset(0, surfaceSize.height - margin - screen.dy);
    if (shift == Offset.zero) return;
    final next = _clampOffset(offset + shift);
    if (next == offset) return;
    offset = next;
    onViewChanged();
  }

  Offset _offsetCentering(Offset normalized) {
    final content = videoRect.topLeft + Offset(normalized.dx * videoRect.width, normalized.dy * videoRect.height);
    return Offset(surfaceSize.width / 2, surfaceSize.height / 2) - content * scale;
  }

  // MARK: Event entry points

  void pointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      final pressed = event.buttons & ~_mouseButtons;
      _mouseButtons = event.buttons;
      for (final button in _buttonsIn(pressed)) {
        send({'t': 'down', 'b': button, ..._pos(_normalized(event.localPosition))});
      }
      return;
    }
    _touchDown(event.pointer, event.localPosition);
  }

  void pointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      send({'t': 'move', ..._pos(_normalized(event.localPosition))});
      return;
    }
    _touchMove(event.pointer, event.localPosition, event.localDelta);
  }

  void pointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      final released = _mouseButtons & ~event.buttons;
      _mouseButtons = event.buttons;
      for (final button in _buttonsIn(released)) {
        send({'t': 'up', 'b': button, ..._pos(_normalized(event.localPosition))});
      }
      return;
    }
    _touchUp(event.pointer, cancelled: false);
  }

  void pointerCancel(PointerCancelEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      for (final button in _buttonsIn(_mouseButtons)) {
        send({'t': 'up', 'b': button});
      }
      _mouseButtons = 0;
      return;
    }
    _touchUp(event.pointer, cancelled: true);
  }

  void pointerHover(PointerHoverEvent event) {
    send({'t': 'move', ..._pos(_normalized(event.localPosition))});
  }

  void pointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // Wheel delta is "scroll down" positive; protocol is "content moves down" positive.
      _scroll(-event.scrollDelta);
    }
  }

  /// Two-finger trackpad / Magic Keyboard gestures on iPad and Android.
  void panZoomUpdate(PointerPanZoomUpdateEvent event) {
    _scroll(event.localPanDelta);
  }

  // MARK: Touch state machine

  void _touchDown(int pointer, Offset position) {
    _touches[pointer] = position;
    if (_touches.length == 1) {
      _gesture = _Pending(start: position);
      _longPressTimer?.cancel();
      _longPressTimer = Timer(_longPress, () => _onLongPress(position));
    } else if (_touches.length == 2) {
      _longPressTimer?.cancel();
      final gesture = _gesture;
      if (gesture is _Dragging) {
        send({'t': 'up', 'b': 0, ..._pos(gesture.last)});
      }
      _gesture = _TwoFinger(
        startCenter: _center(),
        startDistance: math.max(_distance(), 1),
        startScale: scale,
        startOffset: offset,
        lastCenter: _center(),
        time: DateTime.now(),
      );
    }
  }

  void _touchMove(int pointer, Offset position, Offset delta) {
    if (!_touches.containsKey(pointer)) return;
    _touches[pointer] = position;
    final gesture = _gesture;

    switch (gesture) {
      case _Pending():
        if ((position - gesture.start).distance <= _dragSlop) return;
        _longPressTimer?.cancel();
        final start = _normalized(gesture.start);
        send({'t': 'move', ..._pos(start)});
        send({'t': 'down', 'b': 0, ..._pos(start)});
        _gesture = _Dragging(last: start);
        _touchMove(pointer, position, position - gesture.start);
      case _Dragging():
        final point = _normalized(position);
        send({'t': 'move', ..._pos(point)});
        _gesture = _Dragging(last: point);
      case _TwoFinger():
        if (_touches.length < 2) return;
        final center = _center();
        final ratio = _distance() / gesture.startDistance;
        var kind = gesture.kind;
        if (kind == _TwoFingerKind.undecided) {
          if ((ratio - 1).abs() > 0.12) {
            kind = _TwoFingerKind.zoom;
          } else if ((center - gesture.startCenter).distance > _dragSlop) {
            kind = _TwoFingerKind.scroll;
          }
        }
        if (kind == _TwoFingerKind.zoom) {
          _zoom(gesture, center, ratio);
        } else if (kind == _TwoFingerKind.scroll) {
          _scroll(center - gesture.lastCenter);
        }
        _gesture = gesture.copyWith(kind: kind, lastCenter: center);
      case _Idle():
      case _Done():
        break;
    }
  }

  void _touchUp(int pointer, {required bool cancelled}) {
    if (!_touches.containsKey(pointer)) return;
    _touches.remove(pointer);
    final gesture = _gesture;
    _longPressTimer?.cancel();

    switch (gesture) {
      case _Pending():
        if (!cancelled) _click(0, _normalized(gesture.start));
      case _Dragging():
        send({'t': 'up', 'b': 0, ..._pos(gesture.last)});
      case _TwoFinger():
        final quick = DateTime.now().difference(gesture.time) < _tapTimeout;
        if (!cancelled && quick && gesture.kind == _TwoFingerKind.undecided) {
          _click(1, _normalized(gesture.startCenter));
        }
      case _Idle():
      case _Done():
        break;
    }

    // With fingers still down, ignore them until all lift.
    _gesture = _touches.isEmpty ? const _Idle() : const _Done();
  }

  void _onLongPress(Offset position) {
    if (_gesture is! _Pending) return;
    _click(1, _normalized(position));
    _gesture = const _Done();
  }

  void _click(int button, Offset point) {
    send({'t': 'move', ..._pos(point)});
    send({'t': 'down', 'b': button, ..._pos(point)});
    send({'t': 'up', 'b': button, ..._pos(point)});
  }

  // MARK: Scroll, zoom

  /// [delta] in screen pixels, positive = content follows the fingers down/right.
  void _scroll(Offset delta) {
    final perPixel = (displayPoints != null && videoRect.width > 0)
        ? displayPoints!.width / (videoRect.width * scale)
        : 1.0;
    final points = delta * perPixel;
    if (points == Offset.zero) return;
    send({'t': 'scroll', 'dx': points.dx, 'dy': points.dy});
  }

  void _zoom(_TwoFinger gesture, Offset center, double ratio) {
    final nextScale = (gesture.startScale * ratio).clamp(1.0, _maxScale);
    if (nextScale <= 1.001) fill = false;
    // Keep the content point that was under the fingers at the start under them now.
    final anchor = (gesture.startCenter - gesture.startOffset) / gesture.startScale;
    scale = nextScale;
    offset = _clampOffset(center - anchor * nextScale);
    onViewChanged();
  }

  /// Keeps the video covering the screen along any axis where it's larger than the screen,
  /// and centred along one where it's smaller, so zooming never pans into the black bars.
  Offset _clampOffset(Offset value) {
    double axis(double v, double start, double length, double view) {
      final extent = length * scale;
      if (extent <= view) return (view - extent) / 2 - start * scale;
      return v.clamp(view - (start + length) * scale, -start * scale);
    }

    return Offset(
      axis(value.dx, videoRect.left, videoRect.width, surfaceSize.width),
      axis(value.dy, videoRect.top, videoRect.height, surfaceSize.height),
    );
  }

  // MARK: Helpers

  Offset _normalized(Offset local) {
    if (videoRect.isEmpty) return const Offset(0.5, 0.5);
    final content = (local - offset) / scale;
    // A pointer at the last pixel of the picture maps a little short of the Mac's last pixel, so
    // the Dock and hot corners never trigger: snap the outer 2 pixels to the very edge.
    double edge(double value, double start, double size) {
      final along = value - start;
      if (along <= 2) return 0;
      if (along >= size - 2) return 1;
      return along / size;
    }

    return Offset(edge(content.dx, videoRect.left, videoRect.width), edge(content.dy, videoRect.top, videoRect.height));
  }

  Map<String, double> _pos(Offset normalized) => {'x': normalized.dx, 'y': normalized.dy};

  Offset _center() {
    var sum = Offset.zero;
    for (final p in _touches.values) {
      sum += p;
    }
    return sum / _touches.length.toDouble();
  }

  double _distance() {
    if (_touches.length < 2) return 1;
    final points = _touches.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  /// Flutter button bits -> protocol buttons (0 left, 1 right, 2 middle).
  Iterable<int> _buttonsIn(int bits) sync* {
    if (bits & kPrimaryMouseButton != 0) yield 0;
    if (bits & kSecondaryMouseButton != 0) yield 1;
    if (bits & kMiddleMouseButton != 0) yield 2;
  }
}

// MARK: Gesture states

sealed class _Gesture {
  const _Gesture();
}

class _Idle extends _Gesture {
  const _Idle();
}

/// Everything else is ignored until all fingers lift.
class _Done extends _Gesture {
  const _Done();
}

class _Pending extends _Gesture {
  const _Pending({required this.start});
  final Offset start;
}

class _Dragging extends _Gesture {
  const _Dragging({required this.last});

  /// Last normalized pointer position sent.
  final Offset last;
}

enum _TwoFingerKind { undecided, scroll, zoom }

class _TwoFinger extends _Gesture {
  const _TwoFinger({
    required this.startCenter,
    required this.startDistance,
    required this.startScale,
    required this.startOffset,
    required this.lastCenter,
    required this.time,
    this.kind = _TwoFingerKind.undecided,
  });

  final Offset startCenter;
  final double startDistance;
  final double startScale;
  final Offset startOffset;
  final Offset lastCenter;
  final DateTime time;
  final _TwoFingerKind kind;

  _TwoFinger copyWith({_TwoFingerKind? kind, Offset? lastCenter}) => _TwoFinger(
        startCenter: startCenter,
        startDistance: startDistance,
        startScale: startScale,
        startOffset: startOffset,
        lastCenter: lastCenter ?? this.lastCenter,
        time: time,
        kind: kind ?? this.kind,
      );
}
