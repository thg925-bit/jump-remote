import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'pcm_player.dart';

/// Default signaling port of the Mac host (see PROTOCOL.md).
const kSignalingPort = 47865;

enum SessionPhase { connecting, authenticating, negotiating, connected, reconnecting, closed }

/// One of the Mac's monitors.
class MacDisplay {
  const MacDisplay({required this.id, required this.name});
  final int id;
  final String name;
}

/// The Mac's current cursor image, in Mac points, with its hot spot.
class CursorShape {
  const CursorShape({required this.png, required this.size, required this.hotSpot});
  final Uint8List png;
  final Size size;
  final Offset hotSpot;
}

/// One connection to the Mac host: signaling, WebRTC video and the input channel.
class Session extends ChangeNotifier {
  Session({
    required this.address,
    required this.password,
    required this.viewportPixels,
    required this.devicePixelRatio,
  });

  final String address;

  /// Updated when [changePassword] succeeds, so the caller can remember the new one.
  String password;

  /// Client screen in physical pixels, reported to the host for virtual-display sizing.
  final Size viewportPixels;
  final double devicePixelRatio;

  final RTCVideoRenderer renderer = RTCVideoRenderer();
  final PcmPlayer audio = PcmPlayer();

  SessionPhase phase = SessionPhase.connecting;
  String? error;
  String? hostName;

  /// Captured Mac display size in points.
  Size? displayPoints;

  /// Cursor position (normalized over the Mac display) and shape; the app draws the cursor
  /// itself so it moves at display rate instead of video rate.
  final ValueNotifier<Offset> cursor = ValueNotifier(const Offset(0.5, 0.5));
  final ValueNotifier<CursorShape?> cursorShape = ValueNotifier(null);
  DateTime _lastLocalMove = DateTime.fromMillisecondsSinceEpoch(0);
  double? rttMs;
  String statsText = '';

  /// A dropped link reconnects by itself: attempt number (1-based) while that is going on.
  int reconnectAttempt = 0;
  static const _reconnectDelays = [0, 1, 2, 3, 5, 5, 10, 10, 15, 20]; // seconds, about 70 s in all
  static int get reconnectAttempts => _reconnectDelays.length;

  /// The Mac's monitors (two or more allow switching) and the one on screen.
  List<MacDisplay> displays = const [];
  int? currentDisplay;

  /// Data saver (PROTOCOL.md `device.saver` / `saver`): the Mac sends at most 1600 px, 30 fps and
  /// 1.5 Mbps. Set before [start] for the first frame; [setSaver] switches it during the session.
  bool saver = false;

  /// Share copied text with the Mac (PROTOCOL.md `clip`).
  bool shareClipboard = true;
  static const maxClipBytes = 60000;

  /// Text copied on the Mac; the viewer puts it on this device's clipboard.
  void Function(String text)? onMacCopied;

  /// The `file` data channel's messages and its control messages on the input channel
  /// (fileSaved, fileError, fileOffer), for the viewer's file transfer.
  void Function(RTCDataChannelMessage message)? onFileMessage;
  void Function(Map<String, dynamic> message)? onFileControl;
  RTCDataChannel? get fileChannel => _fileChannel;

  WebSocketChannel? _ws;
  Completer<String?>? _passwordReply;
  StreamSubscription<dynamic>? _wsSubscription;
  RTCPeerConnection? _pc;
  RTCDataChannel? _input;
  RTCDataChannel? _audioChannel;
  RTCDataChannel? _fileChannel;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  final List<Timer> _timers = [];
  String? _hostError;
  bool _closed = false;
  bool _disposed = false;
  bool _rendererReady = false;
  int _generation = 0; // bumps per connection attempt; callbacks of an older one are ignored
  bool _everConnected = false;
  bool _final = false; // the Mac said stop: wrong password, another device took over, ...
  Timer? _retryTimer;
  Timer? _lossTimer;
  String? _resumeReason; // why the current attempt is a reconnect (sent to the host's log)
  String? _resumeToken; // from the Mac's offer: lets this session be picked up after a network change
  bool _linkResuming = false; // a new socket is asking the Mac to restart ICE on this session
  DateTime? _linkResumeSince;
  bool _signalingOpen = false;
  int _offlineTries = 0; // "Mac offline" before ever connecting: looked again this many times

