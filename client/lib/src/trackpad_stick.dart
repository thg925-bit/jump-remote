import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mac_trackpad.dart';

/// Floating trackpad: a translucent circle with a white nub (same as the web viewer).
///   drag (the finger may leave the circle) = move, tap = click, two taps = double click,
///   hold (blue ring) = right click, hold then drag (blue nub) = drag.
class TrackpadStick extends StatefulWidget {
  const TrackpadStick({
    super.key,
    this.size = 128,
    required this.trackingSpeed,
    required this.onMove,
    required this.onClick,
    required this.onDragStart,
    required this.onDragEnd,
  });

  /// Diameter of the circle; the nub scales with it.
  final double size;

  /// macOS tracking-speed index (see [MacTrackpad.speeds]).
  final double trackingSpeed;

  /// Cursor travel in Mac points.
  final void Function(Offset points) onMove;

  /// 0 = left, 1 = right.
  final void Function(int button) onClick;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  @override
  State<TrackpadStick> createState() => _TrackpadStickState();
}

class _TrackpadStickState extends State<TrackpadStick> {
  static const _moveThreshold = 3.0;
  static const _holdDelay = Duration(milliseconds: 450);
  static const _velocityWindow = Duration(milliseconds: 50);
  static const _nubTravel = 24.0;

  int? _pointer;
  Offset _start = Offset.zero;
  Offset _last = Offset.zero;
  final List<(Duration, Offset)> _samples = [];
  bool _moved = false;
  bool _held = false;
  bool _dragging = false;
  Timer? _holdTimer;
  Offset _lean = Offset.zero;

  @override
  void dispose() {
    _holdTimer?.cancel();
    if (_dragging) widget.onDragEnd();
    super.dispose();
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _start = _last = event.position;
    _samples
      ..clear()
      ..add((event.timeStamp, event.position));
    _moved = _held = _dragging = false;
    _holdTimer = Timer(_holdDelay, () {
      if (_moved || _pointer == null) return;
      HapticFeedback.mediumImpact();
      setState(() => _held = true);
    });
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final delta = event.position - _last;
    _last = event.position;
    _samples.add((event.timeStamp, event.position));
    while (_samples.length > 2 && event.timeStamp - _samples.first.$1 > _velocityWindow) {
      _samples.removeAt(0);
    }

    final offset = event.position - _start;
    if (!_moved) {
      if (offset.distance <= _moveThreshold) return;
      _moved = true;
      _holdTimer?.cancel();
      if (_held) {
        setState(() {
          _held = false;
          _dragging = true;
        });
        widget.onDragStart();
      }
    }

    final (firstTime, firstPosition) = _samples.first;
    final seconds = (event.timeStamp - firstTime).inMicroseconds / 1e6;
    final speed = seconds > 0 ? (event.position - firstPosition).distance / seconds : 0.0;
    final gain = MacTrackpad.gain(pxPerSecond: speed, trackingSpeed: widget.trackingSpeed);
    widget.onMove(delta * gain);

    final lean = math.min(offset.distance, 40) / 40 * _nubTravel * widget.size / 128;
    setState(() => _lean = offset.distance > 0 ? offset / offset.distance * lean : Offset.zero);
  }

  void _end(int pointer, {required bool cancelled}) {
    if (pointer != _pointer) return;
    _holdTimer?.cancel();
    if (_dragging) {
      widget.onDragEnd();
    } else if (!cancelled && !_moved) {
      widget.onClick(_held ? 1 : 0);
    }
    setState(() {
      _pointer = null;
      _held = _dragging = false;
      _lean = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF4F8CFF);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _end(e.pointer, cancelled: false),
      onPointerCancel: (e) => _end(e.pointer, cancelled: true),
      child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.06),
            border: Border.all(color: Colors.white.withValues(alpha: 0.22), width: 1.5),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 6))],
          ),
          alignment: Alignment.center,
          child: Transform.translate(
            offset: _lean,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: widget.size * 0.36,
              height: widget.size * 0.36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _dragging ? accent : Colors.white.withValues(alpha: 0.92),
                border: _held ? Border.all(color: accent, width: 3) : null,
                boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 10, offset: Offset(0, 2))],
              ),
            ),
          ),
        ),
    );
  }
}
