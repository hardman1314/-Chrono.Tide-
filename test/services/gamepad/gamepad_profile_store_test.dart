import 'dart:async';
import 'dart:io';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/gamepad/gamepad_profile.dart';
import 'package:chrono_tide/services/gamepad/gamepad_profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2 持久化单测（独立文件存储范式的验证套件）。
///
/// 用 `PathHelper.exeDirOverride` 指到临时目录，隔离磁盘写入。
/// ⚠️ 必须在任何 PathHelper getter 被解析之前设置 override。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ct_gamepad_store_test');
    PathHelper.exeDirOverride = tmp.path;
  });

  tearDown(() {
    PathHelper.exeDirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  /// 测试里手工写文件用的辅助（store 自己写时会建父目录，测试直写需自建）
  File rawFile() {
    final f = File(PathHelper.gamepadProfilesFilePath);
    f.parent.createSync(recursive: true);
    return f;
  }

  group('save / load 往返', () {
    test('类型化保存后可原样读回', () async {
      final file = GamepadProfileFile(
        profiles: {
          'game-1': const GamepadProfile(
            gameTitle: '白色相簿2',
            preset: 'generic_vn',
            enabled: true,
            mappings: [
              GamepadMapping(
                  source: GamepadSource.a,
                  action: GamepadAction.key(13),
                  mode: GamepadMappingMode.tap),
            ],
          ),
        },
        defaults: const GamepadProfile(preset: 'generic_vn'),
      );

      await GamepadProfileStore.save(file);
      await GamepadProfileStore.flush();

      final loaded = await GamepadProfileStore.load();
      expect(loaded.profiles['game-1']?.gameTitle, '白色相簿2');
      expect(loaded.profiles['game-1']?.mappings.single.source,
          GamepadSource.a);
      expect(loaded.defaults.preset, 'generic_vn');
      expect(loaded.updatedAt, isNotNull);
    });

    test('落盘的是独立文件 gamepad_profiles.json（不触碰 game.json）', () async {
      await GamepadProfileStore.save(GamepadProfileFile());
      await GamepadProfileStore.flush();

      final f = File(PathHelper.gamepadProfilesFilePath);
      expect(f.existsSync(), isTrue);
      expect(f.path.endsWith('gamepad_profiles.json'), isTrue);
      expect(f.path.contains('game.json'), isFalse);
    });

    test('原子写：成功后不残留 .tmp', () async {
      await GamepadProfileStore.save(GamepadProfileFile());
      await GamepadProfileStore.flush();

      final tmp = File('${PathHelper.gamepadProfilesFilePath}.tmp');
      expect(tmp.existsSync(), isFalse, reason: 'rename 后 .tmp 应消失');
    });

    test('首次保存自动创建 data/ 目录', () async {
      expect(Directory(PathHelper.dataDir).existsSync(), isFalse);
      await GamepadProfileStore.save(GamepadProfileFile());
      await GamepadProfileStore.flush();
      expect(Directory(PathHelper.dataDir).existsSync(), isTrue);
    });
  });

  group('容错（绝不抛错）', () {
    test('文件不存在 → load 返回内置默认', () async {
      final loaded = await GamepadProfileStore.load();
      expect(loaded.profiles, isEmpty);
      expect(loaded.defaults.preset, GamepadPresets.steamosVnId);
    });

    test('文件损坏 → load 降级为内置默认', () async {
      rawFile().writeAsStringSync('{ 不是合法 JSON');
      final loaded = await GamepadProfileStore.load();
      expect(loaded.defaults.preset, GamepadPresets.steamosVnId);
      expect(loaded.profiles, isEmpty);
    });

    test('format_version 不认 → loadRaw 返回 null', () async {
      rawFile().writeAsStringSync('{"format_version": 99, "profiles": {}}');
      expect(await GamepadProfileStore.loadRaw(), isNull);
    });

    test('空文件 → loadRaw 返回 null', () async {
      rawFile().writeAsStringSync('');
      expect(await GamepadProfileStore.loadRaw(), isNull);
    });

    test('JSON 非对象（数组）→ loadRaw 返回 null', () async {
      rawFile().writeAsStringSync('[1,2,3]');
      expect(await GamepadProfileStore.loadRaw(), isNull);
    });
  });

  group('写合并（last-write-wins）', () {
    // ⚠️ save() 会强制盖真实 updated_at（保证文件新鲜度），
    //    因此断言「最后一份载荷生效」必须用 profile 内容，不能用 updatedAt。

    test('顺序两次保存：各写一次盘，最终为最后一份载荷', () async {
      final w0 = GamepadProfileStore.debugWriteCount;

      await GamepadProfileStore.save(GamepadProfileFile(profiles: {
        'g1': const GamepadProfile(gameTitle: '第一份'),
      }));
      await GamepadProfileStore.save(GamepadProfileFile(profiles: {
        'g2': const GamepadProfile(gameTitle: '第二份'),
      }));
      await GamepadProfileStore.flush();

      expect(GamepadProfileStore.debugWriteCount - w0, 2);
      final loaded = await GamepadProfileStore.load();
      expect(loaded.profiles.keys.toSet(), {'g2'},
          reason: '每份载荷是全量快照，最后一次保存生效');
      expect(loaded.profiles['g2']?.gameTitle, '第二份');
    });

    test('写入期间连发的多次保存塌缩为最后一次载荷', () async {
      // 用写盘钩子模拟慢写：drain 在写第 1 份期间挂起，此时第 2/3 份依次入队
      // （第 2 份被第 3 份覆盖）→ 恢复后只应再写第 3 份。
      final hookStarted = Completer<void>();
      GamepadProfileStore.debugWriteHook = () async {
        // ⚠️ 钩子会被每次写盘调用，complete 必须幂等
        // （对已完成 Completer 重复 complete 会抛 StateError，
        //   该异常会被 store 的容错 catch 吞掉，导致后续载荷被跳过）
        if (!hookStarted.isCompleted) hookStarted.complete();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      };
      addTearDown(() => GamepadProfileStore.debugWriteHook = null);

      final w0 = GamepadProfileStore.debugWriteCount;
      final f1 = GamepadProfileStore.save(GamepadProfileFile(profiles: {
        'g1': const GamepadProfile(gameTitle: '写入中'),
      }));
      await hookStarted.future; // 确认 drain 已挂起在钩子上
      final f2 = GamepadProfileStore.save(GamepadProfileFile(profiles: {
        'g2': const GamepadProfile(gameTitle: '入队A'),
      }));
      final f3 = GamepadProfileStore.save(GamepadProfileFile(profiles: {
        'g3': const GamepadProfile(gameTitle: '入队B'),
      }));

      expect(identical(f2, f3), isTrue, reason: '同批调用共享同一次落盘 future');
      await f1;
      await f3;
      await GamepadProfileStore.flush();

      final w1 = GamepadProfileStore.debugWriteCount;
      expect(w1 - w0, 2, reason: '第 1 份 + 第 3 份各写一次；第 2 份被塌缩');
      final loaded = await GamepadProfileStore.load();
      expect(loaded.profiles.keys.toSet(), {'g3'}, reason: '最后入队的载荷生效');
      expect(loaded.profiles['g3']?.gameTitle, '入队B');
    });

    test('flush 后无待写载荷', () async {
      await GamepadProfileStore.save(GamepadProfileFile());
      await GamepadProfileStore.flush();
      expect(GamepadProfileStore.isWriting, isFalse);
    });
  });
}