  // Stats deltas.
  double? _prevBytes;
  DateTime? _prevStatsTime;
  /// Inbound video counters at the start of the current 5 s report span (PROTOCOL.md `stats`).
  Map<String, double>? _reportFrom;
  DateTime? _reportFromTime;
  static const _reportCounters = [
    'framesDecoded', 'totalInterFrameDelay', 'totalSquaredInterFrameDelay', 'totalDecodeTime',
    'jitterBufferDelay', 'jitterBufferEmittedCount', 'framesDropped', 'packetsLost', 'nackCount', 'pliCount',
  ];

  /// A relay link (`https://<relay>/#id=<mac id>`) goes through the Cloudflare relay;
  /// anything else is a direct LAN / Tailscale address.
  bool get _viaRelay => isRelayLink(address);

  Uri get _uri => signalingUri(address);

  static bool isRelayLink(String address) => address.startsWith('https://') || address.startsWith('http://');

  /// Where to open the signaling WebSocket for what the user typed.
  @visibleForTesting
  static Uri signalingUri(String address) {
    if (isRelayLink(address)) {
      final link = Uri.parse(address);
      final id =
          Uri.splitQueryString(link.fragment)['id'] ?? (link.pathSegments.isNotEmpty ? link.pathSegments.last : '');
      return Uri(
        scheme: link.scheme == 'https' ? 'wss' : 'ws',
        host: link.host,
        port: link.hasPort ? link.port : null,
        path: '/client',
        queryParameters: {'id': id.toLowerCase()},
      );
    }
    final withPort = address.contains(':') ? address : '$address:$kSignalingPort';
    return Uri.parse('ws://$withPort/');
  }

  Future<void> start() async {
    await renderer.initialize();
    _rendererReady = true;
    await audio.start();
    await _connect();
  }

  /// One attempt at signaling + WebRTC; also used to reconnect.
  Future<void> _connect() async {
    if (_closed) return;
    final generation = ++_generation;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _hostError = null;
    final WebSocketChannel ws;
    try {
      ws = WebSocketChannel.connect(_uri);
      _ws = ws;
      await ws.ready.timeout(const Duration(seconds: 6));
    } catch (_) {
      if (generation != _generation) return;
      _fail(_viaRelay ? '중개 서버에 연결할 수 없습니다. 인터넷 연결과 링크를 확인하세요.' : 'Mac에 연결할 수 없습니다. 주소와 호스트 실행 여부를 확인하세요.');
      return;
    }
    if (generation != _generation || _closed) return;
    _signalingOpen = true;
    _wsSubscription = ws.stream.listen(
      (data) {
        if (generation != _generation) return;
        try {
          _onSignal(jsonDecode(data as String) as Map<String, dynamic>);
        } catch (e) {
          debugPrint('bad signal: $e');
        }
      },
      // Signaling only sets the session up: once the picture flows, losing it (the app in the
      // background, a mobile network, the relay) is fine; the data channel and WebRTC decide.
      onDone: () {
        if (generation != _generation) return;
        _signalingOpen = false;
        if (_signalingNoLongerNeeded) return;
        // "Mac offline" right at the start: the Mac's own link to the relay drops for a couple
        // of seconds now and then. Look again a few times before giving up.
        if (ws.closeCode == 4404 && !_everConnected && reconnectAttempt == 0 && _offlineTries < 3) {
          _offlineTries++;
          _generation++;
          _teardownLink();
          _setPhase(SessionPhase.connecting);
          _retryTimer?.cancel();
          _retryTimer = Timer(const Duration(seconds: 2), _connect);
          return;
        }
        _fail(
          _hostError ?? (ws.closeCode == 4404 ? 'Mac이 꺼져 있거나 인터넷에 연결돼 있지 않습니다. 링크의 Mac ID도 확인하세요.' : '연결이 종료되었습니다.'),
        );
      },
      onError: (_) {
        if (generation != _generation || _signalingNoLongerNeeded) return;
        _fail(_hostError ?? '연결 오류가 발생했습니다.');
      },
    );
  }

