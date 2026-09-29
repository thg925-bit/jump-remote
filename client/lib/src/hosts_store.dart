import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A Mac the user has connected to before.
class SavedHost {
  const SavedHost({required this.address, required this.password, this.name});

  /// IP or hostname, optionally with `:port`.
  final String address;
  final String password;

  /// Mac name reported by the host on the last connection.
  final String? name;

  SavedHost copyWith({String? name}) =>
      SavedHost(address: address, password: password, name: name ?? this.name);

  Map<String, dynamic> toJson() =>
      {'address': address, 'password': password, 'name': name};

  factory SavedHost.fromJson(Map<String, dynamic> json) => SavedHost(
        address: json['address'] as String,
        password: json['password'] as String? ?? '',
        name: json['name'] as String?,
      );
}

class HostsStore {
  static const _key = 'jump.hosts';

  Future<List<SavedHost>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SavedHost.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Puts [host] first, replacing any entry with the same address.
  Future<List<SavedHost>> remember(SavedHost host) async {
    final hosts = (await load()).where((h) => h.address != host.address).toList()
      ..insert(0, host);
    await _save(hosts);
    return hosts;
  }

  /// Replaces the saved password for [address], if that Mac is remembered.
  Future<List<SavedHost>> updatePassword(String address, String password) async {
    final hosts = [
      for (final host in await load())
        host.address == address ? SavedHost(address: host.address, password: password, name: host.name) : host,
    ];
    await _save(hosts);
    return hosts;
  }

  Future<List<SavedHost>> forget(String address) async {
    final hosts = (await load()).where((h) => h.address != address).toList();
    await _save(hosts);
    return hosts;
  }

  Future<void> _save(List<SavedHost> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(hosts.map((h) => h.toJson()).toList()));
  }
}
