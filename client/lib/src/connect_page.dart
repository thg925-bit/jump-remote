import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hosts_store.dart';
import 'session.dart';
import 'viewer_page.dart';
import 'app_version.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _store = HostsStore();
  final _address = TextEditingController();
  final _password = TextEditingController();
  List<SavedHost> _hosts = [];
  bool _busy = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _store.load().then((hosts) {
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        if (hosts.isNotEmpty) {
          _address.text = hosts.first.address;
          _password.text = hosts.first.password;
        }
      });
    });
  }

  @override
  void dispose() {
    _address.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect(String address, String password) async {
    address = address.trim();
    if (_busy || address.isEmpty) return;
    setState(() => _busy = true);

    final media = MediaQuery.of(context);
    final session = Session(
      address: address,
      password: password,
      viewportPixels: media.size * media.devicePixelRatio,
      devicePixelRatio: media.devicePixelRatio,
    );
    // Before the first frame, so the Mac starts small on a metered link (the viewer's 📶 tile).
    session.saver = (await SharedPreferences.getInstance()).getBool('jump.saver') ?? false;
    if (!mounted) return;

    var remembered = false;
    void rememberOnConnect() {
      if (remembered || session.phase != SessionPhase.connected) return;
      remembered = true;
      _store
          .remember(SavedHost(address: address, password: password, name: session.hostName))
          .then((hosts) {
        if (mounted) setState(() => _hosts = hosts);
      });
    }

    session.addListener(rememberOnConnect);
    unawaited(session.start());

    final error = await Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => ViewerPage(session: session)),
    );

    session.removeListener(rememberOnConnect);
    final failure = error ?? session.error;
    // The viewer saved a password changed during the session; show the updated list.
    final changedPassword = session.password != password ? session.password : null;
    session.dispose();
    final hosts = changedPassword != null ? await _store.load() : null;
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (hosts != null) _hosts = hosts;
      if (changedPassword != null && _address.text.trim() == address) _password.text = changedPassword;
    });
    if (failure != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure)));
    }
  }

  Future<void> _forget(SavedHost host) async {
    final hosts = await _store.forget(host.address);
    if (mounted) setState(() => _hosts = hosts);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.all(20),
              shrinkWrap: true,
              children: [
                Text('Wherever', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Mac 원격 제어', style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white60)),
                const SizedBox(height: 24),
                if (_hosts.isNotEmpty) ...[
                  Text('최근 연결', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final host in _hosts)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.laptop_mac),
                        title: Text(host.name ?? host.address),
                        subtitle: host.name != null ? Text(host.address) : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '삭제',
                          onPressed: () => _forget(host),
                        ),
                        onTap: _busy ? null : () => _connect(host.address, host.password),
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
                Text('새 연결', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _address,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Mac 주소 또는 링크',
                    hintText: '192.168.0.10 · 100.x.x.x · https://…/#id=…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: '비밀번호',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                      tooltip: _showPassword ? '비밀번호 숨기기' : '비밀번호 보기',
                      onPressed: () => setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                  onSubmitted: (_) => _connect(_address.text, _password.text),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : () => _connect(_address.text, _password.text),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('연결'),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Mac 메뉴바의 Wherever Host 아이콘에서 주소·"어디서나 접속" 링크·비밀번호를 볼 수 있습니다.',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                ),
                if (appVersionLabel.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    appVersionLabel,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