  bool get _signalingNoLongerNeeded => phase == SessionPhase.connected && _hostError == null && !_linkResuming;

  /// A dropped link is being picked up on the same session (ICE restart), picture kept.
  bool get linkResuming => _linkResuming;

  /// The link dropped or the network changed: prove the password again on a new socket and ask
  /// the Mac to restart ICE on this very session (PROTOCOL.md `resume`), so the picture carries
  /// on where it was. When the Mac is gone or doesn't answer in time, the usual reconnect takes
  /// over. True if started.
  bool resumeLink(String reason) {
    final pc = _pc;
    if (_closed || _linkResuming || _resumeToken == null || pc == null) return false;
    _linkResuming = true;
    _linkResumeSince = DateTime.now();
    _resumeReason = reason;
    _generation++; // the old socket's events are stale from here on
    final subscription = _wsSubscription, ws = _ws;
    _wsSubscription = null;
    _ws = null;
    subscription?.cancel();
    try {
      ws?.sink.close();
    } catch (_) {}
    notifyListeners();
    _connect();
    return true;
  }

  /// The restarted link is up (or was never really down): back to normal.
  void _finishLinkResume() {
    if (!_linkResuming) return;
    _linkResuming = false;
    _lossTimer?.cancel();
    final since = _linkResumeSince;
    if (since != null) debugPrint('link back after the ICE restart (${DateTime.now().difference(since).inMilliseconds} ms)');
    notifyListeners();
  }

