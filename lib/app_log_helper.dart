import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppLogHelper {
  static File? _logFile;
  static bool _initDone = false;

  static Future<void> initLog() async {
    if (_initDone) return;

    String logDirPath = ''; // 初始化默认值

    try {
      // 优先尝试获取开发根目录（用于调试）
      final exePath = Platform.resolvedExecutable;
      final exeDir = File(exePath).parent;

      // 开发模式：从 exe 向上查找 logs 文件夹
      // Release模式：build/windows/x64/runner/Release/
      // Debug模式：build/windows/x64/runner/Debug/
      // 目标：项目根目录 /logs/

      var currentDir = exeDir;
      for (int i = 0; i < 5; i++) {
        // 最多向上查找5层
        final candidateLogs = Directory("${currentDir.path}\\logs");
        if (await candidateLogs.exists()) {
          logDirPath = candidateLogs.path;
          print("✅ 找到logs文件夹：$logDirPath");
          break;
        }

        // 检查是否到达根目录
        final parent = currentDir.parent;
        if (parent.path == currentDir.path) {
          break; // 已到根目录
        }
        currentDir = parent;
      }

      // 如果没找到logs文件夹，就在exe同级创建
      if (logDirPath == null) {
        logDirPath = "${exeDir.path}\\logs";
        print("⚠️ 未找到logs文件夹，将在：$logDirPath 创建");
      }
    } catch (e) {
      // 如果上述方法失败，回退到当前工作目录
      logDirPath = "${Directory.current.path}\\logs";
      print("⚠️ 使用备用路径：$logDirPath (错误: $e)");
    }

    // 确保logs目录存在
    final logDir = Directory(logDirPath);
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
      print("📁 创建logs目录：${logDir.path}");
    }

    // 生成带日期的日志文件名
    final now = DateTime.now();
    final dateStr =
        "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    _logFile = File("$logDirPath\\CT_${dateStr}_运行日志.txt");

    _initDone = true;
    print("✅ 日志已启动：${_logFile!.path}");
  }

  static void info(String msg) {
    final time = DateTime.now().toString().substring(0, 19);
    final content = "[$time] [信息] $msg\n";
    print(content);
    _save(content);
  }

  static void error(String title, dynamic e, StackTrace stack) {
    final time = DateTime.now().toString().substring(0, 19);
    final content = "[$time] [错误] $title\n$e\n$stack\n\n";
    print(content);
    _save(content);
  }

  static Future<void> _save(String text) async {
    if (_logFile == null) return;
    try {
      await _logFile!.writeAsString(text, mode: FileMode.append);
    } catch (e) {
      // 如果写入失败，打印到控制台但不崩溃
      print("❌ 日志写入失败：$e");
    }
  }

  // 这里的方法名是 runCatch，和 update_service.dart 里的调用完全对应
  static Future<T> runCatch<T>(String tag, Future<T> Function() fn) async {
    try {
      info("开始执行：$tag");
      final res = await fn();
      info("执行成功：$tag");
      return res;
    } catch (e, stack) {
      error("执行失败：$tag", e, stack);
      rethrow;
    }
  }
}

void setupGlobalCatchError() {
  FlutterError.onError = (details) {
    AppLogHelper.error(
        "界面渲染错误", details.exception, details.stack ?? StackTrace.current);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogHelper.error("后台隐形异常", error, stack);
    return true;
  };
}
