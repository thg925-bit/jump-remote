import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'mac_trackpad.dart';

typedef SendInput = void Function(Map<String, dynamic> message);

/// How a finger on the screen drives the Mac, as in Chrome Remote Desktop.
enum TouchMode {
  /// Tap clicks where touched; hold, then drag = drag; one-finger drag scrolls (moves the view
  /// instead while zoomed in).
  direct,

  /// The whole screen is a trackpad: drag moves the cursor, tap clicks at the cursor; hold,
  /// then drag = drag.
  trackpad,
}

/// Turns raw pointer events on the viewer surface into input messages, and owns the client-side
/// zoom (`screen = offset + scale * content`). Mouse, trackpad and pen map directly. Touch
/// follows [mode]; in both modes two-finger tap = right click, three-finger tap = middle click,
/// two-finger drag = scroll and pinch = zoom.
class PointerInput {
  PointerInput({required this.send, required this.onViewChanged, this.cursor, this.moveCursorBy, this.onHold});

  final SendInput send;

  /// Called when zoom/pan changes so the viewer repaints.
  final VoidCallback onViewChanged;

  /// Where the Mac's cursor is (normalized): trackpad clicks happen there.
  final Offset Function()? cursor;

  /// Moves the Mac's cursor by a distance in Mac points (trackpad mode).
  final void Function(Offset points)? moveCursorBy;

  /// A touch now holds the mouse button down (for haptic feedback).
  final VoidCallback? onHold;

  TouchMode mode = TouchMode.direct;

  /// macOS tracking-speed index for trackpad mode (see [MacTrackpad.speeds]).
  double trackingSpeed = 1.0;

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
  static const _threeTapTimeout = Duration(milliseconds: 400);
  static const _maxScale = 6.0;

  /// A quick tap this close to the previous one lands exactly on it (direct mode), so the Mac
  /// sees a double click: fingers never hit the same pixel twice.
  static const _doubleTapTimeout = Duration(milliseconds: 500);
  static const _doubleTapSlop = 25.0;

  final Map<int, Offset> _touches = {};
  final Map<int, Offset> _touchStarts = {};
  _Gesture _gesture = const _Idle();
  Timer? _longPressTimer;
  ({DateTime time, Offset local, Offset point})? _lastTap;

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

  /// Drops the touch gesture without leaving the mouse button down on the Mac (the app went to
  /// the background, the mode changed).
  void cancelGesture() {
    _longPressTimer?.cancel();
    _endHeld();
    _touches.clear();
    _touchStarts.clear();
    _gesture = const _Idle();
  }

  void setMode(TouchMode next) {
    if (next == mode) return;
    cancelGesture();
    _lastTap = null;
    mode = next;
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
    _touchDown(event.pointer, event.localPosition, event.timeStamp);
  }

