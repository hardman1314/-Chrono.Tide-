import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/services/bpm_backdrop_media.dart';
import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/services/bpm_op_video_preference.dart';

void main() {
  late Directory tmp;

  /// 直接写 game.json（不走 updateGameJson —— 它要求文件已存在）
  void writeGameJson(Map<String, dynamic> data) {
    File('${tmp.path}/${GameDataFormat.gameJsonFileName}')
        .writeAsStringSync(jsonEncode(data));
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bpm_media_test_');
    // 🔴 updateGameJson 只对「已存在」的 game.json 做 merge（文件不存在返回
    //    false，见其 doc 注释），所以每个用例先落一个最小基底文件 ——
    //    真实场景里游戏必然已入库（game.json 必然存在），语义等价。
    writeGameJson(<String, dynamic>{
      'format_version': GameDataFormat.currentVersion,
    });
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> readGameJson() =>
      jsonDecode(File('${tmp.path}/${GameDataFormat.gameJsonFileName}')
          .readAsStringSync()) as Map<String, dynamic>;

  group('looksLikeMp4 文件头校验', () {
    test('有效 mp4（第 4..8 字节为 ftyp）通过', () {
      final f = File('${tmp.path}/a.mp4');
      f.writeAsBytesSync(<int>[
        0x00, 0x00, 0x00, 0x20, // box size
        ...'ftyp'.codeUnits,
        ...'isom'.codeUnits,
      ]);
      expect(BpmBackdropMedia.looksLikeMp4(f.path), isTrue);
    });

    test('「改名的假 mp4」被拒（方案 §5.4 的核心目的）', () {
      final f = File('${tmp.path}/b.mp4');
      f.writeAsStringSync('this is not a video at all, just plain text');
      expect(BpmBackdropMedia.looksLikeMp4(f.path), isFalse);
    });

    test('文件过短被拒', () {
      final f = File('${tmp.path}/c.mp4');
      f.writeAsBytesSync(<int>[0, 1, 2]);
      expect(BpmBackdropMedia.looksLikeMp4(f.path), isFalse);
    });

    test('文件不存在返回 false 且不抛', () {
      expect(BpmBackdropMedia.looksLikeMp4('${tmp.path}/nope.mp4'), isFalse);
    });
  });

  group('背景图池（bpm_backdrop_images + selected_image）', () {
    test('无 game.json → 空池、选中为空', () {
      expect(BpmBackdropMedia.readImages(tmp.path), isEmpty);
      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), '');
      expect(BpmBackdropMedia.resolveSelectedImage(tmp.path), isNull);
    });

    test('🔴 v3.11.0 兼容：旧单值字段回退为单元素列表并可选中', () {
      File('${tmp.path}/old.jpg').writeAsBytesSync(<int>[0]);
      writeGameJson(<String, dynamic>{
        BpmBackdropMedia.kLegacyCustomBackdrop: 'old.jpg',
      });

      final images = BpmBackdropMedia.readImages(tmp.path);
      expect(images, hasLength(1));
      expect(images.first.file, 'old.jpg');
      expect(images.first.name, '背景图 1');
      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), 'old.jpg');
      expect(BpmBackdropMedia.resolveSelectedImage(tmp.path),
          '${tmp.path}/old.jpg');
    });

    test('新键存在即用新键 —— 空串 = 明确使用封面，不回退旧字段', () {
      writeGameJson(<String, dynamic>{
        BpmBackdropMedia.kLegacyCustomBackdrop: 'old.jpg',
        BpmBackdropMedia.kSelectedImage: '',
      });
      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), '');
      expect(BpmBackdropMedia.resolveSelectedImage(tmp.path), isNull);
    });

    test('addImages：追加 + 自动选中最后一张 + 🔴 顺带清空旧字段（一次性迁移）', () async {
      writeGameJson(<String, dynamic>{
        BpmBackdropMedia.kLegacyCustomBackdrop: 'old.jpg',
      });
      File('${tmp.path}/a.jpg').writeAsBytesSync(<int>[0]);
      File('${tmp.path}/b.png').writeAsBytesSync(<int>[0]);

      final ok = await BpmBackdropMedia.addImages(tmp.path, const [
        BpmBackdropImageAsset(file: 'a.jpg', name: '立绘'),
        BpmBackdropImageAsset(file: 'b.png', name: '场景'),
      ]);
      expect(ok, isTrue);

      final images = BpmBackdropMedia.readImages(tmp.path);
      // 旧字段的图**保留**（用户资产不丢，以「背景图 1」并入），新增两张排后
      expect(images, hasLength(3));
      expect(images[0].file, 'old.jpg');
      expect(images[1].file, 'a.jpg');
      expect(images[2].name, '场景');
      // 新上传的自动成为当前背景
      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), 'b.png');
      // 旧字段已被清空（迁移完成：删除键或置 null 均算）
      final legacyAfter =
          readGameJson()[BpmBackdropMedia.kLegacyCustomBackdrop];
      expect(legacyAfter == null, isTrue,
          reason: '实际值: $legacyAfter');
    });

    test('removeImage：删的是选中项 → 回退使用封面', () async {
      File('${tmp.path}/a.jpg').writeAsBytesSync(<int>[0]);
      File('${tmp.path}/b.jpg').writeAsBytesSync(<int>[0]);
      await BpmBackdropMedia.addImages(
          tmp.path, const [BpmBackdropImageAsset(file: 'a.jpg', name: 'A')]);
      await BpmBackdropMedia.addImages(
          tmp.path, const [BpmBackdropImageAsset(file: 'b.jpg', name: 'B')]);
      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), 'b.jpg');

      await BpmBackdropMedia.removeImage(tmp.path, 'b.jpg');

      expect(BpmBackdropMedia.readImages(tmp.path), hasLength(1));
      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), '',
          reason: '删除当前选中项 → 回退封面');
    });

    test('renameImage：只改 name 不动 file 与选中', () async {
      await BpmBackdropMedia.addImages(
          tmp.path, const [BpmBackdropImageAsset(file: 'a.jpg', name: 'A')]);

      await BpmBackdropMedia.renameImage(tmp.path, 'a.jpg', '立绘');

      final images = BpmBackdropMedia.readImages(tmp.path);
      expect(images.first.name, '立绘');
      expect(images.first.file, 'a.jpg');
      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), 'a.jpg');
    });

    test('selectImage("")：切回封面', () async {
      await BpmBackdropMedia.addImages(
          tmp.path, const [BpmBackdropImageAsset(file: 'a.jpg', name: 'A')]);
      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), 'a.jpg');

      await BpmBackdropMedia.selectImage(tmp.path, '');

      expect(BpmBackdropMedia.selectedImageRaw(tmp.path), '');
      expect(BpmBackdropMedia.resolveSelectedImage(tmp.path), isNull);
    });
  });

  group('背景视频池（bpm_backdrop_videos + selected_video）', () {
    test('无数据 → 空池、未选', () {
      expect(BpmBackdropMedia.readVideos(tmp.path), isEmpty);
      expect(BpmBackdropMedia.selectedVideoRaw(tmp.path), '');
      expect(BpmBackdropMedia.resolveSelectedVideo(tmp.path), isNull);
    });

    test('🔴 v3.11.0 兼容：旧单值字段回退为「OP」', () {
      File('${tmp.path}/old.mp4').writeAsBytesSync(<int>[0]);
      writeGameJson(<String, dynamic>{
        BpmBackdropMedia.kLegacyOpVideo: 'old.mp4',
      });

      final videos = BpmBackdropMedia.readVideos(tmp.path);
      expect(videos, hasLength(1));
      expect(videos.first.file, 'old.mp4');
      expect(videos.first.name, 'OP');
      expect(BpmBackdropMedia.resolveSelectedVideo(tmp.path),
          '${tmp.path}/old.mp4');
    });

    test('多视频：命名 + 选中（游戏OP / 动画OP / ED 场景）', () async {
      File('${tmp.path}/op.mp4').writeAsBytesSync(<int>[0]);
      File('${tmp.path}/ed.mp4').writeAsBytesSync(<int>[0]);

      await BpmBackdropMedia.addVideos(tmp.path, const [
        BpmBackdropVideoAsset(file: 'op.mp4', name: '游戏OP'),
        BpmBackdropVideoAsset(file: 'ed.mp4', name: '游戏ED'),
      ]);

      expect(BpmBackdropMedia.readVideos(tmp.path), hasLength(2));
      expect(BpmBackdropMedia.selectedVideoRaw(tmp.path), 'ed.mp4',
          reason: '新上传自动选中最后一个');

      await BpmBackdropMedia.selectVideo(tmp.path, 'op.mp4');
      expect(BpmBackdropMedia.resolveSelectedVideo(tmp.path),
          '${tmp.path}/op.mp4');
    });

    test('removeVideo：删的是选中项 → 停止自动播放', () async {
      await BpmBackdropMedia.addVideos(
          tmp.path, const [BpmBackdropVideoAsset(file: 'op.mp4', name: 'OP')]);

      await BpmBackdropMedia.removeVideo(tmp.path, 'op.mp4');

      expect(BpmBackdropMedia.readVideos(tmp.path), isEmpty);
      expect(BpmBackdropMedia.selectedVideoRaw(tmp.path), '');
    });

    test('字段指向不存在的文件 → resolve 为 null（静默回退，不崩）', () {
      writeGameJson(<String, dynamic>{
        BpmBackdropMedia.kBackdropVideos: [
          {'file': 'missing.mp4', 'name': 'OP'}
        ],
        BpmBackdropMedia.kSelectedVideo: 'missing.mp4',
      });
      expect(BpmBackdropMedia.resolveSelectedVideo(tmp.path), isNull);
    });

    test('game.json 内容损坏 → 空池（不抛）', () {
      File('${tmp.path}/${GameDataFormat.gameJsonFileName}')
          .writeAsStringSync('{ this is not json');
      expect(BpmBackdropMedia.readVideos(tmp.path), isEmpty);
      expect(BpmBackdropMedia.readImages(tmp.path), isEmpty);
    });
  });

  group('门槛常量', () {
    test('视频白名单与体积上限符合用户确认值', () {
      expect(
          BpmBackdropMedia.videoExtensions, containsAll(<String>['mp4', 'm4v']));
      expect(BpmBackdropMedia.maxVideoBytes, 500 * 1024 * 1024);
      expect(BpmBackdropMedia.recommendedMaxHeight, 1080);
    });
  });

  group('v3.18 声音优先级：每游戏开关 > 设置页全局默认', () {
    test('该游戏在详情显式拨过开关 → 全局默认不得覆盖', () async {
      // 设置页全局 = 静音（默认）
      await BpmOpVideoPreference.instance.setSoundEnabled(false);
      writeGameJson(<String, dynamic>{
        'format_version': GameDataFormat.currentVersion,
        'bpm_op_video_muted': false, // 详情页拨到「开声」
      });
      expect(BpmBackdropMedia.isGameMuted(tmp.path), isFalse,
          reason: '详情页开了声，全局默认关闭也不得把它压成静音');
    });

    test('全局默认开启时：详情拨到静音仍以详情为准', () async {
      await BpmOpVideoPreference.instance.setSoundEnabled(true);
      writeGameJson(<String, dynamic>{
        'format_version': GameDataFormat.currentVersion,
        'bpm_op_video_muted': true,
      });
      expect(BpmBackdropMedia.isGameMuted(tmp.path), isTrue);
    });

    test('从未单独设置过 → 跟随设置页全局默认', () async {
      await BpmOpVideoPreference.instance.setSoundEnabled(true);
      expect(BpmBackdropMedia.isGameMuted(tmp.path), isFalse);
      await BpmOpVideoPreference.instance.setSoundEnabled(false);
      expect(BpmBackdropMedia.isGameMuted(tmp.path), isTrue);
    });

    test('setGameMuted 写入后即为最终判定（两向）', () async {
      await BpmOpVideoPreference.instance.setSoundEnabled(true);
      await BpmBackdropMedia.setGameMuted(tmp.path, true);
      expect(BpmBackdropMedia.isGameMuted(tmp.path), isTrue);
      await BpmBackdropMedia.setGameMuted(tmp.path, false);
      expect(BpmBackdropMedia.isGameMuted(tmp.path), isFalse);
    });
  });

}
