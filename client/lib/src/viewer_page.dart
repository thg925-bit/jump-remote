import 'dart:math' as math;

import 'dart:io' show Platform;
import 'dart:async' show unawaited;
import 'dart:convert' show utf8;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'hid.dart';
import 'mac_trackpad.dart';
import 'pointer_input.dart';
import 'session.dart';
import 'settings_dialog.dart';
import 'trackpad_stick.dart';
import 'viewer_layout.dart';

/// Full-screen remote view. Pops with an error message (or null) when the session ends.
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.session});

  final Session session;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  /// The hidden text field always holds this, so a soft-keyboard backspace on an
  /// "empty" field still produces a change we can see.
  static const _sentinel = ' ';

  late final PointerInput _pointer = PointerInput(
    // Moves go through the session so our drawn cursor follows instantly.
    send: (message) {
      if (message['t'] == 'move') {
        _session.moveCursor(Offset((message['x'] as num).toDouble(), (message['y'] as num).toDouble()));
      } else {
        _session.sendInput(message);
      }
    },
    onViewChanged: () {
      if (mounted) setState(() {});
    },
  );
  final _keyFocus = FocusNode(debugLabel: 'hardware-keys');
  final _textFocus = FocusNode(debugLabel: 'soft-keyboard');
  final _text = TextEditingController(text: _sentinel);

  /// Soft keyboard: 'direct' types straight onto the Mac as you go (like Chrome Remote Desktop);
  /// 'compose' writes into a box above the keyboard first and sends it with 전송.
  String _keyboardMode = 'direct';
  final _composeFocus = FocusNode(debugLabel: 'compose');
  final _compose = TextEditingController();
  final _keyboardBarKey = GlobalKey();
  double _keyboardBarHeight = 56;

  /// Lengths (in characters) of what 전송 put on the Mac, newest last, so ✕ can take it back
  /// with Backspace. Forgotten as soon as the Mac is clicked (the cursor may have moved).
  final List<int> _sentChunks = [];
  bool get _keyboardOn => _textFocus.hasFocus || _composeFocus.hasFocus;
  bool _resettingText = false;
  String _composingPreview = '';
  bool _showStats = false;
  bool _swallowPasteKey = false;

  /// Hardware keyboard: Ctrl goes to the Mac as ⌘ (PC habits: Ctrl+C, Ctrl+V, Ctrl+A).
  bool _ctrlAsCmd = true;
  final Set<int> _stickyModifiers = {};
  bool _popped = false;

  /// Where the trackpad stick sits: 'right', 'left' or 'hidden'.
  String _stickPlacement = 'right';

  /// Key into [MacTrackpad.speeds].
  String _speed = 'normal';
  static const _placements = ['right', 'left', 'hidden'];
  static const _placementLabels = {'right': '오른쪽', 'left': '왼쪽', 'hidden': '끔'};

  /// Screen rotation inside the viewer: 'auto', 'landscape' or 'portrait'.
  String _rotation = 'auto';
  static const _rotations = ['auto', 'landscape', 'portrait'];
  static const _rotationLabels = {'auto': '자동', 'landscape': '가로', 'portrait': '세로'};
  static const _orientationChannel = MethodChannel('jump/orientation');

  /// Where the user dragged the stick (its centre, as a fraction of the screen); null = auto,
  /// which puts it in the black bar beside the video when there is one.
  Offset? _stickCustom;

  /// Where the user dropped the toolbar (its centre, as a fraction of the screen); null = auto.
  Offset? _toolbarCustom;
  bool _toolbarMoving = false;
  Offset _toolbarGrab = Offset.zero;
  Offset _toolbarPressStart = Offset.zero;
  final _toolbarKey = GlobalKey();
  Size _viewSize = Size.zero;

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _session.onMacCopied = _onMacCopied;
    _session.renderer.onResize = () {
      if (mounted) setState(() {});
    };
    _text.addListener(_onTextChanged);
    _session.cursor.addListener(_followCursor);
    _textFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _composeFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _compose.addListener(() {
      if (mounted) setState(() {}); // 전송 enables with text
    });
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _stickPlacement = _placements.contains(prefs.getString('jump.stick'))
            ? prefs.getString('jump.stick')!
            : 'right';
        _speed = MacTrackpad.speeds.containsKey(prefs.getString('jump.speed'))
            ? prefs.getString('jump.speed')!
            : 'normal';
        _rotation = _rotations.contains(prefs.getString('jump.rotation')) ? prefs.getString('jump.rotation')! : 'auto';
        _pointer.fill = prefs.getBool('jump.fill') ?? false;
        _session.shareClipboard = prefs.getBool('jump.clip') ?? true;
        _ctrlAsCmd = prefs.getBool('jump.ctrlAsCmd') ?? true;
        _keyboardMode = prefs.getString('jump.keyboardMode') == 'compose' ? 'compose' : 'direct';
        final x = prefs.getDouble('jump.stickX'), y = prefs.getDouble('jump.stickY');
        _stickCustom = x != null && y != null ? Offset(x, y) : null;
        final tx = prefs.getDouble('jump.toolbarX'), ty = prefs.getDouble('jump.toolbarY');
        _toolbarCustom = tx != null && ty != null ? Offset(tx, ty) : null;
      });
      _applyRotation();
    });
  }

  /// Rotation applies to this app only; leaving the viewer hands it back to the phone.
  Future<void> _applyRotation([String? rotation]) async {
    if (Platform.isAndroid) {
      await _orientationChannel.invokeMethod('set', rotation ?? _rotation);
      return;
    }
    await SystemChrome.setPreferredOrientations(switch (rotation ?? _rotation) {
      'landscape' => [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      'portrait' => [DeviceOrientation.portraitUp],
      _ => [],
    });
  }

  Future<void> _savePreference(String key, String value) async {
    (await SharedPreferences.getInstance()).setString(key, value);
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _session.onMacCopied = null;
    _session.cursor.removeListener(_followCursor);
    _session.renderer.onResize = null;
    _releaseStickyModifiers(rebuild: false);
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _applyRotation('system');
    _keyFocus.dispose();
    _textFocus.dispose();
    _composeFocus.dispose();
    _compose.dispose();
    _text.dispose();
    super.dispose();
  }

  /// Zoomed in, the view pans to keep the cursor on screen.
  void _followCursor() => _pointer.follow(_session.cursor.value);

  void _onSessionChanged() {
    if (!mounted) return;
    _pointer.displayPoints = _session.displayPoints;
    if (_session.phase == SessionPhase.closed) {
      _leave(_session.error);
      return;
    }
    setState(() {});
  }

  void _leave([String? error]) {
    if (_popped) return;
    _popped = true;
    // Close the settings dialog first if it is open.
    Navigator.of(context)
      ..popUntil((route) => route is! PopupRoute)
      ..pop(error);
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(
        session: _session,
        showStats: _showStats,
        onShowStats: (on) => setState(() => _showStats = on),
        onShareClipboard: (on) {
          _session.shareClipboard = on;
          SharedPreferences.getInstance().then((prefs) => prefs.setBool('jump.clip', on));
        },
        ctrlAsCmd: _ctrlAsCmd,
        onCtrlAsCmd: (on) {
          // Nothing left held under the old mapping.
          for (final code in [Hid.leftControl, Hid.rightControl, Hid.leftMeta, Hid.rightMeta]) {
            _session.sendInput({'t': 'key', 'code': code, 'down': false});
          }
          setState(() => _ctrlAsCmd = on);
          SharedPreferences.getInstance().then((prefs) => prefs.setBool('jump.ctrlAsCmd', on));
        },
      ),
    );
  }

  int _displayIndex() => math.max(0, _session.displays.indexWhere((d) => d.id == _session.currentDisplay));

  void _nextDisplay() {
    final name = _session.selectNextDisplay();
    if (name != null) _notice('🖥 $name');
  }

  void _notice(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          width: 320,
        ),
      );
  }

  /// The Mac copied text: put it on this phone's clipboard.
  void _onMacCopied(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    if (mounted) _notice('📋 Mac에서 복사한 내용을 가져왔습니다');
  }

  /// Cmd/Ctrl+V on a hardware keyboard: send what was copied here first, so the Mac pastes it.
  Future<void> _pasteFromDevice(int vUsage) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isNotEmpty && !_session.sendClipboard(text) && utf8.encode(text).length > Session.maxClipBytes) {
      if (mounted) _notice('복사한 내용이 너무 커서 Mac으로 보내지 않았습니다');
    }
    _session.sendInput({'t': 'key', 'code': vUsage, 'down': true});
    _session.sendInput({'t': 'key', 'code': vUsage, 'down': false});
  }

  // MARK: Build

  @override
  Widget build(BuildContext context) {
    final connected = _session.phase == SessionPhase.connected;
    final keyboardOn = _keyboardOn;
    final barHeight = keyboardOn ? _keyboardBarHeight : 0.0;
    if (keyboardOn) WidgetsBinding.instance.addPostFrameCallback((_) => _measureKeyboardBar());

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _popped = true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: true,
        body: Focus(
          focusNode: _keyFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              _viewSize = size;
              final layout = ViewerLayout.compute(
                size: size,
                video: _fitRect(size),
                zoomed: _pointer.isZoomed,
                stickOnRight: _stickOnRight(size),
                custom: _stickCustom,
                bottomInset: MediaQuery.paddingOf(context).bottom,
                keyboardLift: barHeight,
              );
              final landscape = layout.landscape;
              return Stack(
                children: [
                  Positioned.fill(child: _surface(size)),
                  Positioned(
                    left: 0,
                    bottom: 0,
                    width: 1,
                    height: 1,
                    child: Opacity(opacity: 0, child: _hiddenTextField()),
                  ),
                  if (_composingPreview.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: keyboardOn ? barHeight + 4 : 16,
                      child: Center(child: _chip(_composingPreview)),
                    ),
                  if (connected && _stickPlacement != 'hidden') _stick(size, layout.stick),
                  if (keyboardOn) Positioned(left: 0, right: 0, bottom: 0, child: _keyboardBar()),
                  _toolbar(layout),
                  if (_showStats && _session.statsText.isNotEmpty)
                    SafeArea(
                      child: Align(
                        alignment: landscape && _stickPlacement == 'left'
                            ? Alignment.bottomRight
                            : Alignment.bottomLeft,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(landscape ? 76 : 8, 8, landscape ? 76 : 8, barHeight + 8),
                          child: _statsBox(),
                        ),
                      ),
                    ),
                  if (!connected) Positioned.fill(child: _connectingOverlay()),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Where the whole Mac screen sits when fitted (letterboxed) into [size].
  Rect _fitRect(Size size) {
    final videoWidth = _session.renderer.videoWidth.toDouble();
    final videoHeight = _session.renderer.videoHeight.toDouble();
    if (videoWidth <= 0 || videoHeight <= 0) return Rect.zero;
    final fit = math.min(size.width / videoWidth, size.height / videoHeight);
    final width = videoWidth * fit, height = videoHeight * fit;
    return Rect.fromLTWH((size.width - width) / 2, (size.height - height) / 2, width, height);
  }

  Widget _surface(Size size) {
    final renderer = _session.renderer;
    final videoRect = _fitRect(size);
    _pointer
      ..surfaceSize = size
      ..videoRect = videoRect
      ..refit();

    final transform = Matrix4.translationValues(_pointer.offset.dx, _pointer.offset.dy, 0)
      ..multiply(Matrix4.diagonal3Values(_pointer.scale, _pointer.scale, 1));

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _forgetSent(); // a click on the Mac may move its cursor away from what was sent
        _pointer.pointerDown(event);
      },
      onPointerMove: _pointer.pointerMove,
      onPointerUp: _pointer.pointerUp,
      onPointerCancel: _pointer.pointerCancel,
      onPointerHover: _pointer.pointerHover,
      onPointerSignal: _pointer.pointerSignal,
      onPointerPanZoomUpdate: _pointer.panZoomUpdate,
      child: ClipRect(
        child: Transform(
          transform: transform,
          child: Stack(
            children: [
              if (!videoRect.isEmpty)
                Positioned.fromRect(
                  rect: videoRect,
                  child: RTCVideoView(renderer, filterQuality: FilterQuality.medium),
                ),
              if (!videoRect.isEmpty) _cursorOverlay(videoRect),
            ],
          ),
        ),
      ),
    );
  }

  /// A toolbar dragged to the stick's side takes that side; the stick moves to the other one
  /// (unless the stick itself was dragged somewhere).
  bool _stickOnRight(Size size) {
    final onRight = _stickPlacement != 'left';
    final custom = _toolbarCustom;
    if (custom == null || _stickCustom != null) return onRight;
    final edge = ToolbarPlacement.nearestEdge(Offset(custom.dx * size.width, custom.dy * size.height), size);
    if (edge == ToolbarEdge.right && onRight) return false;
    if (edge == ToolbarEdge.left && !onRight) return true;
    return onRight;
  }

  /// The Mac's cursor, drawn here (the host leaves it out of the video).
  Widget _cursorOverlay(Rect videoRect) {
    return ValueListenableBuilder<CursorShape?>(
      valueListenable: _session.cursorShape,
      builder: (context, shape, _) {
        if (shape == null) return const SizedBox.shrink();
        return ValueListenableBuilder<Offset>(
          valueListenable: _session.cursor,
          builder: (context, position, _) {
            final display = _session.displayPoints ?? const Size(1470, 956);
            final k = videoRect.width / display.width;
            return Positioned(
              left: videoRect.left + position.dx * videoRect.width - shape.hotSpot.dx * k,
              top: videoRect.top + position.dy * videoRect.height - shape.hotSpot.dy * k,
              width: shape.size.width * k,
              height: shape.size.height * k,
              child: IgnorePointer(
                child: Image.memory(shape.png, gaplessPlayback: true, filterQuality: FilterQuality.medium),
              ),
            );
          },
        );
      },
    );
  }

  Map<String, double> _cursorPosition() {
    final p = _session.cursor.value;
    return {'x': p.dx, 'y': p.dy};
  }

  void _clickAtCursor(int button) {
    _forgetSent();
    final position = _cursorPosition();
    _session.sendInput({'t': 'down', 'b': button, ...position});
    _session.sendInput({'t': 'up', 'b': button, ...position});
  }

  String get _deviceLabel => Platform.isAndroid ? '폰' : '아이패드';

  /// Landscape: a column in the black bar opposite the stick. Portrait: a row across the top.
  /// Solid when it sits in a bar, translucent when it has to overlap the Mac screen.
  Widget _toolbar(ViewerLayout layout) {
    final muted = _session.audio.muted;
    final items = <_ToolItem>[
      _ToolItem(
        Icons.mouse,
        _stickCustom != null && _stickPlacement != 'hidden' ? '직접' : _placementLabels[_stickPlacement]!,
        _stickPlacement != 'hidden',
        _cycleStick,
      ),
      _ToolItem(Icons.screen_rotation, _rotationLabels[_rotation]!, _rotation != 'auto', _cycleRotation),
      if (_session.displays.length > 1)
        _ToolItem(Icons.monitor, '모니터\n${_displayIndex() + 1}/${_session.displays.length}', false, _nextDisplay),
      _ToolItem(
        _pointer.fill ? Icons.crop_free : Icons.fit_screen,
        _pointer.fill ? '채움' : '맞춤',
        _pointer.fill,
        _toggleFill,
      ),
      _ToolItem(Icons.keyboard, '키보드', _keyboardOn, _toggleKeyboard),
      // Names where sound comes out; the host mutes the Mac while we play.
      _ToolItem(
        muted ? Icons.laptop_mac : Icons.volume_up,
        muted ? '${_session.macLabel}\n재생' : '$_deviceLabel\n재생',
        !muted,
        _toggleSound,
      ),
      if (_pointer.isZoomed && !_pointer.fill) _ToolItem(Icons.zoom_in_map, '원래\n크기', false, _pointer.resetZoom),
      _ToolItem(Icons.settings, '설정', false, _openSettings),
      _ToolItem(Icons.close, '끊기', false, () => _leave()),
    ];
    final size = _viewSize;
    final safe = MediaQuery.paddingOf(context);
    final bounds = Rect.fromLTRB(
      safe.left,
      safe.top,
      size.width - safe.right,
      size.height - safe.bottom - (_keyboardOn ? _keyboardBarHeight : 0), // above the keyboard bar
    );
    final stick = _stickPlacement == 'hidden' ? null : layout.stick;

    // One clean line along an edge: where it was dragged (the nearest of the four edges; it
    // follows the finger while moving), else the side opposite the stick in landscape and the top
    // in portrait (a top row in landscape would cover the Mac's menu bar).
    final ToolbarEdge edge;
    final Offset along;
    if (_toolbarCustom != null) {
      along = Offset(_toolbarCustom!.dx * size.width, _toolbarCustom!.dy * size.height);
      edge = ToolbarPlacement.nearestEdge(along, size);
    } else if (layout.landscape) {
      edge = layout.toolbarOnLeft ? ToolbarEdge.left : ToolbarEdge.right;
      along = bounds.center;
    } else {
      edge = ToolbarEdge.top;
      along = bounds.topCenter;
    }
    final place = ToolbarPlacement.compute(
      edge: edge,
      count: items.length,
      bounds: bounds,
      along: along,
      avoid: stick,
      floating: _toolbarMoving,
    );

    final tiles = [for (final item in items) _tile(item, place)];
    final lines = [
      for (var i = 0; i < place.lines; i++)
        Flex(
          direction: place.vertical ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          children: tiles.skip(i * place.perLine).take(place.perLine).toList(),
        ),
    ];
    // Translucent: the Mac screen shows through where it overlaps.
    const panel = BoxDecoration(
      color: Color(0xB8161A20),
      borderRadius: BorderRadius.all(Radius.circular(14)),
      border: Border.fromBorderSide(BorderSide(color: Color(0x33FFFFFF), width: 0.5)),
    );
    final decoration = _toolbarMoving
        ? panel.copyWith(color: const Color(0xE6161A20), border: Border.all(color: const Color(0xFF4F8CFF), width: 2))
        : panel;

    // Long-press to move it (drag), or long-press and let go to put it back automatically.
    return AnimatedPositioned(
      duration: _toolbarMoving ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      left: place.rect.left,
      top: place.rect.top,
      width: place.rect.width,
      height: place.rect.height,
      child: GestureDetector(
        key: _toolbarKey,
        onLongPressStart: _toolbarLongPressStart,
        onLongPressMoveUpdate: _toolbarLongPressMove,
        onLongPressEnd: _toolbarLongPressEnd,
        child: DecoratedBox(
          decoration: decoration,
          child: Center(
            child: Flex(
              direction: place.vertical ? Axis.horizontal : Axis.vertical,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines,
            ),
          ),
        ),
      ),
    );
  }

  void _toolbarLongPressStart(LongPressStartDetails details) {
    HapticFeedback.mediumImpact();
    final box = _toolbarKey.currentContext?.findRenderObject() as RenderBox?;
    final center = box == null ? details.globalPosition : box.localToGlobal(box.size.center(Offset.zero));
    _toolbarGrab = details.globalPosition - center;
    _toolbarPressStart = details.globalPosition;
    setState(() => _toolbarMoving = true);
  }

  void _toolbarLongPressMove(LongPressMoveUpdateDetails details) {
    if (details.offsetFromOrigin.distance < 8 || _viewSize.isEmpty) return;
    final center = details.globalPosition - _toolbarGrab;
    setState(
      () => _toolbarCustom = Offset(
        (center.dx / _viewSize.width).clamp(0.05, 0.95),
        (center.dy / _viewSize.height).clamp(0.05, 0.95),
      ),
    );
  }

  void _toolbarLongPressEnd(LongPressEndDetails details) {
    final heldStill = (details.globalPosition - _toolbarPressStart).distance < 8;
    setState(() {
      _toolbarMoving = false;
      if (heldStill) _toolbarCustom = null; // long-press without dragging: back to automatic
    });
    final custom = _toolbarCustom;
    SharedPreferences.getInstance().then((prefs) {
      if (custom == null) {
        prefs.remove('jump.toolbarX');
        prefs.remove('jump.toolbarY');
      } else {
        prefs.setDouble('jump.toolbarX', custom.dx);
        prefs.setDouble('jump.toolbarY', custom.dy);
      }
    });
  }

  /// Icon with a short label under it, or just the icon when [place] is compact; highlighted
  /// when active. Every button is the same size (so columns and rows line up), and a long label
  /// shrinks to fit instead of spilling over.
  Widget _tile(_ToolItem item, ToolbarPlacement place) {
    final color = item.active ? Colors.white : Colors.white70;
    final size = place.buttonSize;
    final gap = 2 * place.scale;
    final Widget face = place.compact
        ? Icon(item.icon, size: 22 * place.scale, color: color)
        : Padding(
            padding: EdgeInsets.fromLTRB(3 * place.scale, 5 * place.scale, 3 * place.scale, 3 * place.scale),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(item.icon, size: 20 * place.scale, color: color),
                SizedBox(height: 2 * place.scale),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      item.label,
                      textAlign: TextAlign.center,
                      softWrap: false,
                      style: TextStyle(fontSize: 10.5, height: 1.15, color: color),
                    ),
                  ),
                ),
              ],
            ),
          );
    return Padding(
      padding: EdgeInsets.all(gap),
      child: Semantics(
        label: item.label.replaceAll('\n', ' '),
        button: true,
        child: Material(
          color: item.active ? const Color(0xFF4F8CFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10 * place.scale),
          child: InkWell(
            borderRadius: BorderRadius.circular(10 * place.scale),
            onTap: item.onTap,
            child: SizedBox(width: size.width - 2 * gap, height: size.height - 2 * gap, child: Center(child: face)),
          ),
        ),
      ),
    );
  }

  void _cycleStick() {
    final next = _placements[(_placements.indexOf(_stickPlacement) + 1) % _placements.length];
    setState(() {
      _stickPlacement = next;
      _stickCustom = null; // back to automatic placement
    });
    _savePreference('jump.stick', next);
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove('jump.stickX');
      prefs.remove('jump.stickY');
    });
  }

  void _cycleRotation() {
    final next = _rotations[(_rotations.indexOf(_rotation) + 1) % _rotations.length];
    setState(() => _rotation = next);
    _savePreference('jump.rotation', next);
    _applyRotation();
  }

  void _toggleFill() {
    _pointer.setFill(!_pointer.fill, _session.cursor.value);
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('jump.fill', _pointer.fill));
  }

  void _toggleSound() {
    setState(() => _session.audio.muted = !_session.audio.muted);
    _session.reportAudio();
  }

  /// The trackpad stick at [rect] (see [ViewerLayout]), with a handle to drag it elsewhere.
  Widget _stick(Size size, Rect rect) {
    final center = rect.center;
    final diameter = rect.width;
    return Positioned(
      left: center.dx - diameter / 2,
      top: center.dy - diameter / 2,
      width: diameter,
      height: diameter,
      child: Stack(
        children: [
          TrackpadStick(
            size: diameter,
            trackingSpeed: MacTrackpad.speeds[_speed]!.$2,
            onMove: _session.moveCursorBy,
            onClick: _clickAtCursor,
            onDragStart: () => _session.sendInput({'t': 'down', 'b': 0, 'c': 1, ..._cursorPosition()}),
            onDragEnd: () => _session.sendInput({'t': 'up', 'b': 0, ..._cursorPosition()}),
          ),
          // Move handle in the square's corner, outside the circle's touch area.
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              onPanUpdate: (details) {
                final moved = center + details.delta;
                setState(() => _stickCustom = Offset(moved.dx / size.width, moved.dy / size.height));
              },
              onPanEnd: (_) => SharedPreferences.getInstance().then((prefs) {
                prefs.setDouble('jump.stickX', _stickCustom!.dx);
                prefs.setDouble('jump.stickY', _stickCustom!.dy);
              }),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xE6161A20),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(Icons.open_with, size: 16, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Above the soft keyboard: the mode switch, then either the extra keys (direct typing) or the
  /// compose box with 전송.
  Widget _keyboardBar() {
    final direct = _keyboardMode == 'direct';
    return Container(
      key: _keyboardBarKey,
      color: const Color(0xF0161A20),
      padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _modeSwitch(),
          const SizedBox(width: 6),
          Expanded(child: direct ? _extraKeys() : _composeField()),
          if (!direct) ...[
            const SizedBox(width: 6),
            _barButton('✕', _eraseLastSent, enabled: _sentChunks.isNotEmpty),
            _barButton('전송', _sendCompose, primary: true, enabled: _compose.text.isNotEmpty),
            _barButton('⏎', () => _typeKey(Hid.enter)),
          ],
        ],
      ),
    );
  }

  /// "바로 | 입력창": how the soft keyboard types. Not a button, so it never takes the focus
  /// (which would close the keyboard).
  Widget _modeSwitch() {
    Widget segment(String mode, String label) {
      final on = _keyboardMode == mode;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _setKeyboardMode(mode),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
          decoration: BoxDecoration(
            color: on ? const Color(0xFF4F8CFF) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(label, style: TextStyle(fontSize: 13, color: on ? Colors.white : Colors.white70)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: const Color(0xFF232932), borderRadius: BorderRadius.circular(9)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [segment('direct', '바로'), segment('compose', '입력창')]),
    );
  }

  void _setKeyboardMode(String mode) {
    if (mode == _keyboardMode) return;
    HapticFeedback.selectionClick();
    setState(() => _keyboardMode = mode);
    _savePreference('jump.keyboardMode', mode);
    if (mode == 'compose') {
      _composeFocus.requestFocus();
    } else {
      _resetText();
      _textFocus.requestFocus();
    }
  }

  Widget _composeField() {
    return TextField(
      controller: _compose,
      focusNode: _composeFocus,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      minLines: 1,
      maxLines: 3,
      style: const TextStyle(fontSize: 16, color: Colors.white),
      decoration: const InputDecoration(
        isDense: true,
        hintText: '여기에 쓰고 전송 → Mac 커서 위치에 입력',
        hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
        filled: true,
        fillColor: Color(0xFF0B0D10),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(8)), borderSide: BorderSide.none),
      ),
    );
  }

  Widget _barButton(String label, VoidCallback onTap, {bool primary = false, bool enabled = true}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onTap();
            }
          : null,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: primary ? const Color(0xFF4F8CFF).withValues(alpha: enabled ? 1 : 0.4) : const Color(0xFF232932),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: const TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.w600)),
      ),
    );
  }

  /// Compose mode: the whole text goes to where the Mac's cursor is (pasted, so line breaks stay
  /// line breaks instead of pressing Return).
  void _sendCompose() {
    final text = _compose.text;
    if (text.isEmpty) return;
    _session.sendInput({'t': 'text', 's': text, 'paste': true});
    setState(() {
      _sentChunks.add(text.characters.length);
      if (_sentChunks.length > 20) _sentChunks.removeAt(0);
    });
    _compose.clear();
  }

  /// ✕: erases the last 전송 on the Mac (one Backspace per character); again for the one before.
  void _eraseLastSent() {
    if (_sentChunks.isEmpty) return;
    final count = math.min(_sentChunks.last, 5000);
    for (var i = 0; i < count; i++) {
      _session.keyTap(Hid.backspace);
    }
    setState(() => _sentChunks.removeLast());
  }

  void _forgetSent() {
    if (_sentChunks.isNotEmpty) setState(_sentChunks.clear);
  }

  void _measureKeyboardBar() {
    final height = _keyboardBarKey.currentContext?.size?.height;
    if (!mounted || height == null || (height - _keyboardBarHeight).abs() < 1) return;
    setState(() => _keyboardBarHeight = height);
  }

  Widget _extraKeys() {
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _extraKey('esc', () => _typeKey(Hid.escape)),
            _extraKey('tab', () => _typeKey(Hid.tab)),
            _stickyKey('⌘', Hid.leftMeta),
            _stickyKey('⌃', Hid.leftControl),
            _stickyKey('⌥', Hid.leftAlt),
            _stickyKey('⇧', Hid.leftShift),
            _extraKey('←', () => _typeKey(Hid.left)),
            _extraKey('↑', () => _typeKey(Hid.up)),
            _extraKey('↓', () => _typeKey(Hid.down)),
            _extraKey('→', () => _typeKey(Hid.right)),
            _extraKey('⌫', () => _typeKey(Hid.backspace)),
            _extraKey('⏎', () => _typeKey(Hid.enter)),
          ],
        ),
      ),
    );
  }

  Widget _extraKey(String label, VoidCallback onTap, {bool active = false}) {
    // GestureDetector rather than a button: buttons can take focus and hide the keyboard.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF4F8CFF) : const Color(0xFF232932),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: const TextStyle(fontSize: 16, color: Colors.white)),
      ),
    );
  }

  Widget _stickyKey(String label, int code) =>
      _extraKey(label, () => _toggleSticky(code), active: _stickyModifiers.contains(code));

  Widget _hiddenTextField() {
    return TextField(
      controller: _text,
      focusNode: _textFocus,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      textCapitalization: TextCapitalization.none,
      keyboardType: TextInputType.multiline,
      maxLines: null,
      showCursor: false,
      style: const TextStyle(color: Colors.transparent, fontSize: 1),
      decoration: const InputDecoration.collapsed(hintText: ''),
    );
  }

  Widget _statsBox() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(7)),
      child: Text(
        _session.statsText,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35, color: Colors.white),
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xE6161A20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A313B)),
      ),
      child: Text(text, style: const TextStyle(fontSize: 16, color: Colors.white)),
    );
  }

  Widget _connectingOverlay() {
    final reconnecting = _session.reconnectAttempt > 0;
    final label = reconnecting
        ? '연결이 끊겨 다시 연결하는 중… (${_session.reconnectAttempt}/${Session.reconnectAttempts})'
        : switch (_session.phase) {
            SessionPhase.connecting => 'Mac에 연결 중…',
            SessionPhase.authenticating => '인증 중…',
            SessionPhase.negotiating => '화면 연결 중…',
            _ => '',
          };
    return ColoredBox(
      color: reconnecting ? Colors.black54 : Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label, style: const TextStyle(color: Colors.white)),
            if (_session.hostName != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_session.hostName!, style: const TextStyle(color: Colors.white54)),
              ),
            const SizedBox(height: 16),
            TextButton(onPressed: () => _leave(), child: const Text('취소')),
          ],
        ),
      ),
    );
  }

  // MARK: Keyboard

  /// Hardware keys go to the Mac as physical HID codes, so the Mac's own input source
  /// does Korean composition. While the soft keyboard is up, printable keys are left to
  /// the device IME and arrive as text instead.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final usage = event.physicalKey.usbHidUsage;
    if (!Hid.isKeyboardPage(usage)) return KeyEventResult.ignored;
    if (_composeFocus.hasFocus) return KeyEventResult.ignored; // typing into the compose box, not the Mac

    // Paste: this device's clipboard goes over first (the V is sent after it, once).
    if (usage == Hid.keyV) {
      final keyboard = HardwareKeyboard.instance;
      if (event is KeyDownEvent &&
          _session.shareClipboard &&
          !keyboard.isAltPressed &&
          (keyboard.isMetaPressed || keyboard.isControlPressed)) {
        _swallowPasteKey = true;
        unawaited(_pasteFromDevice(usage));
        return KeyEventResult.handled;
      }
      if (_swallowPasteKey && event is! KeyDownEvent) {
        if (event is KeyUpEvent) _swallowPasteKey = false;
        return KeyEventResult.handled;
      }
    }

    final down = event is! KeyUpEvent;
    final message = {'t': 'key', 'code': _ctrlAsCmd ? Hid.ctrlAsCmd(usage) : usage, 'down': down};

    if (_textFocus.hasFocus) {
      final composing = _text.value.composing;
      if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
      if (Hid.isModifier(usage)) {
        _session.sendInput(message);
        return KeyEventResult.ignored; // the IME needs Shift too
      }
      final keyboard = HardwareKeyboard.instance;
      final chord = keyboard.isMetaPressed || keyboard.isControlPressed || keyboard.isAltPressed;
      if (!chord && !Hid.isControlKey(usage)) return KeyEventResult.ignored;
    }

    _session.sendInput(message);
    return KeyEventResult.handled;
  }

  void _toggleKeyboard() {
    if (_keyboardOn) {
      _textFocus.unfocus();
      _composeFocus.unfocus();
      _keyFocus.requestFocus();
      _releaseStickyModifiers();
    } else if (_keyboardMode == 'compose') {
      _composeFocus.requestFocus();
    } else {
      _resetText();
      _textFocus.requestFocus();
    }
  }

  void _onTextChanged() {
    if (_resettingText) return;
    final value = _text.value;
    if (value.composing.isValid && !value.composing.isCollapsed) {
      final preview = value.text.replaceFirst(_sentinel, '');
      if (preview != _composingPreview) setState(() => _composingPreview = preview);
      return;
    }
    if (_composingPreview.isNotEmpty) setState(() => _composingPreview = '');

    final text = value.text;
    if (text == _sentinel) return;
    if (text.isEmpty) {
      _typeKey(Hid.backspace);
    } else {
      _typeText(text.startsWith(_sentinel) ? text.substring(_sentinel.length) : text);
    }
    _resetText();
  }

  void _resetText() {
    _resettingText = true;
    _text.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
    _resettingText = false;
  }

  void _typeText(String text) {
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isNotEmpty) {
        if (_stickyModifiers.isNotEmpty) {
          // "⌘ then c" on the soft keyboard means Cmd+C, not the letter c.
          for (final character in line.characters) {
            final code = Hid.forCharacter(character);
            if (code != null) _session.keyTap(code);
          }
          _releaseStickyModifiers();
        } else {
          _session.sendInput({'t': 'text', 's': line});
        }
      }
      if (i < lines.length - 1) _typeKey(Hid.enter);
    }
  }

  void _typeKey(int code) {
    _session.keyTap(code);
    _releaseStickyModifiers();
  }

  void _toggleSticky(int code) {
    setState(() {
      if (_stickyModifiers.remove(code)) {
        _session.sendInput({'t': 'key', 'code': code, 'down': false});
      } else {
        _stickyModifiers.add(code);
        _session.sendInput({'t': 'key', 'code': code, 'down': true});
      }
    });
  }

  void _releaseStickyModifiers({bool rebuild = true}) {
    if (_stickyModifiers.isEmpty) return;
    for (final code in _stickyModifiers) {
      _session.sendInput({'t': 'key', 'code': code, 'down': false});
    }
    _stickyModifiers.clear();
    if (rebuild && mounted) setState(() {});
  }
}

/// One toolbar button: what it shows and what it does.
class _ToolItem {
  const _ToolItem(this.icon, this.label, this.active, this.onTap);
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
}
