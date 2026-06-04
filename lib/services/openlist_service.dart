import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/pb_config.dart';
import '../core/
class OpenListService {
  static final String _configRecordId = BackendConfig.openlistConfigRecordId;
fialBacendConfg.openlstConigRecordId
  static bool _isRunning = false;
  static Process? _process;
  static int? _processPid;
  static String? _authToken;

  static bool get isRunning => _isRunning;
  static int? get processPid => _processPid;
  static String? get authToken => _authToken;

  static Future<void> boot() async {
    debugPrint('[OL-BOOT] ======(
    await _login();

    debugPrint(
        '[OL-BOOT] ✅ OpenList 就绪 | PID: $_processPid | Token: ${_authToken != null ? "已获取(${_authToken!.length}字符)" : "未获取"}');
  }

  static Future<void> _ensureOpenListFiles() async {
    debugPrint('[OL-BOOT] 0/3 检查OpenList文件完整性');

    try {
      final olDir = Directory(PathHelper.openlistDir);
      final exeFile = File(PathHelper.openlistExePath);

      if (!await olDir.exists()) {
        await olDir.create(recursive: true);
        debugPrint('[OL-BOOT]   创建 ${PathHelper.openlistDir} 目录');
      }

      if (!await exeFile.exists()) {
        debugPrint('[OL-BOOT]   ❌ openlist.exe 不存在！请确认打包脚本已正确复制 openlist/ 目录');
        debugPrint('[OL-BOOT]   期望路径: ${PathHelper.openlistExePath}');
        return;
      } else {
        debugPrint(
            '[OL-BOOT]   ✅ openlist.exe 已存在，跳过提取 (${(await exeFile.length()).toStringAsFixed(1)}KB)');
      }

      debugPrint('[OL-BOOT]   ✅ OpenList 文件就绪 (data.zip将从服务器同步)');
    } catch (e) {
      debugPrint('[OL-BOOT]   ⚠️ OpenList文件检查异常: $e');
    }
  }

  static Future<void> _syncConfig() async {
    debugPrint('[OL-BOOT] 1/3 从PocketBase拉取data.zip配置');

    try {
      final pbUrl =
          '${PBConfig.pb.baseUrl}/api/collections/openlist_configs/records/$_configRecordId';
      debugPrint('[OL-BOOT]   PB请求地址: $pbUrl');

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..findProxy = (uri) => 'DIRECT';

      final request = await client.getUrl(Uri.parse(pbUrl));
      final response = await request.close();

      if (response.statusCode != 200) {
        debugPrint('[OL-BOOT] ❌ PB请求失败 (${response.statusCode})');
        client.close();
        return;
      }

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final zipUrl =
          data['dataZip'] ?? data['data_zip'] ?? data['zipUrl'] ?? '';

      if (zipUrl.isEmpty) {
        debugPrint('[OL-BOOT] ⚠️ 未找到data.zip下载链接，跳过配置同步');
        client.close();
        return;
      }

      String fullZipUrl = zipUrl;
      if (!zipUrl.startsWith('http')) {
        fullZipUrl =
            '${PBConfig.pb.baseUrl}/api/files/openlist_configs/$_configRecordId/$zipUrl';
      }

      debugPrint('[OL-BOOT]   data.zip URL: $fullZipUrl');

      final olDir = Directory(PathHelper.openlistDir);
      final dataDir = Directory(PathHelper.openlistDataDir);

      if (!await olDir.exists()) {
        await olDir.create(recursive: true);
      }
      if (!await dataDir.exists()) {
        await dataDir.create(recursive: true);
      }

      final zipPath = PathHelper.openlistDataZipPath;
      final zipFile = File(zipPath);

      bool downloadSuccess =
          await _downloadZipWithFullDiagnostics(client, fullZipUrl, zipFile);

      if (downloadSuccess) {
        bool isZipValid = await _verifyZipFileSignature(zipFile);
        if (!isZipValid) {
          debugPrint('[OL-BOOT] ❌ 下载的文件不是有效的ZIP格式！');
          await zipFile.delete();
          debugPrint('[OL-BOOT] 已删除无效文件，将使用本地缓存');
        } else {
          final needsExtract = await _needsDataExtraction(dataDir);
          if (needsExtract) {
            if (await dataDir.exists()) {
              await dataDir.delete(recursive: true);
              debugPrint('[OL-BOOT]   🗑️ 已清理旧/损坏的data目录');
            }
            await dataDir.create(recursive: true);

            bool extractSuccess =
                await _extractZipWithRobustMethod(zipPath, dataDir);

            if (extractSuccess) {
              await _fixNestedDataDir(dataDir.path);
              await _fixFilePermissionsAndEncoding(dataDir);
              bool isValid = await _validateExtractedDataWithDeepCheck(dataDir);
              if (isValid) {
                debugPrint('[OL-BOOT] ✅ 解压openlist/data完成并通过深度验证');
                await _logFinalDirectoryState(dataDir);
              } else {
                debugPrint('[OL-BOOT] ⚠️ 数据验证发现问题，但继续尝试启动...');
              }
            } else {
              debugPrint('[OL-BOOT] ❌ 所有解压方案均失败');
            }
          } else {
            debugPrint('[OL-BOOT]   ℹ️ data/ 目录已存在且有效，跳过解压');
          }
        }
      } else {
        debugPrint('[OL-BOOT] ⚠️ data.zip下载失败，使用本地缓存');
      }
      client.close();
    } catch (e, stackTrace) {
      debugPrint('[OL-BOOT] ⚠️ 配置同步异常: $e');
      debugPrint('[OL-BOOT] 堆栈信息: $stackTrace');
    }
  }

  static Future<bool> _downloadZipWithFullDiagnostics(
      HttpClient client, String url, File zipFile) async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[OL-DOWNLOAD] 🔍 开始深度诊断下载流程');
      debugPrint('[OL-DOWNLOAD] URL: $url');
      debugPrint('[OL-DOWNLOAD] 目标: ${zipFile.path}');
      debugPrint('═══════════════════════════════════════════════════════════');

      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);

