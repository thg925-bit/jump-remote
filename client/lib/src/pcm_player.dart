import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// Plays the host's audio channel: 48 kHz stereo Int16 PCM (see PROTOCOL.md).
///
/// The plugin queues everything it is fed, so this keeps latency bounded itself: it
/// collects ~60 ms before starting, estimates the queue from frames fed vs. time played,
/// and drops packets while more than ~250 ms is waiting.
class PcmPlayer {
  static const _sampleRate = 48000;
  static const _startFrames = _sampleRate * 60 ~/ 1000;
  static const _maxQueuedFrames = _sampleRate * 250 ~/ 1000;

  bool muted = false;

  /// Whether this device is actually playing the stream (the host mutes the Mac then).
  bool get isPlaying => _ready && !muted;

  bool _ready = false;
  bool _playing = false;
  final List<Uint8List> _prebuffer = [];
  int _prebufferFrames = 0;
  int _fedFrames = 0;
  final Stopwatch _clock = Stopwatch();

  Future<void> start() async {
    try {
      await FlutterPcmSound.setLogLevel(LogLevel.none);
      await FlutterPcmSound.setup(sampleRate: _sampleRate, channelCount: 2);
      await FlutterPcmSound.setFeedThreshold(0);
      // Fully drained (the host skips silence): rebuffer before playing again.
      FlutterPcmSound.setFeedCallback((remaining) {
        if (remaining == 0) _playing = false;
      });
      _ready = true;
    } catch (e) {
      debugPrint('audio setup failed: $e');
    }
  }

  void push(Uint8List pcm) {
    if (!_ready || muted || pcm.isEmpty) return;
    final frames = pcm.lengthInBytes ~/ 4;

    // Queue ran dry without us hearing about it: start over with a fresh prebuffer.
    if (_playing && _queuedFrames < 0) _playing = false;

    if (!_playing) {
      _prebuffer.add(pcm);
      _prebufferFrames += frames;
      if (_prebufferFrames < _startFrames) return;
      _clock
        ..reset()
        ..start();
      _fedFrames = 0;
      _playing = true;
      for (final chunk in _prebuffer) {
        _feed(chunk);
      }
      _prebuffer.clear();
      _prebufferFrames = 0;
      return;
    }

    if (_queuedFrames > _maxQueuedFrames) return; // backlog: drop to catch up
    _feed(pcm);
  }

  Future<void> dispose() async {
    _ready = false;
    FlutterPcmSound.setFeedCallback(null);
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }

  int get _queuedFrames => _fedFrames - _clock.elapsedMicroseconds * _sampleRate ~/ 1000000;

  void _feed(Uint8List pcm) {
    _fedFrames += pcm.lengthInBytes ~/ 4;
    FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.sublistView(pcm)));
  }
}
