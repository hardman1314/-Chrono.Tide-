// PortableSharedPreferencesStore 写入合并回归测试（★ P0-3，2026-09-16 稳定性审计）
//
// 旧问题：每次 set* 都 `json.encode(整份 prefs)` + `writeAsStringSync(flush:true)`，
// 大 prefs + 高频写入时把 UI isolate 占满（"导入时其他功能也卡"的共性根因）。
// 现要求：同一事件循环内的多次 set* 合并为**一次**编码 + 写盘，且落盘为异步。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/portable_shared_preferences_store.dart';

void main() {
  late Directory temp;
  late File prefsFile;

  setUp(() {
    temp = Directory.systemTemp
        .createTempSync('ct_prefs_coalesce_${DateTime.now().microsecondsSinceEpoch}');
    prefsFile = File('${temp.path}${Platform.pathSeparator}prefs.json');
    PortableSharedPreferencesStore.debugWriteCount = 0;
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('同一轮内的多次写入合并为一次落盘', () async {
    final store = PortableSharedPreferencesStore(prefsFile);

    // 同一事件循环内连续 50 次写入（模拟扫描期的高频保存）
    final futures = <Future<bool>>[];
    for (var i = 0; i < 50; i++) {
      futures.add(store.setValue('String', 'flutter.key_$i', 'value_$i'));
    }
    await Future.wait(futures);

    expect(PortableSharedPreferencesStore.debugWriteCount, 1,
        reason: '同轮写入必须合并为一次编码+写盘（旧实现是 50 次）');

    final decoded = json.decode(prefsFile.readAsStringSync()) as Map;
    expect(decoded.length, 50, reason: '合并写盘不得丢键');
    expect(decoded['flutter.key_49'], 'value_49');
  });

  test('跨轮写入会各自落盘（不丢更新）', () async {
    final store = PortableSharedPreferencesStore(prefsFile);

    await store.setValue('String', 'flutter.a', '1');
    expect(PortableSharedPreferencesStore.debugWriteCount, 1);

    await store.setValue('String', 'flutter.b', '2');
    expect(PortableSharedPreferencesStore.debugWriteCount, 2);

    final decoded = json.decode(prefsFile.readAsStringSync()) as Map;
    expect(decoded['flutter.a'], '1');
    expect(decoded['flutter.b'], '2');
  });

  test('写入后不残留 .tmp 文件（原子写收尾）', () async {
    final store = PortableSharedPreferencesStore(prefsFile);
    await store.setValue('String', 'flutter.x', 'y');
    await store.flushPending();

    expect(File('${prefsFile.path}.tmp').existsSync(), isFalse);
    expect(prefsFile.existsSync(), isTrue);
  });
}