      request.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      request.headers.set('Accept', '*/*');
      request.headers.set('Accept-Encoding', 'identity');

      final response = await request.close();

      debugPrint('[OL-DOWNLOAD] 📊 HTTP响应信息:');
      debugPrint('   状态码: ${response.statusCode}');
      debugPrint('   Content-Length: ${response.contentLength ?? "未知"}');
      debugPrint(
          '   ContentType: ${response.headers.value("content-type") ?? "未知"}');

      if (response.isRedirect || response.redirects.isNotEmpty) {
        debugPrint('   重定向次数: ${response.redirects.length}');
        for (var i = 0; i < response.redirects.length; i++) {
          debugPrint('   重定向[$i]: ${response.redirects[i].location}');
        }
      }

      if (response.statusCode != 200) {
        debugPrint('[OL-DOWNLOAD] ❌ HTTP错误: ${response.statusCode}');

        String errorBody = '';
        try {
          errorBody = await response.transform(utf8.decoder).join();
          if (errorBody.length > 500) {
            errorBody = '${errorBody.substring(0, 500)}...(截断)';
          }
          debugPrint('[OL-DOWNLOAD] 错误内容: $errorBody');
        } catch (_) {}

        return false;
      }

      final contentType =
          response.headers.value('content-type')?.toLowerCase() ?? '';
      if (contentType.contains('text/html') ||
          contentType.contains('application/json')) {
        debugPrint('[OL-DOWNLOAD] ⚠️ 响应Content-Type异常: $contentType');
        debugPrint('[OL-DOWNLOAD] 服务器可能返回了错误页面而非ZIP文件');
      }

      final contentLength = response.contentLength ?? -1;
      debugPrint(
          '[OL-DOWNLOAD] 📥 开始流式写入... (期望大小: ${contentLength > 0 ? "${(contentLength / 1024).toStringAsFixed(1)}KB" : "未知"})');

      final sink = zipFile.openWrite(mode: FileMode.writeOnly);
      final List<int> firstBytes = [];
      int totalBytes = 0;

      await for (final chunk in response) {
        sink.add(chunk);
        totalBytes += chunk.length;

        if (firstBytes.length < 16) {
          final needed = 16 - firstBytes.length;
          final toAdd =
              chunk.length > needed ? chunk.sublist(0, needed) : chunk;
          firstBytes.addAll(toAdd);
        }
      }

      await sink.flush();
      await sink.close();

      final actualSize = await zipFile.length();

      debugPrint('[OL-DOWNLOAD] ✅ 写入完成');
      debugPrint('   总字节数: $totalBytes');
      debugPrint(
          '   文件大小: ${actualSize}B (${(actualSize / 1024).toStringAsFixed(1)}KB)');

      if (firstBytes.isNotEmpty) {
        final hexHeader = firstBytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ');
        debugPrint('[OL-DOWNLOAD] 🔬 文件头(前16字节HEX): $hexHeader');

        final isPkZip = firstBytes[0] == 0x50 &&
            firstBytes[1] == 0x4B &&
            (firstBytes[2] == 0x03 ||
                firstBytes[2] == 0x05 ||
                firstBytes[2] == 0x06 ||
                firstBytes[2] == 0x07);
        debugPrint(
            '[OL-DOWNLOAD] ZIP签名检测: ${isPkZip ? "✅ PK签名有效" : "❌ 不是ZIP格式"}');

        if (!isPkZip && firstBytes.isNotEmpty) {
          try {
            final asciiText = String.fromCharCodes(
                firstBytes.where((b) => b >= 32 && b <= 126));
            if (asciiText.isNotEmpty) {
              debugPrint('[OL-DOWNLOAD] 文件头ASCII: "$asciiText"');
              if (asciiText.toLowerCase().contains('<html') ||
                  asciiText.toLowerCase().contains('<!doctype')) {
                debugPrint('[OL-DOWNLOAD] ❌❌❌ 检测到HTML内容！下载的是网页而非ZIP文件！');
              }
            }
          } catch (_) {}
        }
      }

      if (contentLength > 0 && actualSize != contentLength) {
        final diff = (actualSize - contentLength).abs();
        final diffPercent = (diff / contentLength * 100).toStringAsFixed(1);
        debugPrint('[OL-DOWNLOAD] ⚠️ 大小不匹配 | 差异: ${diff}B ($diffPercent%)');

        if (double.parse(diffPercent) > 1.0) {
          debugPrint('[OL-DOWNLOAD] ❌ 差异过大(>1%)，认为下载不完整');
          await zipFile.delete();
          return false;
        }
      }

