import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/game_data_format.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cover_gallery_test_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('listCoverGallery：canonical 竖封面 → 横幅 → covers/ 自定义图，身份标记正确', () {
    final cover = File('${tmp.path}/cover.png')..writeAsBytesSync([1]);
    final banner = File('${tmp.path}/banner.jpg')..writeAsBytesSync([2]);
    final coversDir = Directory('${tmp.path}/covers')..createSync();
    final custom1 = File('${coversDir.path}/custom_a.png')..writeAsBytesSync([3]);
    final custom2 = File('${coversDir.path}/custom_b.jpg')..writeAsBytesSync([4]);
    // 非图片文件不应出现在候选里
    File('${coversDir.path}/readme.txt').writeAsBytesSync([5]);

    final list = GameDataFormat.listCoverGallery(tmp.path);

    expect(list.length, 4);
    expect(list[0].path, cover.path.replaceAll('\\', '/'));
    expect(list[0].isVertical, isTrue);
    expect(list[0].isBanner, isFalse);
    expect(list[1].path, banner.path.replaceAll('\\', '/'));
    expect(list[1].isBanner, isTrue);
    expect(list[2].path, custom1.path.replaceAll('\\', '/'));
    expect(list[2].isVertical, isFalse);
    expect(list[2].isBanner, isFalse);
    expect(list[3].path, custom2.path.replaceAll('\\', '/'));
  });

  test('listCoverGallery：cover_file / banner_file 指定名优先于常见命名', () {
    // 故意放一个非标准名 + 一个会被常见命名探测命中的文件
    File('${tmp.path}/cover.png').writeAsBytesSync([1]);
    File('${tmp.path}/banner.webp').writeAsBytesSync([2]);
    // 直接手写 game.json（避免依赖 updateGameJson 异步写入时序）
    File('${tmp.path}/${'game.json'}').writeAsStringSync(
      '{"format_version":4,"title":"t","cover_file":"my_cover.jpg",'
      '"banner_file":"my_banner.png"}',
    );
    final myCover = File('${tmp.path}/my_cover.jpg')..writeAsBytesSync([1]);
    final myBanner = File('${tmp.path}/my_banner.png')..writeAsBytesSync([2]);

    final list = GameDataFormat.listCoverGallery(tmp.path);

    expect(list.length, 2);
    expect(list[0].path, myCover.path.replaceAll('\\', '/'));
    expect(list[1].path, myBanner.path.replaceAll('\\', '/'));
  });

  test('listCoverGallery：空目录返回空列表，不抛异常', () {
    expect(GameDataFormat.listCoverGallery(tmp.path), isEmpty);
    expect(GameDataFormat.listCoverGallery('${tmp.path}/不存在'), isEmpty);
  });

  test('coversDirName 常量 = covers（护栏：改名会破坏 covers/ 前缀删除守卫）', () {
    expect(GameDataFormat.coversDirName, 'covers');
  });
}
