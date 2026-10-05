// Win32 文件属性 FFI 回归测试（★ P0-6，2026-09-16 稳定性审计）
//
// 目标：`.ctgame` 的"清属性 → 写 → 设隐藏"不再依赖 Process.run('attrib')：
// 2000 条导入 = 4000 次进程创建。此处验证 FFI 路径可用、行为正确，
// 且失败时返回 false（调用方回退到 attrib 进程，双保险）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/win32_file_attributes.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
        'ct_win32_attr_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('Windows 上 FFI 可用（kernel32 可加载）', () {
    if (!Platform.isWindows) return;
    expect(Win32FileAttributes.isAvailable, isTrue);
  });

  test('clearReadOnlyHidden 对已存在文件成功、非存在路径失败', () {
    if (!Platform.isWindows) return;
    final file = File('${temp.path}${Platform.pathSeparator}.ctgame')
      ..writeAsStringSync('{"format_version":1}');

    expect(Win32FileAttributes.clearReadOnlyHidden(file.path), isTrue);
    expect(
      Win32FileAttributes.clearReadOnlyHidden(
          '${temp.path}${Platform.pathSeparator}missing.ctgame'),
      isFalse,
      reason: '路径不存在 → 返回 false，调用方回退 attrib 进程',
    );
  });

  test('setHidden 幂等且不影响文件内容', () {
    if (!Platform.isWindows) return;
    final file = File('${temp.path}${Platform.pathSeparator}.ctgame')
      ..writeAsStringSync('{"format_version":1}');

    expect(Win32FileAttributes.setHidden(file.path), isTrue);
    expect(Win32FileAttributes.setHidden(file.path), isTrue,
        reason: '已是隐藏属性 → 二次调用仍应成功（幂等）');
    expect(file.readAsStringSync(), '{"format_version":1}');

    // 清属性后仍可重写（模拟重复入库场景）
    expect(Win32FileAttributes.clearReadOnlyHidden(file.path), isTrue);
    file.writeAsStringSync('{"format_version":2}');
    expect(file.readAsStringSync(), '{"format_version":2}');
  });
}
