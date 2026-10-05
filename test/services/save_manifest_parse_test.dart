import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/save_manifest.dart';

/// 诊断测试：用现有 _SimpleYamlParser 解析完整版 manifest.yaml
/// 目的：确认解析耗时、条目数、字段丢失情况，为修复策略提供依据
void main() {
  late SaveManifest manifest;
  late Duration parseDuration;

  setUpAll(() {
    // ★ 体积优化：清单 asset 已改为 gzip 压缩（16.7MB → 2.2MB），此处同步解压
    final file = File('assets/data/manifest.yaml.gz');
    final bytes = file.readAsBytesSync();
    final yaml = GZipCodec().decode(bytes);
    final sw = Stopwatch()..start();
    manifest = SaveManifest.fromYaml(utf8.decode(yaml));
    sw.stop();
    parseDuration = sw.elapsed;
  });

  test('解析耗时与条目总数', () {
    print('解析耗时: ${parseDuration.inSeconds}.${(parseDuration.inMilliseconds % 1000)}s');
    print('文件大小(gz): ${(File('assets/data/manifest.yaml.gz').lengthSync() / 1024 / 1024).toStringAsFixed(1)}MB');
    print('解析条目数: ${manifest.count}');
    print('可处理条目数(非别名): ${manifest.processableCount}');
    expect(manifest.count, greaterThan(0));
  });

  test('!Anyway! 字段完整性（应有 files+cloud+steam+steamExtra）', () {
    final game = manifest.lookup('!Anyway!');
    expect(game, isNotNull, reason: '条目应存在');
    print('\n!Anyway! 字段检查:');
    print('  files: ${game!.files.length} (预期 1)');
    print('  steam.id: ${game.steam.id} (预期 866510)');
    print('  cloud.steam: ${game.cloud.steam} (预期 true)');
    print('  id.steamExtra: ${game.id.steamExtra} (预期含 867990)');
    print('  installDirs: ${game.installDirs} (预期含 Anyway)');
  });

  test('! That Bastard... 字段完整性（应有 registry+steam）', () {
    final game = manifest.lookup('! That Bastard Is Trying To Steal Our Gold !');
    expect(game, isNotNull, reason: '条目应存在');
    print('\n! That Bastard... 字段检查:');
    print('  registry: ${game!.registry.length} (预期 1，含 config+save)');
    print('  steam.id: ${game.steam.id} (预期 449940)');
    print('  installDirs: ${game.installDirs}');
    if (game.registry.isNotEmpty) {
      print('  registry path: ${game.registry.keys.first}');
      print('  registry tags: ${game.registry.values.first.tags}');
    }
  });

  test('Celeste 字段完整性', () {
    final game = manifest.lookup('Celeste');
    expect(game, isNotNull, reason: '条目应存在');
    print('\nCeleste 字段检查:');
    print('  files: ${game!.files.length}');
    print('  steam.id: ${game.steam.id} (预期 504230)');
    print('  cloud.steam: ${game.cloud.steam}');
  });

  test('lookupBySteamId 查询', () {
    final game = manifest.lookupBySteamId(866510); // !Anyway!
    print('\nlookupBySteamId(866510): ${game?.name ?? "未找到"}');
  });

  test('字段分布统计（诊断哪些字段解析成功）', () {
    int withFiles = 0, withRegistry = 0, withSteam = 0, withGog = 0;
    int withCloud = 0, withInstallDir = 0, withAlias = 0, withNotes = 0;
    int withLaunch = 0; // launch 不被 _parseGame 读取，但可间接判断

    for (final game in manifest.games.values) {
      if (game.files.isNotEmpty) withFiles++;
      if (game.registry.isNotEmpty) withRegistry++;
      if (game.steam.isNotEmpty) withSteam++;
      if (game.gog.isNotEmpty) withGog++;
      if (!game.cloud.isEmpty) withCloud++;
      if (game.installDirs.isNotEmpty) withInstallDir++;
      if (game.isAlias) withAlias++;
      if (game.notes.isNotEmpty) withNotes++;
    }

    print('\n========== 字段分布统计 ==========');
    print('总条目: ${manifest.count}');
    print('含 files: $withFiles');
    print('含 registry: $withRegistry');
    print('含 steam: $withSteam');
    print('含 gog: $withGog');
    print('含 cloud: $withCloud');
    print('含 installDir: $withInstallDir');
    print('含 alias: $withAlias');
    print('含 notes: $withNotes');
    print('===================================');
  });

  test('打印前 30 个条目概览', () {
    print('\n========== 前 30 条目 ==========');
    int i = 0;
    for (final game in manifest.games.values.take(30)) {
      final flags = <String>[];
      if (game.isAlias) flags.add('ALIAS');
      if (game.files.isNotEmpty) flags.add('files(${game.files.length})');
      if (game.registry.isNotEmpty) flags.add('reg(${game.registry.length})');
      if (game.steam.isNotEmpty) flags.add('steam:${game.steam.id}');
      print('  ${game.name} -> ${flags.join(", ")}');
      i++;
    }
    print('=================================\n');
  });
}
