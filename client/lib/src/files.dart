import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// A file on this phone, as the picker or the share sheet handed it over.
class PickedFile {
  const PickedFile({required this.uri, required this.name, required this.size});
  final String uri;
  final String name;
  /// -1 when Android doesn't say.
  final int size;

  static PickedFile? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['uri'], name = raw['name'], size = raw['size'];
    if (uri is! String || name is! String) return null;
    return PickedFile(uri: uri, name: name, size: size is num ? size.toInt() : -1);
  }
}

/// The Android side (MainActivity.kt): the picker, the share sheet, reading content URIs in
/// order, and writing into Downloads.
class FileBridge {
  static const _channel = MethodChannel('jump/files');

  static Future<List<PickedFile>> pick() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('pick') ?? const [];
    return raw.map(PickedFile.fromMap).whereType<PickedFile>().toList();
  }

  /// Files shared into the app since the last call.
  static Future<List<PickedFile>> shared() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('shared') ?? const [];
    return raw.map(PickedFile.fromMap).whereType<PickedFile>().toList();
  }

  static Future<int> readOpen(String uri) async => (await _channel.invokeMethod<int>('readOpen', {'uri': uri}))!;
  static Future<Uint8List> readNext(int id, int length) async =>
      (await _channel.invokeMethod<Uint8List>('readNext', {'id': id, 'length': length})) ?? Uint8List(0);
  static Future<void> readClose(int id) => _channel.invokeMethod<void>('readClose', {'id': id});

  static Future<int> saveOpen(String name) async => (await _channel.invokeMethod<int>('saveOpen', {'name': name}))!;
  static Future<void> saveWrite(int id, Uint8List bytes) => _channel.invokeMethod<void>('saveWrite', {'id': id, 'bytes': bytes});
  static Future<void> saveClose(int id, {bool keep = true}) => _channel.invokeMethod<void>('saveClose', {'id': id, 'keep': keep});
}

/// What the Mac offers after a ⌘C on files in the Finder (PROTOCOL.md, Files).
class FileOffer {
  const FileOffer({required this.id, required this.names, required this.totalSize});
  final int id;
  final List<String> names;
  final int totalSize;

  String get label => names.length == 1 ? names.first : '${names.first} 외 ${names.length - 1}개';
}

/// Files to and from the Mac on the `file` data channel: 16 KiB chunks, paced by the channel's
/// buffered amount. What goes out lands in the Mac's Downloads; what comes in lands in this
/// phone's Downloads.
class FileTransfer {
  FileTransfer({required this.channel, required this.sendInput, required this.notice, required this.onOffer});

  static const chunkSize = 16 * 1024;
  static const maxBuffered = 1 << 20;

  /// The `file` channel of the current peer connection (null until it arrives).
  RTCDataChannel? Function() channel;
  final void Function(Map<String, dynamic> message) sendInput;
  final void Function(String text, {double seconds}) notice;
  final void Function(FileOffer offer) onOffer;

  int _nextId = 1;
  final List<PickedFile> _pending = [];
  bool _busy = false;
  _Incoming? _incoming;