      if (actualSize < 100) {
        debugPrint('[OL-DOWNLOAD] ❌ 文件过小(${actualSize}B)');
        try {
          final content = await zipFile.readAsString();
          debugPrint('[OL-DOWNLOAD] 文件内容: "$content"');
        } catch (_) {}
        await zipFile.delete();
        return false;
      }

      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[OL-DOWNLOAD] ✅✅✅ 下载完成并初步验证通过');
      debugPrint('═══════════════════════════════════════════════════════════');
      return true;
    } catch (e, stackTrace) {
      debugPrint('[OL-DOWNLOAD] ❌ 下载异常: $e');
      debugPrint('[OL-DOWNLOAD] 堆栈: $stackTrace');
      return false;
    }
  }

  static Future<bool> _verifyZipFileSignature(File zipFile) async {
    try {
      if (!await zipFile.exists()) {
        debugPrint('[OL-VERIFY] ❌ ZIP文件不存在');
        return false;
      }

      final stream = zipFile.openRead();
      final bytes = await stream.first;

      if (bytes.length < 4) {
        debugPrint('[OL-VERIFY] ❌ 文件太小(<4字节)');
        return false;
      }

      final signature = bytes.sublist(0, 4);
      final hexSig = signature
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');

      debugPrint('[OL-VERIFY] ZIP文件签名: $hexSig');

      bool isValid = (signature[0] == 0x50 && signature[1] == 0x4B) &&
          (signature[2] == 0x03 ||
              signature[2] == 0x05 ||
              signature[2] == 0x06 ||
              signature[2] == 0x07);

      if (isValid) {
        debugPrint('[OL-VERIFY] ✅ 确认是有效的ZIP/PK格式');
      } else {
        debugPrint('[OL-VERIFY] ❌ 无效的ZIP文件签名');
      }

      return isValid;
    } catch (e) {
      debugPrint('[OL-VERIFY] ❌ 验证异常: $e');
      return false;
    }
  }

  static Future<bool> _extractZipWithRobustMethod(
      String zipPath, Directory targetDir) async {
    debugPrint('═══════════════════════════════════════════════════════════');
    debugPrint('[OL-EXTRACT] 🔧 开始鲁棒性解压流程');
    debugPrint('[OL-EXTRACT] 压缩包: $zipPath');
    debugPrint('[OL-EXTRACT] 目标目录: ${targetDir.path}');
    debugPrint('═══════════════════════════════════════════════════════════');

    bool success7z = await _extractZipWith7zEnhanced(zipPath, targetDir.path);

    if (success7z) {
      debugPrint('[OL-EXTRACT] ✅ 7-Zip解压成功');
      return true;
    }

    debugPrint('[OL-EXTRACT] 7-Zip失败，尝试PowerShell备选...');
    bool successPS =
        await _extractZipWithPowerShellEnhanced(zipPath, targetDir.path);

    if (successPS) {
      debugPrint('[OL-EXTRACT] ✅ PowerShell解压成功');
      return true;
    }

    debugPrint('[OL-EXTRACT] ❌ 所有解压方法均失败');
    return false;
  }

  static Future<bool> _extractZipWith7zEnhanced(
      String zipPath, String targetDir) async {
    try {
      final exePath = PathHelper.bundled7zPath;
      final exeFile = File(exePath);

      if (!await exeFile.exists()) {
        debugPrint('[OL-7Z] ❌ 7z.exe不存在: $exePath');
        return false;
      }

      debugPrint('[OL-7Z] 使用增强版7-Zip参数解压');

      final args = [
        'x',
        zipPath.replaceAll('/', '\\'),
        '-o$targetDir',
        '-y',
        '-aoa',
        '-spf',
        '-tzip',
      ];

      debugPrint('[OL-7Z] 完整命令:');
      debugPrint('   $exePath ${args.join(" ")}');

      final result = await Process.run(
        exePath,
        args,
        workingDirectory: targetDir,
        runInShell: false,
        includeParentEnvironment: true,
      );

      final exitCode = result.exitCode;
      final stdoutContent = result.stdout.toString().trim();
      final stderrContent = result.stderr.toString().trim();

      debugPrint('[OL-7Z] 执行结果:');
      debugPrint('   退出码: $exitCode');

      if (stdoutContent.isNotEmpty) {
        final lines = stdoutContent
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        debugPrint('   STDOUT (${lines.length}行):');
        for (final line in lines.take(15)) {
          debugPrint('   | ${line.trim()}');
        }
        if (lines.length > 15) {
          debugPrint('   | ... 还有${lines.length - 15}行');
        }
      }

      if (stderrContent.isNotEmpty) {
        final lines = stderrContent.split('\n');
        debugPrint('   STDERR (${lines.length}行):');
        for (final line in lines.take(5)) {
          debugPrint('   ! ${line.trim()}');
        }
        if (lines.length > 5) {
          debugPrint('   ! ... 还有${lines.length - 5}行');
        }
      }

      if (exitCode == 0 || exitCode == 1) {
        if (exitCode == 1) {
          debugPrint('[OL-7Z] ⚠️ 退出码1(警告)，但可能已成功解压');
        }

        final dirCheck = Directory(targetDir);
        if (await dirCheck.exists()) {
          final entities = await dirCheck.list(recursive: true).toList();
          final files = entities.whereType<File>().toList();
          final dirs = entities.whereType<Directory>().toList();

          debugPrint('[OL-7Z] 📁 解压结果统计:');
          debugPrint('   文件数: ${files.length}');
          debugPrint('   目录数: ${dirs.length}');

          if (files.isEmpty) {
            debugPrint('[OL-7Z] ❌ 未提取到任何文件');
            return false;
          }

          debugPrint('[OL-7Z] 提取的文件列表:');
          for (final file in files) {
            final name = file.uri.pathSegments.last;
            final size = await file.length();
            debugPrint('   ✓ $name (${size}B)');
          }

          return true;
        } else {
          debugPrint('[OL-7Z] ❌ 目标目录不存在');
          return false;
        }
      } else {
        debugPrint('[OL-7Z] ❌ 7-Zip执行失败(退出码=$exitCode)');

        if (exitCode == 2) {
          debugPrint('[OL-7Z] 致命错误');
        } else if (exitCode == 7) {
          debugPrint('[OL-7Z] 命令行错误');
        } else if (exitCode == 8) {
          debugPrint('[OL-7Z] 内存不足');
        } else if (exitCode == 255) {
          debugPrint('[OL-7Z] 用户中断');
        }

        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('[OL-7Z] ❌ 异常: $e');
      debugPrint('[OL-7Z] 堆栈: $stackTrace');
      return false;
    }
  }

  static Future<bool> _extractZipWithPowerShellEnhanced(
      String zipPath, String targetDir) async {
    try {
      debugPrint('[OL-PS] PowerShell增强解压模式');

      final psScript = '''
        \$ErrorActionPreference = "Stop"
        
        Write-Host "开始解压..."
        Write-Host "源文件: $zipPath"
        Write-Host "目标目录: $targetDir"
        
        if (-not (Test-Path "$zipPath")) {
            Write-Host "ERROR: 源文件不存在"
            exit 1
        }
        
        if (-not (Test-Path "$targetDir")) {
            New-Item -ItemType Directory -Path "$targetDir" -Force | Out-Null
        }
        
        try {
            Expand-Archive -LiteralPath "$zipPath" -DestinationPath "$targetDir" -Force
            
            \$files = Get-ChildItem -Path "$targetDir" -Recurse -File
            Write-Host ("提取文件数: " + \$files.Count)
            
            foreach (\$file in \$files) {
                Write-Host ("  FILE: " + \$file.Name + " (" + \$file.Length + " bytes)")
            }
            
            exit 0
        } catch {
            Write-Host ("ERROR: " + \$_.Exception.Message)
            exit 2
        }
      ''';

      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          psScript,
        ],
        runInShell: true,
      );

      final exitCode = result.exitCode;
      final output = result.stdout.toString().trim();
      final errors = result.stderr.toString().trim();

      debugPrint('[OL-PS] 退出码: $exitCode');

      if (output.isNotEmpty) {
        for (final line in output.split('\n')) {
          debugPrint('[OL-PS] > ${line.trim()}');
        }
      }

      if (errors.isNotEmpty) {
        debugPrint('[OL-PS] 错误: $errors');
      }

      return exitCode == 0;
    } catch (e) {
      debugPrint('[OL-PS] 异常: $e');
      return false;
    }
  }

  static Future<void> _fixFilePermissionsAndEncoding(Directory dataDir) async {
    try {
      debugPrint('[OL-FIX] 🔧 检查文件编码（只读模式，不修改内容）...');

      await for (final entity in dataDir.list(recursive: true)) {
        if (entity is File) {
          try {
            final name = entity.uri.pathSegments.last;

            if (name.endsWith('.json')) {
              final bytes = await entity.readAsBytes();

              if (bytes.isNotEmpty) {
                if (bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
                  debugPrint('[OL-FIX] ⚠️ $name 包含UTF-8 BOM标记（保留原样不修改）');
                }

                String text = await entity.readAsString();

                debugPrint('[OL-FIX] 📄 $name:');
                debugPrint('   大小: ${bytes.length}B');
                debugPrint(
                    '   前100字符: ${text.length > 100 ? text.substring(0, 100) + "..." : text}');

                try {
                  final json = jsonDecode(text) as Map<String, dynamic>;
                  debugPrint('   JSON格式: ✅ 有效');
                  debugPrint('   顶层键: ${json.keys.toList()}');

                  if (json.containsKey('users')) {
                    debugPrint('   users字段: ✅ 存在');
                  } else {
                    debugPrint('   ⚠️ users字段: ❌ 不存在（OpenList可能使用数据库存储用户）');
                  }
                } catch (e) {
                  debugPrint('   JSON格式: ❌ 无效 ($e)');
                }
              }
            }
          } catch (e) {
            debugPrint('[OL-FIX] 检查文件失败(${entity.path}): $e');
          }
        }
      }

      debugPrint('[OL-FIX] ✅ 检查完成（未修改任何文件）');
    } catch (e) {
      debugPrint('[OL-FIX] ⚠️ 检查过程出错: $e');
    }
  }

  static Future<bool> _validateExtractedDataWithDeepCheck(
      Directory dataDir) async {
    try {
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint('[OL-VALIDATE] 🔍 开始深度数据验证');
      debugPrint('═══════════════════════════════════════════════════════════');

      if (!await dataDir.exists()) {
        debugPrint('[OL-VALIDATE] ❌ data目录不存在');
        return false;
      }

      final configFile =
          File('${dataDir.path}${Platform.pathSeparator}config.json');
      final dbFile = File('${dataDir.path}${Platform.pathSeparator}data.db');

      int validCount = 0;
      int totalCount = 3;

      if (await configFile.exists()) {
        final configSize = await configFile.length();
        debugPrint('[OL-VALIDATE] 📄 config.json:');
        debugPrint('   存在: ✅');
        debugPrint('   大小: ${configSize}B');

        try {
          final rawBytes = await configFile.readAsBytes();

          if (rawBytes.isNotEmpty) {
            final hexStart = rawBytes
                .take(8)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join(' ');
            debugPrint('   文件头HEX: $hexStart');

            if (rawBytes[0] == 0xEF &&
                rawBytes[1] == 0xBB &&
                rawBytes[2] == 0xBF) {
              debugPrint('   ⚠️ 包含UTF-8 BOM标记（应该已移除）');
            }
          }

          final content = await configFile.readAsString();

          if (content.trim().isEmpty) {
            debugPrint('   ❌ 内容为空');
          } else {
            final json = jsonDecode(content) as Map<String, dynamic>;
            debugPrint('   JSON格式: ✅ 有效');
            debugPrint('   顶层键: ${json.keys.toList()}');

            bool hasUsers = false;
            bool hasValidUser = false;

            if (json.containsKey('users') && json['users'] is List) {
              hasUsers = true;
              final users = json['users'] as List;
              debugPrint('   用户数: ${users.length}');

              if (users.isNotEmpty) {
                final first = users.first;
                if (first is Map<String, dynamic>) {
                  final username = first['username']?.toString() ?? '';
                  final password = first['password']?.toString() ?? '';

                  debugPrint('   首用户名: "$username"');
                  debugPrint(
                      '   密码长度: ${password.length > 0 ? password.length : 0}');

                  if (username.isNotEmpty) {
                    hasValidUser = true;
                  }

                  if (username == BackendConfig.openlistAdminUsername && password == BackendConfig.openlistAdminPassword) {
                    debugPrint('   ℹ️ 使用配置中的凭据');
                  }
                }
              }
            } else {
              debugPrint('   ⚠️ 缺少users字段或格式错误');
            }

            List<String> storageKeys = [
              'scheme',
              'database',
              'store',
              'storage',
              'driver'
            ];
            List<String> foundStorageKeys = [];
            for (final key in storageKeys) {
              if (json.containsKey(key)) {
                foundStorageKeys.add(key);
              }
            }

            if (foundStorageKeys.isNotEmpty) {
              debugPrint('   存储配置: ✅ 发现键 [${foundStorageKeys.join(", ")}]');
            } else {
              debugPrint('   ⚠️ 未找到存储驱动配置');
            }

            if (hasUsers && hasValidUser) {
              validCount++;
              debugPrint('   ✅ 配置验证通过');
            } else {
              debugPrint('   ⚠️ 用户配置有问题');
            }
          }
        } catch (e) {
          debugPrint('   ❌ JSON解析失败: $e');
        }
      } else {
        debugPrint('[OL-VALIDATE] ❌ config.json 不存在');
      }

      if (await dbFile.exists()) {
        final dbSize = await dbFile.length();
        debugPrint('[OL-VALIDATE] 💾 data.db:');
        debugPrint('   存在: ✅');
        debugPrint('   大小: ${(dbSize / 1024).toStringAsFixed(1)}KB');

        if (dbSize >= 4096) {
          validCount++;
          debugPrint('   ✅ 大小合理(>=4KB)');
        } else if (dbSize >= 1024) {
          validCount++;
          debugPrint('   ⚠️ 较小但可接受(1-4KB)');
        } else {
          debugPrint('   ❌ 过小(<1KB)，可能损坏');
        }

        try {
          final dbBytes = await dbFile.readAsBytes();
          final header = String.fromCharCodes(dbBytes.take(16));
          debugPrint('   文件头文本: "$header"');
        } catch (e) {
          debugPrint('   无法读取文件头: $e');
        }
      } else {
        debugPrint('[OL-VALIDATE] ℹ️ data.db 不存在（首次启动正常）');
        validCount++;
      }

      final entities = await dataDir.list(recursive: true).toList();
      final files = entities.whereType<File>().toList();
      final dirs = entities.whereType<Directory>().toList();

      debugPrint('[OL-VALIDATE] 📁 目录结构:');
      debugPrint('   总文件数: ${files.length}');
      debugPrint('   子目录数: ${dirs.length}');

      if (files.length >= 2) {
        validCount++;
        debugPrint('   ✅ 文件数量充足(≥2)');
      } else {
        debugPrint('   ⚠️ 文件数量偏少(<2)');
      }

      debugPrint('   文件列表:');
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final size = await file.length();
        final modified = await file.lastModified();
        final timeStr = modified.toString().substring(0, 19);
        debugPrint('   📄 $name | ${size}B | $timeStr');
      }

      final passRate = (validCount / totalCount * 100).toStringAsFixed(0);
      debugPrint('');
      debugPrint('[OL-VALIDATE] 📊 验证结果汇总:');
      debugPrint('   通过项: $validCount/$totalCount');
      debugPrint('   通过率: $passRate%');

      bool allValid = validCount >= 2;

      if (allValid) {
        debugPrint('');
        debugPrint('✅✅✅ 深度验证通过！OpenList配置数据看起来正常 ✅✅✅');
      } else {
        debugPrint('');
        debugPrint('⚠️ 验证未完全通过，但OpenList可能仍能工作');
      }

      debugPrint('═══════════════════════════════════════════════════════════');

      return allValid;
    } catch (e, stackTrace) {
      debugPrint('[OL-VALIDATE] ❌ 验证异常: $e');
      debugPrint('[OL-VALIDATE] 堆栈: $stackTrace');
      return false;
    }
  }

  static Future<void> _logFinalDirectoryState(Directory dataDir) async {
    try {
      debugPrint('');
      debugPrint('🎯 ═════════════════════════════════════════════════════');
      debugPrint('🎯 最终目录状态报告');
      debugPrint('🎯 ═════════════════════════════════════════════════════');
      debugPrint('🎯 路径: ${dataDir.path}');
      debugPrint('');

      final entities = await dataDir.list(recursive: true).toList();
      final files = entities.whereType<File>().toList();
      final dirs = entities.whereType<Directory>().length;

      debugPrint('🎯 统计信息:');
      debugPrint('   文件总数: ${files.length}');
      debugPrint('   目录总数: $dirs');
      debugPrint('');

      debugPrint('🎯 详细文件列表:');
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final relativePath = file.path.substring(dataDir.path.length + 1);
        debugPrint('   📄 $relativePath');
      }

      debugPrint('');
      debugPrint('🎯 ═════════════════════════════════════════════════════');
      debugPrint('🎯 准备启动OpenList进程...');
      debugPrint('🎯 ═════════════════════════════════════════════════════');
      debugPrint('');
    } catch (e) {
      debugPrint('⚠️ 无法生成最终状态报告: $e');
    }
  }

  static Future<bool> _needsDataExtraction(Directory dataDir) async {
    if (!await dataDir.exists()) return true;

    final configFile =
        File('${dataDir.path}${Platform.pathSeparator}config.json');
    final dbFile = File('${dataDir.path}${Platform.pathSeparator}data.db');

    if (!await configFile.exists() || !await dbFile.exists()) return true;

    final dbSize = await dbFile.length();
    if (dbSize < 1024) {
      debugPrint('[OL-BOOT]   ⚠️ data.db 过小 (${dbSize}B)，可能损坏，需要重新解压');
      return true;
    }

    return false;
  }

  static Future<void> _fixNestedDataDir(String targetDir) async {
    try {
      final dir = Directory(targetDir);
      if (!await dir.exists()) return;

      final entities = await dir.list().toList();
      final topDirs =
          entities.where((e) => e is Directory).cast<Directory>().toList();
      final topFiles = entities.where((e) => e is File).cast<File>().toList();

      if (topDirs.length == 1 &&
          topFiles.isEmpty &&
          topDirs.first.path.endsWith('data')) {
        final nested = topDirs.first;
        bool hasExpectedFiles = false;
        await for (final entity in nested.list()) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name == 'config.json' || name == 'data.db' || name == 'log') {
            hasExpectedFiles = true;
            break;
          }
        }

        if (hasExpectedFiles) {
          debugPrint('[OL-BOOT] 🔧 检测到嵌套 data/ 目录，移动内容到父级...');
          await for (final entity in nested.list(recursive: false)) {
            final name = entity.path.split(Platform.pathSeparator).last;
            final destPath = '$targetDir${Platform.pathSeparator}$name';
            if (entity is File) {
              await entity.rename(destPath);
            } else if (entity is Directory) {
              final destDir = Directory(destPath);
              if (!await destDir.exists()) {
                await entity.rename(destPath);
              } else {
                await for (final sub in entity.list(recursive: true)) {
                  final subRelativePath =
                      sub.path.substring(entity.path.length + 1);
                  final subDestPath =
                      '$destPath${Platform.pathSeparator}$subRelativePath';
                  if (sub is File) {
                    final subParentDir = Directory(subDestPath.substring(
                        0, subDestPath.lastIndexOf(Platform.pathSeparator)));
                    if (!await subParentDir.exists()) {
                      await subParentDir.create(recursive: true);
                    }
                    await sub.rename(subDestPath);
                  }
                }
                await entity.delete(recursive: true);
              }
            }
          }
          final remaining = await nested.list().toList();
          if (remaining.isEmpty) {
            await nested.delete();
          }
          debugPrint('[OL-BOOT] ✅ 嵌套已修复');
        }
      }
    } catch (e) {
      debugPrint('[OL-BOOT] ⚠️ 嵌套修复非致命错误: $e');
    }
  }

  static Future<void> _startProcess() async {
    debugPrint('[OL-BOOT] 2/3 启动OpenList进程（端口5244）');

    try {
      final exePath = PathHelper.openlistExePath;
      final exeFile = File(exePath);

      if (!await exeFile.exists()) {
        debugPrint('[OL-BOOT] ❌ openlist.exe不存在于 ${PathHelper.openlistDir} 目录');
        return;
      }

      final args = [
        '--config',
        PathHelper.openlistConfigPath,
        '--data',
        PathHelper.openlistDataDir,
        'server'
      ];
      final cmdLine = '$exePath ${args.join(' ')}';
      debugPrint('[OL-BOOT]   启动命令: $cmdLine');

      _process = await Process.start(
        exePath,
        args,
        workingDirectory: PathHelper.openlistDir,
        mode: ProcessStartMode.detachedWithStdio,
      );

      _processPid = _process?.pid;
      _isRunning = true;
      debugPrint('[OL-BOOT] ✅ 启动成功 | PID: $_processPid | 监听: 127.0.0.1:5244');
    } catch (e) {
      debugPrint('[OL-BOOT] ❌ 启动失败: $e');
    }
  }

  static Future<void> _waitForReady() async {
    debugPrint('[OL-BOOT]   等待OpenList服务就绪（最长15秒）...');

    const checkUrl = 'http://127.0.0.1:5244/api/public/settings';
    bool ready = false;

    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(seconds: 1));

      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..findProxy = (uri) => 'DIRECT';

        final request = await client.getUrl(Uri.parse(checkUrl));
        final response = await request.close();
        final localPort = request.connectionInfo?.localPort ?? 0;

        debugPrint(
            '[OL-BOOT]   轮询检测[$i]: $checkUrl | 绑定端口: $localPort | 响应码: ${response.statusCode}');

        if (response.statusCode == 200) {
          ready = true;
          debugPrint(
              '[OL-BOOT] ✅ OpenList服务就绪 (HTTP 200, 端口5244, 耗时${i + 1}s)');
          client.close();
          break;
        }
        client.close();
      } catch (e) {
        debugPrint('[OL-BOOT]   轮询检测[$i]: 连接中... ($e)');
      }
    }

    if (!ready) {
      debugPrint('[OL-BOOT] ⚠️ 15秒内未就绪，OpenList可能启动失败或端口被占用');
    }
  }

  static Future<void> _login() async {
    debugPrint('[OL-AUTH] ═════════ 开始多策略登录尝试 ═════════');

    final loginUrl = 'http://127.0.0.1:5244/api/auth/login';

    List<Map<String, String>> credentialsList = [
      _readCredentialsFromConfig(),
      {'username': BackendConfig.openlistAdminUsername, 'password': BackendConfig.openlistAdminPassword},
      {'username': '', 'password': ''},
    ];

    credentialsList = credentialsList.where((c) => c.isNotEmpty).toList();
    debugPrint('[OL-AUTH] 准备尝试 ${credentialsList.length} 组凭据');

    for (int i = 0; i < credentialsList.length; i++) {
      final credentials = credentialsList[i];
      final username = credentials['username'] ?? '(空)';
      final password = credentials['password'] ?? '';

      debugPrint(
          '[OL-AUTH] ── 尝试 ${i + 1}/${credentialsList.length}: 用户="$username" 密码="${password.isNotEmpty ? '*' * password.length : '(空)'}"');

      try {
        bool success = await _attemptLogin(loginUrl, credentials);

        if (success) {
          debugPrint('[OL-AUTH] ✅ 登录成功 (第${i + 1}次尝试)');
          return;
        } else {
          debugPrint('[OL-AUTH] ❌ 第${i + 1}次尝试失败');
        }
      } catch (e) {
        debugPrint('[OL-AUTH] ⚠️ 第${i + 1}次尝试异常: $e');
      }

      if (i < credentialsList.length - 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    debugPrint('[OL-AUTH] ❌ 所有登录尝试均失败');
    debugPrint('[OL-AUTH]   Token状态: 未获取');
    debugPrint('[OL-AUTH]   可能原因:');
    debugPrint('     1. config.json中没有有效的用户配置');
    debugPrint('     2. data.db数据库损坏或不包含用户数据');
    debugPrint('     3. OpenList需要首次初始化设置');
    debugPrint('[OL-AUTH]   将尝试无Token访问（可能会被拒绝）');
    debugPrint('[OL-AUTH] ═════════ 登录尝试结束 ═════════');
  }

  static Future<bool> _attemptLogin(
      String loginUrl, Map<String, String> credentials) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = (uri) => 'DIRECT';

    try {
      final request = await client.postUrl(Uri.parse(loginUrl))
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(credentials));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      debugPrint(
          '[OL-AUTH]     HTTP ${response.statusCode} | Body: ${responseBody.length > 100 ? responseBody.substring(0, 100) + "..." : responseBody}');

      if (response.statusCode == 200) {
        final json = jsonDecode(responseBody);
        final data = json['data'];
        if (data is Map<String, dynamic>) {
          _authToken = data['token']?.toString();
        }

        if (_authToken != null && _authToken!.isNotEmpty) {
          debugPrint('[OL-AUTH]     ✅ 获取Token成功 | 长度: ${_authToken!.length}');
          client.close();
          return true;
        } else {
          debugPrint('[OL-AUTH]     ⚠️ 响应200但无Token');
          client.close();
          return false;
        }
      } else {
        client.close();
        return false;
      }
    } catch (e) {
      client.close();
      rethrow;
    }
  }

  static Map<String, String> _readCredentialsFromConfig() {
    final configFile = File(PathHelper.openlistConfigPath);
    if (configFile.existsSync()) {
      try {
        final content = configFile.readAsStringSync();
        final config = jsonDecode(content) as Map<String, dynamic>;

        debugPrint('[OL-AUTH]   读取config.json:');
        debugPrint('     文件大小: ${content.length}字符');

        final users = config['users'];
        if (users is List && users.isNotEmpty) {
          debugPrint('     users字段: ✅ 存在 (${users.length}个用户)');

          final firstUser = users.first;
          if (firstUser is Map<String, dynamic>) {
            final username = firstUser['username']?.toString() ?? '';
            final password = firstUser['password']?.toString() ?? '';

            if (username.isNotEmpty) {
              debugPrint('     首用户: $username');
              return {'username': username, 'password': password};
            }
          }
        } else {
          debugPrint('     users字段: ❌ 不存在 或为空');
          debugPrint('     可用键: ${config.keys.toList()}');
        }
      } catch (e) {
        debugPrint('[OL-AUTH]   读取config.json失败: $e');
      }
    } else {
      debugPrint(
          '[OL-AUTH]   config.json不存在: ${PathHelper.openlistConfigPath}');
    }

    return {};
  }

  static Map<String, String> _readCredentials() {
    return _readCredentialsFromConfig().isNotEmpty
        ? _readCredentialsFromConfig()
        : {'username': BackendConfig.openlistAdminUsername, 'password': BackendConfig.openlistAdminPassword};
  }

  static Future<String?> getGameDownloadUrl(String gamePath) async {
    debugPrint('[OL-LINK] 收到游戏路径: $gamePath');

    const requestUrl = 'http://127.0.0.1:5244/api/fs/get';
    debugPrint('[OL-LINK] 请求 OpenList 接口: $requestUrl');

    if (!_isRunning) {
      debugPrint('[OL-LINK] ❌ OpenList未运行');
      return null;
    }

    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..findProxy = (uri) => 'DIRECT';

      if (_authToken != null && _authToken!.isNotEmpty) {
        debugPrint('[OL-LINK] 携带Authorization Token请求');
      } else {
        debugPrint('[OL-LINK] ⚠️ 无Token，尝试无认证请求');
      }

      final request = await client.postUrl(Uri.parse(requestUrl))
        ..headers.contentType = ContentType.json;

      if (_authToken != null && _authToken!.isNotEmpty) {
        request.headers.set('Authorization', _authToken!);
      }

      request.write(jsonEncode({'path': gamePath}));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      debugPrint(
          '[OL-LINK] HTTP ${response.statusCode} | 响应体: ${responseBody.length > 500 ? responseBody.substring(0, 500) + '...(截断)' : responseBody}');

      client.close();

      if (response.statusCode != 200) {
        if (response.statusCode == 401 && _authToken != null) {
          debugPrint('[OL-LINK] ❌ 401 Token失效，尝试重新登录...');
          _authToken = null;
          await _login();
          if (_authToken != null) {
            return getGameDownloadUrl(gamePath);
          }
        }
        debugPrint('[OL-LINK] ❌ HTTP错误 (${response.statusCode})');
        return null;
      }

      final json = jsonDecode(responseBody);
      final innerData = json['data'];
      String rawUrl = '';

      if (innerData is Map<String, dynamic>) {
        rawUrl = innerData['raw_url'] ?? '';
      } else if (json['raw_url'] != null) {
        rawUrl = json['raw_url'].toString();
      }

      if (rawUrl.isNotEmpty) {
        debugPrint('[OL-LINK] ✅ 解析 raw_url 成功 (${rawUrl.length}字符)');
        return rawUrl;
      } else {
        debugPrint('[OL-LINK] 解析 raw_url 失败：字段不存在 / 为空');
        return null;
      }
    } catch (e) {
      debugPrint('[OL-LINK] ❌ 请求异常: $e');
      return null;
    }
  }

  static void stop() {
    if (_process != null) {
      _process!.kill();
      _process = null;
    }
    if (_processPid != null) {
      debugPrint('[OL-BOOT] 终止OpenList进程 PID=$_processPid');
      try {
        Process.runSync('taskkill', ['/PID', '$_processPid', '/F', '/T']);
      } catch (_) {}
      _processPid = null;
    }
    _isRunning = false;
    debugPrint('[OL-BOOT] OpenList进程已停止');
  }

  static Future<void> dispose() async {
    debugPrint('[OL-BOOT] ═══════════ 开始强制清理OpenList进程 ═══════════');

    stop();

    for (int attempt = 1; attempt <= 3; attempt++) {
      debugPrint('[OL-BOOT] 清理尝试 $attempt/3...');
      await Future.delayed(Duration(milliseconds: 500 * attempt));

      bool stillRunning = await _isProcessStillRunning();
      if (!stillRunning) {
        debugPrint('[OL-BOOT] ✅ OpenList进程已完全终止 (尝试$attempt)');
        break;
      }

      debugPrint('[OL-BOOT] ⚠️ 进程仍在运行，执行强力终止...');

      try {
        final result = await Process.run(
          'taskkill',
          ['/IM', 'openlist.exe', '/F', '/T'],
        );

        if (result.exitCode == 0) {
          debugPrint('[OL-BOOT] ✅ taskkill 成功 (尝试$attempt)');
        } else {
          final stderr = result.stderr.toString().trim();
          if (stderr.toLowerCase().contains('not found') || stderr.isEmpty) {
            debugPrint('[OL-BOOT] ✅ 无残留openlist.exe进程');
            break;
          } else {
            debugPrint('[OL-BOOT] ⚠️ taskkill 返回: $stderr');
          }
        }
      } catch (e) {
        debugPrint('[OL-BOOT] ❌ taskkill 异常: $e');
      }

      if (attempt == 3) {
        debugPrint('[OL-BOOT] ❌ 3次尝试后OpenList可能仍未完全终止');
      }
    }

    _isRunning = false;
    _process = null;
    _processPid = null;
    _authToken = null;
    debugPrint('[OL-BOOT] ═══════════ OpenList清理完成 ═══════════');
  }

  static Future<bool> _isProcessStillRunning() async {
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq openlist.exe', '/NH', '/FO', 'CSV'],
      );
      final output = result.stdout.toString().trim();
      return output.toLowerCase().contains('openlist.exe');
    } catch (_) {
      return false;
    }
  }
}