  void pointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      send({'t': 'move', ..._pos(_normalized(event.localPosition))});
      return;
    }
    _touchMove(event.pointer, event.localPosition, event.timeStamp);
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

  void _touchDown(int pointer, Offset position, Duration time) {
    _touches[pointer] = position;
    _touchStarts[pointer] = position;
    final gesture = _gesture;
    if (_touches.length == 1) {
      _gesture = _Pending(start: position, samples: [(time, position)]);
      _longPressTimer?.cancel();
      _longPressTimer = Timer(_longPress, _onLongPress);
    } else if (_touches.length == 2) {
      _longPressTimer?.cancel();
      // A second finger during a one-finger gesture: that one ends, and this is no tap.
      final interrupted = gesture is! _Pending && gesture is! _Idle;
      _endHeld();
      _gesture = _TwoFinger(
        startCenter: _center(),
        startDistance: math.max(_distance(), 1),
        startScale: scale,
        startOffset: offset,
        lastCenter: _center(),
        time: DateTime.now(),
        moved: interrupted,
      );
    } else if (_touches.length == 3 && gesture is _TwoFinger && !gesture.moved) {
      _gesture = _ThreeFinger(time: gesture.time, center: _center());
    } else {
      // More fingers, or a third one mid-gesture: drop it rather than guess.
      _endHeld();
      _gesture = const _Done();
    }
  }

  void _touchMove(int pointer, Offset position, Duration time) {
    if (!_touches.containsKey(pointer)) return;
    _touches[pointer] = position;
    var gesture = _gesture;

    if (gesture is _Pending) {
      if ((position - gesture.start).distance <= _dragSlop) return;
      _longPressTimer?.cancel();
      if (mode == TouchMode.trackpad) {
        gesture = _Track(last: gesture.start, samples: gesture.samples);
      } else if (isZoomed) {
        gesture = _Pan(last: gesture.start);
      } else {
        _moveTo(_normalized(gesture.start)); // so the window under the finger is the one that scrolls
        gesture = _ScrollOne(last: gesture.start);
      }
      _gesture = gesture;
    }

    switch (gesture) {
      case _Track():
        _trackBy(gesture, position, time);
      case _Held():
        if (mode == TouchMode.trackpad) {
          _trackBy(gesture, position, time);
        } else {
          gesture.point = _normalized(position);
          _moveTo(gesture.point);
        }
      case _Pan():
        offset = _clampOffset(offset + (position - gesture.last));
        gesture.last = position;
        onViewChanged();
      case _ScrollOne():
        _scroll(position - gesture.last);
        gesture.last = position;
      case _TwoFinger():
        if (_touches.length < 2) return;
        final center = _center();
        final ratio = _distance() / gesture.startDistance;
        if (gesture.kind == _TwoFingerKind.undecided) {
          if ((ratio - 1).abs() > 0.12) {
            gesture.kind = _TwoFingerKind.zoom;
          } else if ((center - gesture.startCenter).distance > _dragSlop) {
            gesture.kind = _TwoFingerKind.scroll;
            if (mode == TouchMode.direct) _moveTo(_normalized(gesture.startCenter));
          } else {
            return;
          }
          gesture.moved = true;
        }
        if (gesture.kind == _TwoFingerKind.zoom) {
          _zoom(gesture, center, ratio);
        } else {
          _scroll(center - gesture.lastCenter);
        }
        gesture.lastCenter = center;
      case _ThreeFinger():
        final start = _touchStarts[pointer];
        if (start != null && (position - start).distance > _dragSlop) gesture.moved = true;
      case _Pending():
      case _Idle():
      case _Done():
        break;
    }
  }

  void _touchUp(int pointer, {required bool cancelled}) {
    if (!_touches.containsKey(pointer)) return;
    _touches.remove(pointer);
    _touchStarts.remove(pointer);
    _longPressTimer?.cancel();
    final gesture = _gesture;

    if (cancelled) {
      _endHeld();
    } else {
      switch (gesture) {
        case _Pending():
          _tap(gesture.start);
        case _Held():
          _endHeld();
        case _TwoFinger():
          final quick = DateTime.now().difference(gesture.time) < _tapTimeout;
          if (quick && !gesture.moved) _clickAt(1, gesture.startCenter);
        case _ThreeFinger():
          final quick = DateTime.now().difference(gesture.time) < _threeTapTimeout;
          if (quick && !gesture.moved) _clickAt(2, gesture.center);
        default:
          break;
      }
    }

    // With fingers still down, ignore them until all lift.
    _gesture = _touches.isEmpty ? const _Idle() : const _Done();
  }

  /// Held still: press the left button and keep it down (direct mode: where the finger is);
  /// moving on drags, lifting lets go.
  void _onLongPress() {
    final gesture = _gesture;
    if (gesture is! _Pending) return;
    _lastTap = null;
    final point = mode == TouchMode.direct ? _normalized(gesture.start) : _cursor;
    if (mode == TouchMode.direct) _moveTo(point);
    send({'t': 'down', 'b': 0, 'c': 1, ..._pos(point)});
    _gesture = _Held(point: point, last: gesture.start, samples: gesture.samples);
    onHold?.call();
  }

  /// Lets go of the button a held touch keeps down, if any.
  void _endHeld() {
    final gesture = _gesture;
    if (gesture is! _Held) return;
    _gesture = const _Done();
    send({'t': 'up', 'b': 0, ..._pos(mode == TouchMode.direct ? gesture.point : _cursor)});
  }

  /// One-finger tap: at the cursor (trackpad), or where touched, snapped onto the previous tap
  /// when it is a quick second one close by.
  void _tap(Offset local) {
    if (mode == TouchMode.trackpad) {
      _clickAt(0, local);
      return;
    }
    final now = DateTime.now();
    var point = _normalized(local);
    final last = _lastTap;
    if (last != null && now.difference(last.time) < _doubleTapTimeout && (local - last.local).distance <= _doubleTapSlop) {
      point = last.point;
      _lastTap = (time: now, local: last.local, point: last.point);
    } else {
      _lastTap = (time: now, local: local, point: point);
    }
    _click(0, point);
  }

  /// A click with [button] (0 left, 1 right, 2 middle): where the fingers are, or at the cursor
  /// in trackpad mode.
  void _clickAt(int button, Offset local) {
    if (button != 0) _lastTap = null;
    if (mode == TouchMode.trackpad) {
      final point = _cursor;
      send({'t': 'down', 'b': button, ..._pos(point)}); // two taps in a row: the Mac counts a double click
      send({'t': 'up', 'b': button, ..._pos(point)});
    } else {
      _click(button, _normalized(local));
    }
  }

  void _click(int button, Offset point) {
    _moveTo(point);
    send({'t': 'down', 'b': button, ..._pos(point)});
    send({'t': 'up', 'b': button, ..._pos(point)});
  }

  void _moveTo(Offset point) => send({'t': 'move', ..._pos(point)});

  Offset get _cursor => cursor?.call() ?? const Offset(0.5, 0.5);

  /// Trackpad: moves the cursor by the finger's travel through macOS's pointer acceleration.
  void _trackBy(_Tracking gesture, Offset position, Duration time) {
    final delta = position - gesture.last;
    gesture.last = position;
    final samples = gesture.samples..add((time, position));
    while (samples.length > 2 && time - samples.first.$1 > const Duration(milliseconds: 50)) {
      samples.removeAt(0);
    }
    final (firstTime, firstPosition) = samples.first;
    final seconds = (time - firstTime).inMicroseconds / 1e6;
    final speed = seconds > 0 ? (position - firstPosition).distance / seconds : 0.0;
    final gain = MacTrackpad.gain(pxPerSecond: speed, trackingSpeed: trackingSpeed);
    moveCursorBy?.call(delta * gain);
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

/// One finger down, not yet a tap, a hold or a drag.
class _Pending extends _Gesture {
  _Pending({required this.start, required this.samples});
  final Offset start;
  final List<(Duration, Offset)> samples;
}

/// A one-finger gesture that moves the cursor like a trackpad.
sealed class _Tracking extends _Gesture {
  _Tracking({required this.last, required this.samples});
  Offset last;
  final List<(Duration, Offset)> samples;
}

/// Trackpad mode: the finger moves the cursor.
class _Track extends _Tracking {
  _Track({required super.last, required super.samples});
}

/// The left button is down (after a hold); moving drags.
class _Held extends _Tracking {
  _Held({required this.point, required super.last, required super.samples});

  /// Direct mode: where the button went down / the finger is now (normalized).
  Offset point;
}

/// Direct mode, zoomed in: one finger moves the view.
class _Pan extends _Gesture {
  _Pan({required this.last});
  Offset last;
}

/// Direct mode: one finger scrolls.
class _ScrollOne extends _Gesture {
  _ScrollOne({required this.last});
  Offset last;
}

enum _TwoFingerKind { undecided, scroll, zoom }

class _TwoFinger extends _Gesture {
  _TwoFinger({
    required this.startCenter,
    required this.startDistance,
    required this.startScale,
    required this.startOffset,
    required this.lastCenter,
    required this.time,
    required this.moved,
  });

  final Offset startCenter;
  final double startDistance;
  final double startScale;
  final Offset startOffset;
  final DateTime time;
  Offset lastCenter;
  bool moved;
  _TwoFingerKind kind = _TwoFingerKind.undecided;
}

class _ThreeFinger extends _Gesture {
  _ThreeFinger({required this.time, required this.center});
  final DateTime time;
  final Offset center;
  bool moved = false;
}
