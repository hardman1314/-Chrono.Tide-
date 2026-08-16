import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/pb_config.dart';

class UserCacheService {
  static const String _keyUserId = 'user_id';
  static const String _keyUserName = 'user_name';
  static const String _keyUserBio = 'user_bio';
  static const String _keyUserAvatarBase64 = 'user_avatar_base64';

  static bool _isInitialized = false;
  static late SharedPreferences _prefs;

  static bool get isInitialized => _isInitialized;

  static Future<void> init() async {
    if (_isInitialized) return;
    _prefs = await SharedPreferences.getInstance();
    _isInitialized = true;
    debugPrint('[USER-CACHE] init done');
  }

  static Future<bool> saveUserInfo({
    required String userId,
    required String name,
    String bio = '',
    String? avatarUrl,
    Uint8List? avatarBytes,
  }) async {
    if (!_isInitialized) await init();
    try {
      await _prefs.setString(_keyUserId, userId);
      await _prefs.setString(_keyUserName, name);
      await _prefs.setString(_keyUserBio, bio);

      if (avatarBytes != null && avatarBytes.isNotEmpty) {
        final b64 = base64Encode(avatarBytes);
        await _prefs.setString(_keyUserAvatarBase64, b64);
        debugPrint('[USER-CACHE] avatar cached');
      } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
        debugPrint('[USER-CACHE] avatarUrl: $avatarUrl');
      } else {
        await _prefs.remove(_keyUserAvatarBase64);
      }
      return true;
    } catch (e) {
      debugPrint('[USER-CACHE] saveUserInfo error: $e');
      return false;
    }
  }

  static String? get userId {
    return _isInitialized ? _prefs.getString(_keyUserId) : null;
  }

  static String get userName {
    return _isInitialized ? (_prefs.getString(_keyUserName) ?? '') : '';
  }

  static String get userBio {
    return _isInitialized ? (_prefs.getString(_keyUserBio) ?? '') : '';
  }

  static String? get userAvatarBase64 {
    return _isInitialized ? _prefs.getString(_keyUserAvatarBase64) : null;
  }

  static bool get hasCachedData {
    return _isInitialized && userId != null && userId!.isNotEmpty;
  }

  static bool get hasCachedAvatar {
    return userAvatarBase64 != null && userAvatarBase64!.isNotEmpty;
  }

  static Future<void> updateName(String newName) async {
    if (!_isInitialized) return;
    await _prefs.setString(_keyUserName, newName);
  }

  static Future<void> updateBio(String newBio) async {
    if (!_isInitialized) return;
    await _prefs.setString(_keyUserBio, newBio);
  }

  static Future<void> updateAvatarFromBytes(List<int> bytes) async {
    if (!_isInitialized) return;
    try {
      final b64 = base64Encode(bytes);
      await _prefs.setString(_keyUserAvatarBase64, b64);
    } catch (e) {
      debugPrint('[USER-CACHE] updateAvatar error: $e');
    }
  }

  static Future<void> clearAll() async {
    if (!_isInitialized) return;
    await _prefs.remove(_keyUserId);
    await _prefs.remove(_keyUserName);
    await _prefs.remove(_keyUserBio);
    await _prefs.remove(_keyUserAvatarBase64);
  }

  /// buildUserAvatar - priority: avatarBytes > avatarUrl download > local cache > default
  static Widget buildUserAvatar({
    double size = 50,
    required Widget defaultAvatar,
    Uint8List? avatarBytes,
    String? avatarUrl,
  }) {
    // Priority 1: pre-downloaded bytes (most reliable)
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      return ClipOval(
        child: Image.memory(
          avatarBytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (c, e, s) => defaultAvatar,
        ),
      );
    }

    // Priority 2: download from URL with auth header
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return _AvatarDownloader(
        url: avatarUrl,
        size: size,
        defaultAvatar: defaultAvatar,
      );
    }

    // Priority 3: local base64 cache
    return _CachedAvatarWidget(size: size, defaultAvatar: defaultAvatar);
  }
}

/// Download avatar from URL with Bearer token
class _AvatarDownloader extends StatefulWidget {
  final String url;
  final double size;
  final Widget defaultAvatar;

  const _AvatarDownloader({
    required this.url,
    required this.size,
    required this.defaultAvatar,
  });

  @override
  State<_AvatarDownloader> createState() => _AvatarDownloaderState();
}

class _AvatarDownloaderState extends State<_AvatarDownloader> {
  Uint8List? _bytes;
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(_AvatarDownloader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _done = false;
      _failed = false;
      _fetch();
    }
  }

  Future<void> _fetch() async {
    try {
      final token = PBConfig.pb.authStore.token;
      final headers = <String, String>{};
      if (token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final resp = await http
          .get(
            Uri.parse(widget.url),
            headers: headers,
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        setState(() {
          _bytes = resp.bodyBytes;
          _done = true;
        });
        // Save to local cache
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            'user_avatar_base64',
            base64Encode(resp.bodyBytes),
          );
        } catch (_) {}
      } else {
        setState(() {
          _failed = true;
          _done = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _done = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_done || _bytes == null || _failed) {
      if (_failed) {
        return _CachedAvatarWidget(
          size: widget.size,
          defaultAvatar: widget.defaultAvatar,
        );
      }
      return widget.defaultAvatar;
    }
    return ClipOval(
      child: Image.memory(
        _bytes!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => widget.defaultAvatar,
      ),
    );
  }
}

/// Read avatar from local base64 cache
class _CachedAvatarWidget extends StatelessWidget {
  final double size;
  final Widget defaultAvatar;

  const _CachedAvatarWidget({
    required this.size,
    required this.defaultAvatar,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return defaultAvatar;
        final b64 = snapshot.data!.getString('user_avatar_base64');
        if (b64 != null && b64.isNotEmpty) {
          try {
            final bytes = Uint8List.fromList(base64Decode(b64));
            return ClipOval(
              child: Image.memory(
                bytes,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => defaultAvatar,
              ),
            );
          } catch (_) {}
        }
        return defaultAvatar;
      },
    );
  }
}
