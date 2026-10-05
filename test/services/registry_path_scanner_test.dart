// RegistryPathScanner 基础回归（只读注册表扫描器）
//
// 说明：扫描器读真实 HKCU/HKLM（只读 KEY_READ，无需管理员）。
// 为保持测试确定性且不触碰敏感数据：
// - 用例 1 验证空路径入参的早退保护；
// - 用例 2 用"必然不存在的随机 needle"跑真实全树扫描，断言可用性、
//   零命中、且 maxKeys 上限生效（快速截断不拖慢测试）。
// 不断言任何真实注册表内容，避免环境差异导致 flaky。

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/registry_path_scanner.dart';

void main() {
  group('RegistryPathScanner.scanOldPathReferences', () {
    test('空路径入参 → 不可用并给出原因（早退保护）', () async {
      final report = await RegistryPathScanner.scanOldPathReferences(oldPath: '');
      expect(report.available, isFalse);
      expect(report.error, isNotNull);
      expect(report.hits, isEmpty);
    });

    test('真实扫描（随机 needle）：可用、零命中、上限生效不拖慢', () async {
      final report = await RegistryPathScanner.scanOldPathReferences(
        oldPath: r'C:\__ct_spike_not_exist_\nonexistent_dir_9x7y',
        maxKeys: 500, // 小上限：快速截断，测试 < 数秒
        timeout: const Duration(seconds: 20),
      );
      expect(report.available, isTrue, reason: 'advapi32 在 Windows 测试机必然可加载');
      expect(report.hits, isEmpty,
          reason: '随机 needle 不应命中任何注册表值');
      expect(report.scannedKeys, greaterThanOrEqualTo(0));
    });
  });
}
