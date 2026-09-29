import 'package:flutter_test/flutter_test.dart';
import 'package:jump_viewer/src/session.dart';

void main() {
  test('relay link with #id= goes to the relay client endpoint', () {
    expect(Session.signalingUri('https://jump-relay.me.workers.dev/#id=ABCD2345WXYZ').toString(),
        'wss://jump-relay.me.workers.dev/client?id=abcd2345wxyz');
  });

  test('relay link with the id as the last path segment', () {
    expect(Session.signalingUri('https://jump-relay.me.workers.dev/abcd2345wxyz').toString(),
        'wss://jump-relay.me.workers.dev/client?id=abcd2345wxyz');
  });

  test('local relay over http keeps its port', () {
    expect(Session.signalingUri('http://127.0.0.1:48787/#id=abcdefgh').toString(),
        'ws://127.0.0.1:48787/client?id=abcdefgh');
  });

  test('plain addresses stay direct on the signaling port', () {
    expect(Session.signalingUri('100.85.24.119').toString(), 'ws://100.85.24.119:47865/');
    expect(Session.signalingUri('192.168.0.10:47875').toString(), 'ws://192.168.0.10:47875/');
  });
}
