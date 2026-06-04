import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import '../core/pb_config.dart';
import '../core/backend_config.dart';
import '../models/game_model.dart';

class GameRepository {
  static const int pageSize = 20;

  static Future<List<GameModel>> getGameList({
    int page = 1,
    int perPage = pageSize,
    String searchQuery = '',
  }) async {
    if (!BackendConfig.isBackendAvailable) {
      return [];
    }

    debugPrint('[PB] 开始请求PB games集合');
    debugPrint(
        '[PB]   请求地址: ${PBConfig.pb.baseUrl}/api/collections/games/records');
    debugPrint(
        '[PB]   参数: page=$page, perPage=$perPage${searchQuery.isNotEmpty ? ', 搜索: "$searchQuery"' : ''}');

    try {
      final filter = searchQuery.isNotEmpty ? "title ~ '$searchQuery'" : null;

      final result = await PBConfig.pb.collection('games').getList(
            page: page,
            perPage: perPage,
            sort: '-created',
            filter: filter,
            expand: '',
          );

      final games =
          result.items.map((record) => GameModel.fromPBRecord(record)).toList();

      debugPrint('[PB] ✅ 请求成功，返回条数: ${games.length}');
      if (games.isEmpty) {
        debugPrint('[PB] ⚠️ 请求成功，但games集合无数据');
      } else {
        for (var i = 0; i < games.length; i++) {
          final g = games[i];
          debugPrint(
              '[PB]   游戏[${i + 1}]: Title="${g.title}", coverURL=${g.coverUrl.isNotEmpty ? g.coverUrl : "(无)"}');
        }
      }

      return games;
    } on ClientException catch (e) {
      if (_isNetworkError(e)) {
        debugPrint('[ERROR] ❌ PB网络异常 - getGameList: ${e.toString()}');
        throw Exception('网络连接失败，请检查网络后重试');
      }
      debugPrint(
          '[ERROR] ❌ PB请求失败 (${e.statusCode}) - getGameList: ${e.toString()}');
      throw Exception('获取游戏列表失败 (${e.statusCode})');
    } catch (e) {
      if (e is SocketException || e is IOException) {
        debugPrint('[ERROR] ❌ PB连接异常 - getGameList: $e');
        throw Exception('无法连接服务器，请检查网络连接');
      }
      debugPrint('[ERROR] ❌ PB未知错误 - getGameList: $e');
      throw Exception('获取游戏列表时发生未知错误');
    }
  }

  static Future<GameModel?> getGameById(String gameId) async {
    if (!BackendConfig.isBackendAvailable) {
      return null;
    }

    debugPrint('[PB] 开始获取游戏详情 | gameId=$gameId');

    try {
      final record = await PBConfig.pb.collection('games').getOne(gameId);
      final game = GameModel.fromPBRecord(record);

      debugPrint(
          '[PB] ✅ 游戏详情加载成功 | Title="${game.title}" | coverURL=${game.coverUrl.isNotEmpty ? game.coverUrl : "(无)"} | Tags: ${game.tags.join(', ')}');

      return game;
    } on ClientException catch (e) {
      if (e.statusCode == 404) {
        debugPrint('[ERROR] ❌ 游戏不存在 ($gameId): ${e.toString()}');
        throw Exception('游戏不存在或已被删除');
      }
      if (_isNetworkError(e)) {
        debugPrint('[ERROR] ❌ PB网络异常 - getGameById: ${e.toString()}');
        throw Exception('网络连接失败，请检查网络后重试');
      }
      debugPrint(
          '[ERROR] ❌ PB请求失败 (${e.statusCode}) - getGameById: ${e.toString()}');
      throw Exception('获取游戏详情失败 (${e.statusCode})');
    } catch (e) {
      if (e is SocketException || e is IOException) {
        debugPrint('[ERROR] ❌ PB连接异常 - getGameById: $e');
        throw Exception('无法连接服务器，请检查网络连接');
      }
      debugPrint('[ERROR] ❌ PB未知错误 - getGameById: $e');
      throw Exception('获取游戏详情时发生未知错误');
    }
  }

  static bool _isNetworkError(ClientException e) {
    final originalError = e.originalError;
    if (originalError is SocketException) return true;
    if (originalError is IOException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('connection') ||
        msg.contains('timeout') ||
        msg.contains('socket') ||
        msg.contains('failed to connect');
  }
}
