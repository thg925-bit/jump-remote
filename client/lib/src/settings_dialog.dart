import 'package:flutter/material.dart';

import 'hosts_store.dart';
import 'session.dart';

/// Viewer settings: the stats overlay, and changing the Mac's password without touching the Mac.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.session,
    required this.showStats,
    required this.onShowStats,
    required this.onShareClipboard,
    required this.ctrlAsCmd,
    required this.onCtrlAsCmd,
  });

  final Session session;
  final bool showStats;
  final ValueChanged<bool> onShowStats;
  final ValueChanged<bool> onShareClipboard;
  final bool ctrlAsCmd;
  final ValueChanged<bool> onCtrlAsCmd;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  late bool _showStats = widget.showStats;
  late bool _shareClipboard = widget.session.shareClipboard;
  late bool _ctrlAsCmd = widget.ctrlAsCmd;
  final Set<TextEditingController> _shown = {};
  bool _busy = false;
  bool _ok = false;
  String? _message;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _change() async {
    final current = _current.text;
    final next = _next.text.trim();
    String? problem;
    if (current.isEmpty) {
      problem = '현재 비밀번호를 입력하세요';
    } else if (next.length < 8) {
      problem = '새 비밀번호는 8자 이상이어야 합니다';
    } else if (next != _confirm.text.trim()) {
      problem = '새 비밀번호 확인이 다릅니다';
    }
    if (problem != null) {
      setState(() {
        _ok = false;
        _message = problem;
      });
      return;
    }

    setState(() {
      _busy = true;
      _ok = false;
      _message = '변경 중…';
    });
    final error = await widget.session.changePassword(current, next);
    if (error == null) await HostsStore().updatePassword(widget.session.address, next);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = error == null;
      _message = error ?? '변경했습니다. 다음 접속부터 새 비밀번호로 들어옵니다.';
      if (error == null) {
        _current.clear();
        _next.clear();
        _confirm.clear();
      }
    });
  }

  Widget _field(TextEditingController controller, String label, {bool last = false}) {
    return TextField(
      controller: controller,
      obscureText: !_shown.contains(controller),
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onSubmitted: last ? (_) => _change() : null,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_shown.contains(controller) ? Icons.visibility_off : Icons.visibility, size: 20),
          tooltip: _shown.contains(controller) ? '비밀번호 숨기기' : '비밀번호 보기',
          onPressed: () =>
              setState(() => _shown.contains(controller) ? _shown.remove(controller) : _shown.add(controller)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messageColor = _ok
        ? const Color(0xFF46C46E)
        : _busy
        ? Colors.white60
        : theme.colorScheme.error;
    return AlertDialog(
      title: const Text('설정'),
      scrollable: true,
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('통계 표시'),
              value: _showStats,
              onChanged: (on) {
                setState(() => _showStats = on);
                widget.onShowStats(on);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('클립보드 공유'),
              subtitle: const Text('Mac에서 복사하면 여기로, 여기서 복사한 건 Cmd·Ctrl+V로 Mac에'),
              value: _shareClipboard,
              onChanged: (on) {
                setState(() => _shareClipboard = on);
                widget.onShareClipboard(on);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ctrl을 ⌘처럼 (PC 키보드)'),
              subtitle: const Text('연결한 키보드의 Ctrl+C·V·A가 Mac에서 복사·붙여넣기·전체 선택으로'),
              value: _ctrlAsCmd,
              onChanged: (on) {
                setState(() => _ctrlAsCmd = on);
                widget.onCtrlAsCmd(on);
              },
            ),
            const SizedBox(height: 8),
            Text('Mac 비밀번호 변경', style: theme.textTheme.titleSmall?.copyWith(color: Colors.white70)),
            const SizedBox(height: 10),
            _field(_current, '현재 비밀번호'),
            const SizedBox(height: 10),
            _field(_next, '새 비밀번호 (8자 이상)'),
            const SizedBox(height: 10),
            _field(_confirm, '새 비밀번호 확인', last: true),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_message!, style: TextStyle(fontSize: 13, color: messageColor)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('닫기')),
        FilledButton(onPressed: _busy ? null : _change, child: const Text('비밀번호 변경')),
      ],
    );
  }
}