  /// Queues files for the Mac and sends them one after another.
  Future<void> send(List<PickedFile> files) async {
    if (files.isEmpty) return;
    if (channel() == null) {
      notice('연결된 뒤에 보낼 수 있습니다', seconds: 2.5);
      return;
    }
    _pending.addAll(files);
    if (_busy) return;
    _busy = true;
    try {
      while (_pending.isNotEmpty) {
        await _sendOne(_pending.removeAt(0));
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _sendOne(PickedFile file) async {
    final channel = this.channel();
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      notice('보내지 못했습니다: ${file.name} (연결 없음)', seconds: 3);
      return;
    }
    final id = _nextId++;
    int? handle;
    try {
      handle = await FileBridge.readOpen(file.uri);
      await channel.send(RTCDataChannelMessage(jsonEncode({'t': 'file', 'id': id, 'name': file.name, 'size': file.size})));
      var sent = 0;
      var shown = DateTime.now();
      while (true) {
        if (channel.state != RTCDataChannelState.RTCDataChannelOpen) throw StateError('channel closed');
        if (await channel.getBufferedAmount() > maxBuffered) {
          await _waitDrained(channel);
          continue;
        }
        final chunk = await FileBridge.readNext(handle, chunkSize);
        if (chunk.isEmpty) break;
        await channel.send(RTCDataChannelMessage.fromBinary(chunk));
        sent += chunk.length;
        if (file.size > 0 && DateTime.now().difference(shown).inMilliseconds > 500) {
          shown = DateTime.now();
          notice('보내는 중: ${file.name} ${(sent * 100 ~/ file.size)}%', seconds: 2);
        }
      }
      if (file.size >= 0 && sent != file.size) throw StateError('read $sent of ${file.size} bytes');
      await channel.send(RTCDataChannelMessage(jsonEncode({'t': 'end', 'id': id})));
      notice('보냈습니다: ${file.name} — Mac이 저장하는 중…', seconds: 3);
    } catch (e) {
      notice('보내지 못했습니다: ${file.name}', seconds: 3);
      try {
        await channel.send(RTCDataChannelMessage(jsonEncode({'t': 'abort', 'id': id})));
      } catch (_) {}
    } finally {
      if (handle != null) await FileBridge.readClose(handle);
    }
  }

  /// Resolves once the channel's buffer is down, or after a second.
  Future<void> _waitDrained(RTCDataChannel channel) {
    final completer = Completer<void>();
    channel.bufferedAmountLowThreshold = 256 * 1024;
    channel.onBufferedAmountLow = (_) {
      if (!completer.isCompleted) completer.complete();
    };
    return completer.future.timeout(const Duration(seconds: 1), onTimeout: () {});
  }

  /// A message on the file channel: a file from the Mac, chunk by chunk, into Downloads.
  Future<void> onChannelMessage(RTCDataChannelMessage message) async {
    if (!message.isBinary) {
      Map<String, dynamic> control;
      try {
        control = jsonDecode(message.text) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      switch (control['t']) {
        case 'file':
          await _discardIncoming();
          final name = control['name'] as String? ?? 'file';
          final size = (control['size'] as num?)?.toInt() ?? -1;
          try {
            final handle = await FileBridge.saveOpen(name);
            _incoming = _Incoming(id: handle, name: name, size: size);
            notice('받는 중: $name', seconds: 2);
          } catch (e) {
            notice('받지 못했습니다: $name ($e)', seconds: 4);
          }
        case 'end':
          final incoming = _incoming;
          _incoming = null;
          if (incoming == null) return;
          await incoming.chain;
          final complete = incoming.size < 0 || incoming.received == incoming.size;
          try {
            await FileBridge.saveClose(incoming.id, keep: complete);
          } catch (_) {}
          notice(complete ? '다운로드에 저장: ${incoming.name}' : '받지 못했습니다: ${incoming.name}', seconds: 3.5);
      }
      return;
    }
    final incoming = _incoming;
    if (incoming == null) return;
    final bytes = message.binary;
    incoming.received += bytes.length;
    // Writes go out in order, one after another, while the next chunk arrives.
    incoming.chain = incoming.chain.then((_) => FileBridge.saveWrite(incoming.id, bytes));
  }

  Future<void> _discardIncoming() async {
    final incoming = _incoming;
    _incoming = null;
    if (incoming == null) return;
    await incoming.chain;
    try {
      await FileBridge.saveClose(incoming.id, keep: false);
    } catch (_) {}
  }

  /// Control messages on the input channel.
  void onInput(Map<String, dynamic> message) {
    switch (message['t']) {
      case 'fileSaved':
        notice('Mac 다운로드 폴더에 저장: ${message['name']}', seconds: 3.5);
      case 'fileError':
        notice('파일: ${message['message']}', seconds: 4);
      case 'fileOffer':
        final list = message['files'];
        if (list is! List || list.isEmpty) return;
        final names = <String>[];
        var total = 0;
        for (final entry in list) {
          if (entry is Map) {
            names.add(entry['name'] as String? ?? 'file');
            total += (entry['size'] as num?)?.toInt() ?? 0;
          }
        }
        onOffer(FileOffer(id: (message['id'] as num?)?.toInt() ?? 0, names: names, totalSize: total));
    }
  }

  /// Asks the Mac for the offered files.
  void get(FileOffer offer) => sendInput({'t': 'fileGet', 'id': offer.id});

  /// The session is over: nothing half received stays in Downloads.
  Future<void> reset() async {
    _pending.clear();
    await _discardIncoming();
  }
}

class _Incoming {
  _Incoming({required this.id, required this.name, required this.size});
  final int id;
  final String name;
  final int size;
  int received = 0;
  Future<void> chain = Future.value();
}

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1048576) return '${(n / 1024).toStringAsFixed(0)} KB';
  if (n < 1073741824) return '${(n / 1048576).toStringAsFixed(1)} MB';
  return '${(n / 1073741824).toStringAsFixed(2)} GB';
}
