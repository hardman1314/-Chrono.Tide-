// 智能导入板块 — 路径规范化与匹配测试
//
// 测试覆盖：
// 1. PathNormalizer.forCompare 大小写/分隔符统一
// 2. PathNormalizer.forStore 保留原始大小写
// 3. forCompare 与 forStore 互相匹配（大小写不敏感）
// 4. 尾部斜杠处理
// 5. 混合分隔符处理
// 6. isSubdirectory 边界条件

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/utils/path_normalizer.dart';

void main() {
  group('PathNormalizer.forCompare', () {
    test('应统一为小写 + 反斜杠', () {
      final result = PathNormalizer.forCompare('D:/Games/MyGame');
      expect(result, 'd:\\games\\mygame');
    });

    test('应处理混合分隔符', () {
      final result = PathNormalizer.forCompare('D:\\Games/MyGame\\Data');
      expect(result, 'd:\\games\\mygame\\data');
    });

    test('应去除尾部斜杠', () {
      final result = PathNormalizer.forCompare('D:\\Games\\');
      expect(result, 'd:\\games');
    });

    test('应保留根目录尾部斜杠（C:\\）', () {
      final result = PathNormalizer.forCompare('C:\\');
      expect(result, 'c:\\');
    });

    test('应折叠冗余段（.. 和 .）', () {
      final result = PathNormalizer.forCompare('D:\\Games\\..\\Games\\MyGame');
      expect(result, 'd:\\games\\mygame');
    });

    test('空路径应返回空字符串', () {
      expect(PathNormalizer.forCompare(''), '');
    });
  });

  group('PathNormalizer.forStore', () {
    test('应保留原始大小写', () {
      final result = PathNormalizer.forStore('D:/Games/MyGame');
      expect(result, 'D:\\Games\\MyGame');
    });

    test('应统一为反斜杠', () {
      final result = PathNormalizer.forStore('D/Games/MyGame');
      expect(result.contains('\\'), true);
    });

    test('应去除尾部斜杠', () {
      final result = PathNormalizer.forStore('D:\\Games\\');
      expect(result, 'D:\\Games');
    });

    test('空路径应返回空字符串', () {
      expect(PathNormalizer.forStore(''), '');
    });
  });

  group('forCompare 与 forStore 互相匹配', () {
    test('不同大小写的路径应通过 forCompare 匹配', () {
      final stored = PathNormalizer.forStore('D:\\Games\\MyGame');
      final input = 'd:\\games\\mygame';
      expect(PathNormalizer.forCompare(stored), PathNormalizer.forCompare(input));
    });

    test('不同分隔符的路径应通过 forCompare 匹配', () {
      final stored = PathNormalizer.forStore('D:\\Games\\MyGame');
      final input = 'D:/Games/MyGame';
      expect(PathNormalizer.forCompare(stored), PathNormalizer.forCompare(input));
    });

    test('混合大小写+分隔符应通过 forCompare 匹配', () {
      final stored = PathNormalizer.forStore('D:/Games/MyGame');
      final input = 'd:\\GAMES\\mygame';
      expect(PathNormalizer.forCompare(stored), PathNormalizer.forCompare(input));
    });
  });

  group('PathNormalizer.isSubdirectory', () {
    test('直接子目录应返回 true', () {
      expect(
        PathNormalizer.isSubdirectory('D:\\Games', 'D:\\Games\\MyGame'),
        true,
      );
    });

    test('间接子目录应返回 true', () {
      expect(
        PathNormalizer.isSubdirectory('D:\\Games', 'D:\\Games\\Folder\\MyGame'),
        true,
      );
    });

    test('非子目录应返回 false', () {
      expect(
        PathNormalizer.isSubdirectory('D:\\Games', 'D:\\Other\\MyGame'),
        false,
      );
    });

    test('相同路径应返回 false（非子目录）', () {
      expect(
        PathNormalizer.isSubdirectory('D:\\Games', 'D:\\Games'),
        false,
      );
    });

    test('前缀相似但非子目录应返回 false', () {
      // D:\Game 不应是 D:\Games 的父目录
      expect(
        PathNormalizer.isSubdirectory('D:\\Game', 'D:\\Games\\MyGame'),
        false,
      );
    });

    test('大小写不敏感匹配', () {
      expect(
        PathNormalizer.isSubdirectory('D:\\Games', 'd:\\games\\mygame'),
        true,
      );
    });
  });

  group('PathNormalizer.depthOf', () {
    test('直接子目录深度为1', () {
      expect(
        PathNormalizer.depthOf('D:\\Games\\MyGame', 'D:\\Games'),
        1,
      );
    });

    test('间接子目录深度为2', () {
      expect(
        PathNormalizer.depthOf('D:\\Games\\Folder\\MyGame', 'D:\\Games'),
        2,
      );
    });

    test('相同路径深度为0', () {
      expect(
        PathNormalizer.depthOf('D:\\Games', 'D:\\Games'),
        0,
      );
    });

    test('非后代路径返回-1', () {
      expect(
        PathNormalizer.depthOf('D:\\Other\\MyGame', 'D:\\Games'),
        -1,
      );
    });

    test('混合分隔符应正确计算深度', () {
      expect(
        PathNormalizer.depthOf('D:/Games/MyGame', 'D:\\Games'),
        1,
      );
    });
  });
}
