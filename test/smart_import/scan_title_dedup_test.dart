// 智能导入排重修复回归测试（2026-09-13，用户报告：同一游戏不同嵌套被重复识别导入）
//
// 覆盖三类根因：
// ① 同名非包含副本（远月案例）：五阶段旧管线只有路径维度去重，互不包含的
//    同名目录双双入队 → 阶段 4a 同名副本去重；
// ② 救援顺序缺陷：阶段 2.5 救援的父目录 append 在末尾，"子先父后"使父子
//    重叠去重失效 → 阶段 4b 深度升序遍历；
// ③ 救援传播：包装目录的内容游戏在别处已有代表时，包装目录本身也是重复
//    → 阶段 4c。
// 另覆盖 TitleCleaner.normalizeForCompare 与 WatchFolderService.compactCandidates。
//
// ⚠️ 临时目录建在 D:\ 根（不用 systemTemp）：AppData 等路径段会触发识别器
// 系统路径负信号（-50）导致置信度不足；目录名带微秒时间戳避免跨运行竞态
// （gal_game_detector_test 的既有教训）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/models/watch_folder.dart';
import 'package:chrono_tide/pages/join/utils/game_folder_scanner.dart';
import 'package:chrono_tide/services/watch_folder_service.dart';
import 'package:chrono_tide/utils/title_cleaner.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory(
        'D:\\ct_scan_dedup_test_${DateTime.now().microsecondsSinceEpoch}');
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 构造一个最小 kiriKiri 游戏目录：data.xp3（强信号）+ game.exe（直接 exe）
  /// 置信度 = (40 + 15 + 10) / 100 = 0.65，isGame=true
  Directory makeKirikiriGame(String parentPath, String name) {
    final dir = Directory(p.join(parentPath, name))..createSync(recursive: true);
    File(p.join(dir.path, 'data.xp3')).writeAsStringSync('xp3');
    File(p.join(dir.path, 'game.exe')).writeAsStringSync('exe');
    return dir;
  }

  group('扫描管线同名/嵌套去重', () {
    test('① ATRI 同名三层嵌套只保留一份（平手保留更浅目录）', () async {
      final atri = Directory(p.join(root.path, 'ATRI'))..createSync();
      final lvl2 = makeKirikiriGame(atri.path, 'ATRI -My Dear Moments-');
      makeKirikiriGame(lvl2.path, 'ATRI -My Dear Moments-');

      final games = await GameFolderScanner.scanGames(rootPath: root.path);

      expect(games, hasLength(1), reason: '同名嵌套副本必须合并为一份');
      expect(games.single.path.toLowerCase(), lvl2.path.toLowerCase(),
          reason: '识别度平手时保留路径更浅的一份');
    });

    test('② 远月案例：同题不同父目录 + 救援包装目录，只保留一份', () async {
      final top = makeKirikiriGame(root.path, '远月少女的礼仪.1');
      final wrapper = Directory(p.join(root.path, '远月少女的礼仪.2.1'))
        ..createSync();
      makeKirikiriGame(wrapper.path, '远月少女的礼仪.1');

      final games = await GameFolderScanner.scanGames(rootPath: root.path);

      expect(games, hasLength(1),
          reason: '同名副本与其救援包装目录都应被淘汰，只留顶层一份');
      expect(games.single.path.toLowerCase(), top.path.toLowerCase());
    });

    test('③ 同名但引擎明确不同 → 保守保留两份（不同游戏）', () async {
      final a = Directory(p.join(root.path, 'A'))..createSync();
      final navK = Directory(p.join(a.path, 'Nav'))..createSync();
      File(p.join(navK.path, 'data.xp3')).writeAsStringSync('x');
      File(p.join(navK.path, 'krkr.exe')).writeAsStringSync('x');

      final b = Directory(p.join(root.path, 'B'))..createSync();
      final navU = Directory(p.join(b.path, 'Nav'))..createSync();
      File(p.join(navU.path, 'unityplayer.dll')).writeAsStringSync('x');
      File(p.join(navU.path, 'Nav.exe')).writeAsStringSync('x');

      final games = await GameFolderScanner.scanGames(rootPath: root.path);

      expect(games, hasLength(2),
          reason: 'kirikiri vs unity 的同名目录更可能是两个游戏，不合并');
    });

    test('④ 救援包装目录与其不同名子游戏：保留祖先（深度排序修复）', () async {
      final wrapper = Directory(p.join(root.path, '命运石之门'))..createSync();
      makeKirikiriGame(wrapper.path, 'DST');

      final games = await GameFolderScanner.scanGames(rootPath: root.path);

      expect(games, hasLength(1),
          reason: '旧实现"子先父后"会让父子双双入选；排序修复后保留祖先');
      expect(games.single.path.toLowerCase(), wrapper.path.toLowerCase());
    });

    test('⑤ 不同名的两个游戏不受影响（防误杀）', () async {
      makeKirikiriGame(root.path, '游戏A');
      makeKirikiriGame(root.path, '游戏B');

      final games = await GameFolderScanner.scanGames(rootPath: root.path);

      expect(games, hasLength(2));
    });
  });

  group('TitleCleaner.normalizeForCompare', () {
    test('全角折叠 / 大小写 / 标点空白不影响同题判定', () {
      expect(
        TitleCleaner.normalizeForCompare('ＡＴＲＩ -My Dear Moments-'),
        TitleCleaner.normalizeForCompare('atri -my dear moments-'),
      );
      expect(
        TitleCleaner.normalizeForCompare('远月少女的礼仪.１'),
        TitleCleaner.normalizeForCompare('远月少女的礼仪.1'),
      );
    });

    test('无字母数字/CJK 内容时返回空键（调用方应跳过合并）', () {
      expect(TitleCleaner.normalizeForCompare('···---'), isEmpty);
    });
  });

  group('WatchFolderService.compactCandidates（启动队列自愈）', () {
    ImportCandidate cand(String dir, String title, double conf,
            {String engine = 'unknown', String? metadataTitle}) =>
        ImportCandidate(
          dirPath: dir,
          inferredTitle: title,
          confidence: conf,
          discoveredAt: DateTime(2026, 9, 13),
          engineType: engine,
          metadataTitle: metadataTitle,
        );

    test('同名父子对保留识别度更高者（与扫描 4a 语义一致）', () {
      final parent = cand('E:\\GAL\\X', 'X', 0.65);
      final child = cand('E:\\GAL\\X\\X', 'X', 1.0);
      final out = WatchFolderService.compactCandidates([parent, child]);
      expect(out, hasLength(1));
      expect(out.single.dirPath, child.dirPath);
    });

    test('不同名父子对保留祖先（与扫描 4b 语义一致）', () {
      final parent = cand('E:\\GAL\\包装', '包装', 0.4);
      final child = cand('E:\\GAL\\包装\\真游戏', '真游戏', 0.9);
      final out = WatchFolderService.compactCandidates([parent, child]);
      expect(out, hasLength(1));
      expect(out.single.dirPath, parent.dirPath);
    });

    test('同题不同父目录保留识别度最高者（远月队列残留场景）', () {
      final nested = cand('E:\\GAL\\远月少女的礼仪.2.1\\远月少女的礼仪.1', '远月少女的礼仪.1', 0.43);
      final top = cand('E:\\GAL\\远月少女的礼仪.1', '远月少女的礼仪.1', 0.70);
      final out = WatchFolderService.compactCandidates([nested, top]);
      expect(out, hasLength(1));
      expect(out.single.dirPath, top.dirPath);
    });

    test('引擎冲突的同名候选都保留', () {
      final a = cand('E:\\GAL\\A\\Nav', 'Nav', 0.65, engine: 'kirikiri');
      final b = cand('E:\\GAL\\B\\Nav', 'Nav', 0.50, engine: 'unity');
      final out = WatchFolderService.compactCandidates([a, b]);
      expect(out, hasLength(2));
    });

    test('元数据同名（两份副本抓到同一条元数据）也视为重复', () {
      final a = cand('E:\\GAL\\ATRI\\ATRI -My Dear Moments-',
          'ATRI -My Dear Moments-', 0.65);
      final b = cand('E:\\GAL\\ATRI\\备份', 'ATRI 备份', 1.0,
          metadataTitle: 'ATRI -My Dear Moments-');
      final out = WatchFolderService.compactCandidates([a, b]);
      expect(out, hasLength(1));
      expect(out.single.dirPath, a.dirPath, reason: '先保留者优先');
    });
  });
}
