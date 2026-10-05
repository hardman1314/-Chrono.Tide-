import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/manifest_service.dart';

/// ManifestService 单元测试
/// 验证单例初始化、asset 加载、查询接口的正确性
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await ManifestService.instance.init();
  });

  test('init 后 isReady 应为 true 且无错误', () {
    expect(ManifestService.instance.isReady, isTrue,
        reason: '清单加载后应就绪');
    expect(ManifestService.instance.loadError, isNull,
        reason: '加载成功不应有错误信息');
  });

  test('条目总数应大于 50000（完整版清单）', () {
    print('清单条目数: ${ManifestService.instance.count}');
    expect(ManifestService.instance.count, greaterThan(50000));
  });

  test('lookup 按游戏名查找 "!Anyway!"', () {
    final game = ManifestService.instance.lookup('!Anyway!');
    expect(game, isNotNull);
    expect(game!.steam.id, 866510);
    expect(game.files.length, 1);
    expect(game.cloud.steam, isTrue);
  });

  test('lookup 不存在的游戏返回 null', () {
    final game = ManifestService.instance.lookup('这是一个不存在的游戏名_xyz_123');
    expect(game, isNull);
  });

  test('lookupBySteamId 按 Steam App ID 查找 Celeste', () {
    final game = ManifestService.instance.lookupBySteamId(504230);
    expect(game, isNotNull);
    expect(game!.name, 'Celeste');
  });

  test('lookupBySteamId 不存在的 ID 返回 null', () {
    final game = ManifestService.instance.lookupBySteamId(999999999);
    expect(game, isNull);
  });

  test('fuzzyLookup 模糊查找 "witcher" 应返回非空', () {
    final results = ManifestService.instance.fuzzyLookup('witcher');
    expect(results, isNotEmpty);
    print('fuzzyLookup("witcher") 命中 ${results.length} 条');
  });

  test('init 幂等：重复调用不重新加载', () async {
    final countBefore = ManifestService.instance.count;
    await ManifestService.instance.init(); // 再次调用
    expect(ManifestService.instance.count, countBefore,
        reason: '幂等保护应跳过重复加载');
  });
}