  /// Back from the background: a link that dropped meanwhile is picked up at once.
  Future<void> resumeLinkIfNeeded() async {
    final state = await _pc?.getConnectionState();
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      resumeLink('화면 복귀');
    }
  }

  /// Shows the Mac's next monitor; returns its name (null with only one).
  String? selectNextDisplay() {
    if (displays.length < 2) return null;
    final index = displays.indexWhere((d) => d.id == currentDisplay);
    final next = displays[(index + 1) % displays.length];
    sendInput({'t': 'selectDisplay', 'id': next.id});
    return next.name;
  }

  /// Turns the data saver on or off for this session.
  void setSaver(bool on) {
    saver = on;
    sendInput({'t': 'saver', 'on': on});
  }

  /// Sends text copied on this device ahead of a paste keystroke. False when it wasn't sent.
  bool sendClipboard(String text) {
    if (!shareClipboard || text.isEmpty || utf8.encode(text).length > maxClipBytes) return false;
    sendInput({'t': 'clip', 'text': text});
    return true;
  }

  /// Asks the host to change its password. Returns null on success, otherwise the reason.
  Future<String?> changePassword(String current, String next) async {
    final channel = _input;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) return '아직 연결 중입니다';
    final reply = _passwordReply = Completer<String?>();
    sendInput({'t': 'password', 'current': current, 'new': next});
    final error = await reply.future.timeout(const Duration(seconds: 10), onTimeout: () => 'Mac이 응답하지 않습니다');
    if (identical(_passwordReply, reply)) _passwordReply = null;
    if (error == null) password = next;
    return error;
  }

  /// Sends one input message (see PROTOCOL.md) if the channel is open.
  void sendInput(Map<String, dynamic> message) {
    final channel = _input;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) return;
    channel.send(RTCDataChannelMessage(jsonEncode(message)));
  }

  /// Moves the Mac cursor and our drawn copy of it at once.
  void moveCursor(Offset normalized) {
    final clamped = Offset(normalized.dx.clamp(0.0, 1.0), normalized.dy.clamp(0.0, 1.0));
    cursor.value = clamped;
    _lastLocalMove = DateTime.now();
    sendInput({'t': 'move', 'x': clamped.dx, 'y': clamped.dy});
  }

  /// Moves the cursor by a distance in Mac points (trackpad stick).
  void moveCursorBy(Offset points) {
    final display = displayPoints ?? const Size(1470, 956);
    moveCursor(cursor.value + Offset(points.dx / display.width, points.dy / display.height));
  }

  /// "맥북에어" etc. from the host's name, for the sound toggle.
  String get macLabel {
    final name = hostName ?? '';
    const names = [
      ('MacBook Air', '맥북에어'),
      ('MacBook Pro', '맥북프로'),
      ('Mac Studio', '맥스튜디오'),
      ('Mac mini', '맥미니'),
      ('iMac', '아이맥'),
      ('Mac Pro', '맥프로'),
    ];
    for (final (pattern, label) in names) {
      if (name.toLowerCase().contains(pattern.toLowerCase())) return label;
    }
    return '맥';
  }

  /// Sound plays in one place: here while we play it, otherwise on the Mac.
  void reportAudio() => sendInput({'t': 'audio', 'on': audio.isPlaying});

  void keyTap(int hidUsage) {
    sendInput({'t': 'key', 'code': hidUsage, 'down': true});
    sendInput({'t': 'key', 'code': hidUsage, 'down': false});
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    await _teardownLink();
    await audio.dispose();
    if (_rendererReady && !_disposed) renderer.srcObject = null;
    if (phase != SessionPhase.closed) {
      phase = SessionPhase.closed;
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    cursor.dispose();
    cursorShape.dispose();
    if (_rendererReady) renderer.dispose();
    super.dispose();
  }

  /// Drops the current signaling socket and peer connection; the session itself stays.
  Future<void> _teardownLink() async {
    _linkResuming = false;
    _lossTimer?.cancel();
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    final input = _input, audioChannel = _audioChannel, fileChannel = _fileChannel, pc = _pc, ws = _ws, subscription = _wsSubscription;
    _input = null;
    _audioChannel = null;
    _fileChannel = null;
    _pc = null;
    _ws = null;
    _wsSubscription = null;
    try {
      await input?.close();
      await audioChannel?.close();
      await fileChannel?.close();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
    await subscription?.cancel();
    try {
      await ws?.sink.close();
    } catch (_) {}
  }

  // MARK: Signaling

  void _send(Map<String, dynamic> message) {
    if (_closed) return;
    _ws?.sink.add(jsonEncode(message));
  }

  Future<void> _onSignal(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'challenge':
        hostName = message['host'] as String?;
        _setPhase(SessionPhase.authenticating);
        final nonce = base64Decode(message['nonce'] as String);
        final mac = Hmac(sha256, utf8.encode(password)).convert(nonce).bytes;
        final codecs = await _receivableCodecs();
        _send({
          'type': 'auth',
          'hmac': base64Encode(mac),
          'device': {
            'name': _deviceName(),
            'width': viewportPixels.width.round(),
            'height': viewportPixels.height.round(),
            'scale': devicePixelRatio,
            'cursor': true, // we draw the cursor ourselves
            'codecs': codecs, // lets the host pick HEVC when this device can decode it
            'saver': saver, // data saver from the first frame
            if (_resumeReason != null) 'reconnect': _resumeReason, // for the host's log
          },
          if (_linkResuming && _resumeToken != null) 'resume': _resumeToken, // same session: restart ICE
        });
      case 'offer':
        if (message['resume'] is String) _resumeToken = message['resume'] as String;
        if (message['restart'] == true && _pc != null && _linkResuming) {
          await _applyRestart(message['sdp'] as String);
        } else {
          if (_pc != null) await _teardownPeer(); // the Mac started over instead: take it here
          await _answer(message['sdp'] as String, (message['iceServers'] as List?) ?? const []);
        }
      case 'candidate':
        final candidate = RTCIceCandidate(
          message['candidate'] as String?,
          message['sdpMid'] as String?,
          (message['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (_remoteDescriptionSet) {
          await _addCandidate(candidate);
        } else {
          _pendingCandidates.add(candidate);
        }
      case 'error':
        final retry = message['retry'] == true;
        // Retryable while the picture still flows peer to peer (the relay lost the Mac for a
        // moment): only signaling is gone, which a running session doesn't need.
        if (retry && phase == SessionPhase.connected) return;
        // The close frame can lag behind (especially through the relay); end now.
        _hostError = message['message'] as String?;
        if (!retry) _final = true;
        _fail(_hostError ?? '연결이 종료되었습니다.', retry: retry);
    }
  }

  /// The Mac restarted ICE on the running session: answer on the same peer connection.
  Future<void> _applyRestart(String sdp) async {
    final pc = _pc;
    if (pc == null) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;
      for (final candidate in _pendingCandidates) {
        await _addCandidate(candidate);
      }
      _pendingCandidates.clear();
      final answer = await pc.createAnswer({});
      await pc.setLocalDescription(answer);
      _send({'type': 'answer', 'sdp': answer.sdp});
      // A link that never really broke (the restart was asked for early) raises no "connected"
      // event: look for ourselves once the checks had a moment.
      Timer(const Duration(milliseconds: 1500), () async {
        if (_pc != pc || !_linkResuming) return;
        final ice = await pc.getIceConnectionState();
        if (ice == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            ice == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _finishLinkResume();
        }
      });
    } catch (e) {
      debugPrint('ICE restart failed: $e');
      _fail('연결이 끊어졌습니다.');
    }
  }

  /// Drops the peer connection and its channels, keeping the session and its socket.
  Future<void> _teardownPeer() async {
    _lossTimer?.cancel();
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    final input = _input, audioChannel = _audioChannel, fileChannel = _fileChannel, pc = _pc;
    _input = null;
    _audioChannel = null;
    _fileChannel = null;
    _pc = null;
    try {
      await input?.close();
      await audioChannel?.close();
      await fileChannel?.close();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
  }

  /// [iceServers] come from the Mac (STUN, plus TURN through the relay) only after auth.
  Future<void> _answer(String sdp, List<dynamic> iceServers) async {
    final generation = _generation;
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
    });
    if (_closed || generation != _generation) {
      await pc.close();
      return;
    }
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _send({
        'type': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onTrack = (event) {
      if (_pc != pc) return;
      if (event.track.kind != 'video' || event.streams.isEmpty) return;
      renderer.srcObject = event.streams.first;
    };
    pc.onDataChannel = (channel) {
      if (_pc != pc) return;
      if (channel.label == 'audio') {
        _audioChannel = channel;
        channel.onMessage = (message) {
          if (message.isBinary) audio.push(message.binary);
        };
        return;
      }
      if (channel.label == 'file') {
        _fileChannel = channel;
        channel.onMessage = (message) => onFileMessage?.call(message);
        return;
      }
      if (channel.label != 'input') return;
      _input = channel;
      if (channel.state == RTCDataChannelState.RTCDataChannelOpen) reportAudio();
      channel.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) reportAudio();
        // The Mac closed it (or the link died): the session is over.
        if (state == RTCDataChannelState.RTCDataChannelClosed && _input == channel) _fail('연결이 끊어졌습니다.');
      };
      channel.onMessage = (message) {
        try {
          _onInputMessage(jsonDecode(message.text) as Map<String, dynamic>);
        } catch (_) {}
      };
    };
    pc.onIceConnectionState = (state) {
      if (_pc != pc || !_linkResuming) return;
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _finishLinkResume();
      }
    };
    pc.onConnectionState = (state) {
      if (_pc != pc) return;
      // The loss timer runs on until the link is back: "connecting" on the way there is not it.
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _lossTimer?.cancel();
          _finishLinkResume();
          _everConnected = true;
          reconnectAttempt = 0;
          _setPhase(SessionPhase.connected);
          notifyListeners();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          // Dead for good on this path: an ICE restart finds a new one; failing that, start over.
          _lossTimer?.cancel();
          if (!_linkResuming && resumeLink('연결이 끊어졌습니다')) {
            _lossTimer = Timer(const Duration(seconds: 8), () {
              if (_pc == pc) _fail('연결이 끊어졌습니다.');
            });
          } else {
            _fail('연결이 끊어졌습니다.');
          }
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // A network switch sits in "disconnected" a long time before "failed": ask the Mac to
          // restart ICE at once (a hiccup that recovers by itself loses nothing by it) and start
          // over if that doesn't bring it back. With signaling gone and no way to resume, both
          // say the link is dead: go sooner.
          _lossTimer?.cancel();
          final wait = resumeLink('연결이 끊어졌습니다') ? 10 : (_signalingOpen ? 8 : 3);
          _lossTimer = Timer(Duration(seconds: wait), () {
            if (_pc == pc) _fail('연결이 끊어졌습니다 ($wait초 동안 응답 없음).');
          });
        default:
          break;
      }
    };

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteDescriptionSet = true;
    for (final candidate in _pendingCandidates) {
      await _addCandidate(candidate);
    }
    _pendingCandidates.clear();

    final answer = await pc.createAnswer({});
    await pc.setLocalDescription(answer);
    _send({'type': 'answer', 'sdp': answer.sdp});
    _setPhase(SessionPhase.negotiating);

    _timers.add(
      Timer.periodic(const Duration(seconds: 1), (_) {
        sendInput({'t': 'ping', 'ts': DateTime.now().microsecondsSinceEpoch / 1000.0});
      }),
    );
    _timers.add(Timer.periodic(const Duration(seconds: 1), (_) => _updateStats()));
  }

  Future<void> _addCandidate(RTCIceCandidate candidate) async {
    try {
      await _pc?.addCandidate(candidate);
    } catch (e) {
      debugPrint('addCandidate failed: $e');
    }
  }

  Future<List<String>> _receivableCodecs() async {
    try {
      final capabilities = await getRtpReceiverCapabilities('video');
      return {for (final codec in capabilities.codecs ?? <RTCRtpCodecCapability>[]) codec.mimeType}.toList();
    } catch (_) {
      return [];
    }
  }

  void _onInputMessage(Map<String, dynamic> message) {
    switch (message['t']) {
      case 'cursor':
        // Our own moves are newer than the host's echo of them.
        if (DateTime.now().difference(_lastLocalMove) < const Duration(milliseconds: 300)) return;
        cursor.value = Offset((message['x'] as num).toDouble(), (message['y'] as num).toDouble());
      case 'cursorImage':
        cursorShape.value = CursorShape(
          png: base64Decode(message['png'] as String),
          size: Size((message['w'] as num).toDouble(), (message['h'] as num).toDouble()),
          hotSpot: Offset((message['hx'] as num).toDouble(), (message['hy'] as num).toDouble()),
        );
      case 'display':
        displayPoints = Size((message['w'] as num).toDouble(), (message['h'] as num).toDouble());
        notifyListeners();
      case 'bye':
        // The Mac ended the session (another device took over, a setting changed, …).
        _hostError = message['message'] as String?;
        final retry = message['retry'] == true;
        if (!retry) _final = true;
        _fail(_hostError ?? '연결이 종료되었습니다.', retry: retry);
      case 'clip':
        final text = message['text'];
        if (shareClipboard && text is String && text.isNotEmpty) onMacCopied?.call(text);
      case 'displays':
        displays = [
          for (final entry in (message['list'] as List? ?? const []))
            if (entry is Map) MacDisplay(id: (entry['id'] as num).toInt(), name: entry['name'] as String? ?? '모니터'),
        ];
        currentDisplay = (message['current'] as num?)?.toInt();
        notifyListeners();
      case 'fileSaved' || 'fileError' || 'fileOffer':
        onFileControl?.call(message);
      case 'password':
        final reply = _passwordReply;
        _passwordReply = null;
        if (reply != null && !reply.isCompleted) {
          reply.complete(message['ok'] == true ? null : (message['error'] as String? ?? '변경하지 못했습니다'));
        }
      case 'pong':
        final sent = (message['ts'] as num?)?.toDouble();
        if (sent != null) {
          rttMs = DateTime.now().microsecondsSinceEpoch / 1000.0 - sent;
        }
    }
  }

  // MARK: Stats

  Future<void> _updateStats() async {
    final pc = _pc;
    if (pc == null || _closed) return;
    final reports = await pc.getStats();
    Map<dynamic, dynamic>? video;
    final byId = <String, Map<dynamic, dynamic>>{};
    for (final report in reports) {
      byId[report.id] = report.values;
      if (report.type == 'inbound-rtp' && report.values['kind'] == 'video') {
        video = report.values;
      }
    }
    if (video == null) return;

    double number(String key) {
      final value = video![key];
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0;
      return 0;
    }

    final now = DateTime.now();
    final bytes = number('bytesReceived');
    var mbps = 0.0;
    if (_prevBytes != null && _prevStatsTime != null) {
      final seconds = now.difference(_prevStatsTime!).inMicroseconds / 1e6;
      if (seconds > 0) mbps = (bytes - _prevBytes!) * 8 / seconds / 1e6;
    }
    _prevBytes = bytes;
    _prevStatsTime = now;

    _reportPlayback(now, {for (final key in _reportCounters) key: number(key), 'jitter': number('jitter')});

    final emitted = number('jitterBufferEmittedCount');
    final jitterMs = emitted > 0 ? 1000 * number('jitterBufferDelay') / emitted : 0;
    final decoded = number('framesDecoded');
    final decodeMs = decoded > 0 ? 1000 * number('totalDecodeTime') / decoded : 0;
    final codec = byId[video['codecId']]?['mimeType']?.toString().replaceFirst('video/', '') ?? '';

    statsText = [
      '${number('frameWidth').toInt()}×${number('frameHeight').toInt()}  ${number('framesPerSecond').round()} fps',
      '${mbps.toStringAsFixed(1)} Mbps  $codec',
      'RTT ${rttMs?.toStringAsFixed(0) ?? '?'} ms',
      'jitter buf ${jitterMs.toStringAsFixed(0)} ms  decode ${decodeMs.toStringAsFixed(1)} ms',
      'dropped ${number('framesDropped').toInt()}  ${video['decoderImplementation'] ?? ''}',
    ].join('\n');
    notifyListeners();
  }

  /// Every 5 s, what this viewer actually played, for the Mac's log ("[viewer]" in host.log):
  /// without it a stutter on the receiving side is invisible from there.
  void _reportPlayback(DateTime now, Map<String, double> taken) {
    final from = _reportFrom, fromTime = _reportFromTime;
    if (from == null || fromTime == null) {
      _reportFrom = taken;
      _reportFromTime = now;
      return;
    }
    final seconds = now.difference(fromTime).inMilliseconds / 1000;
    if (seconds < 5) return;
    _reportFrom = taken;
    _reportFromTime = now;
    double d(String key) => math.max(0, (taken[key] ?? 0) - (from[key] ?? 0));
    final frames = d('framesDecoded');
    // Spread of the time between frames as they were shown: 0 is perfectly even playback.
    final mean = frames > 1 ? d('totalInterFrameDelay') / frames : 0.0;
    final gapSd = frames > 1 ? math.sqrt(math.max(0, d('totalSquaredInterFrameDelay') / frames - mean * mean)) * 1000 : null;
    final emitted = d('jitterBufferEmittedCount');
    double round(double value, [int digits = 1]) => double.parse(value.toStringAsFixed(digits));
    sendInput({
      't': 'stats',
      'fps': (frames / seconds).round(),
      if (gapSd != null) 'gap': round(gapSd),
      'jitter': round((taken['jitter'] ?? 0) * 1000),
      'buffer': emitted > 0 ? (1000 * d('jitterBufferDelay') / emitted).round() : 0,
      'decode': frames > 0 ? round(1000 * d('totalDecodeTime') / frames) : 0,
      'dropped': d('framesDropped').round(),
      'lost': d('packetsLost').round(),
      'nack': d('nackCount').round(),
      'pli': d('pliCount').round(),
    });
  }

  // MARK: Helpers

  void _setPhase(SessionPhase next) {
    if (_closed || phase == next) return;
    phase = next;
    notifyListeners();
  }

  void _fail(String reason, {bool retry = false}) {
    if (_closed) return;
    if (!_final && (retry || _everConnected) && reconnectAttempt < _reconnectDelays.length) {
      _reconnect(reason);
      return;
    }
    error = reconnectAttempt > 0 ? '다시 연결하지 못했습니다. $reason' : reason;
    close();
  }

  /// Keeps the viewer (and its last frame) and tries the same address and password again.
  void _reconnect([String? reason]) {
    _resumeReason = reason;
    final delay = Duration(seconds: _reconnectDelays[reconnectAttempt]);
    reconnectAttempt++;
    _generation++; // everything from the dropped link is stale from here on
    _teardownLink();
    phase = SessionPhase.reconnecting;
    notifyListeners();
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _connect);
  }

  String _deviceName() {
    if (Platform.isIOS) return 'iPad';
    if (Platform.isAndroid) return 'Android';
    return Platform.operatingSystem;
  }
}
