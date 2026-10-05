import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/utils/network_path.dart';
import 'package:chrono_tide/utils/path_normalizer.dart';

/// 网络路径（UNC / 映射网络驱动器）工具单测。
///
/// 只断言**与运行机器无关**的纯逻辑：盘符探测（`GetDriveTypeW`）、
/// UNC 解析（`WNetGetUniversalNameW`）在测试环境不可控，故不对
/// 「某个盘符是不是网络盘」下断言，只断言字符串形态与降级行为。
void main() {
  group('stripLongPathPrefix', () {
    test('剥离 \\\\?\\ 盘符前缀', () {
      expect(NetworkPath.stripLongPathPrefix(r'\\?\C:\Games\X'),
          r'C:\Games\X');
    });

    test('剥离 \\\\?\\UNC\\ 前缀并还原为 UNC', () {
      expect(NetworkPath.stripLongPathPrefix(r'\\?\UNC\host\share\X'),
          r'\\host\share\X');
    });

    test('普通路径（含 UNC）原样返回', () {
      expect(NetworkPath.stripLongPathPrefix(r'C:\Games\X'), r'C:\Games\X');
      expect(NetworkPath.stripLongPathPrefix(r'\\host\share\X'),
          r'\\host\share\X');
      expect(NetworkPath.stripLongPathPrefix(''), '');
    });
  });

  group('volumeRoot', () {
    test('盘符路径返回盘符根', () {
      expect(NetworkPath.volumeRoot(r'Z:\Games\X'), r'Z:\');
      expect(NetworkPath.volumeRoot(r'C:'), r'C:\');
      expect(NetworkPath.volumeRoot(r'd:\a\b'), r'd:\');
    });

    test('UNC 路径返回共享根', () {
      expect(NetworkPath.volumeRoot(r'\\host\share\Games\X'),
          r'\\host\share');
      expect(NetworkPath.volumeRoot(r'\\host\share'), r'\\host\share');
    });

    test('长路径前缀不影响解析', () {
      expect(NetworkPath.volumeRoot(r'\\?\Z:\Games\X'), r'Z:\');
      expect(NetworkPath.volumeRoot(r'\\?\UNC\host\share\Games\X'),
          r'\\host\share');
    });

    test('相对路径 / 空返回 null', () {
      expect(NetworkPath.volumeRoot(''), isNull);
      expect(NetworkPath.volumeRoot(r'Games\X'), isNull);
    });

    test('正斜杠分隔符同样可解析', () {
      expect(NetworkPath.volumeRoot('Z:/Games/X'), r'Z:\');
      expect(NetworkPath.volumeRoot('//host/share/Games/X'), r'\\host\share');
    });
  });

  group('isNetwork', () {
    test('UNC 恒为网络路径', () {
      expect(NetworkPath.isNetwork(r'\\host\share\Games'), isTrue);
      expect(NetworkPath.isNetwork(r'\\?\UNC\host\share\Games'), isTrue);
    });

    test('无法解析的输入不视为网络路径', () {
      expect(NetworkPath.isNetwork(''), isFalse);
      expect(NetworkPath.isNetwork(r'Games\X'), isFalse);
    });
  });

  group('isSameVolume', () {
    test('同一 UNC 共享视为同卷', () {
      expect(
          NetworkPath.isSameVolume(r'\\host\share\A', r'\\host\share\B\C'),
          isTrue);
    });

    test('不同 UNC 共享视为跨卷', () {
      expect(
          NetworkPath.isSameVolume(r'\\host\shareA\x', r'\\host\shareB\y'),
          isFalse);
    });

    test('UNC 与无关盘符视为跨卷', () {
      expect(NetworkPath.isSameVolume(r'\\host\share\x', r'C:\x'), isFalse);
    });

    test('无法解析时保守返回 false', () {
      expect(NetworkPath.isSameVolume('', r'C:\x'), isFalse);
      expect(NetworkPath.isSameVolume(r'rel\a', r'rel\b'), isFalse);
    });

    test('同一盘符字母视为同卷（本地盘行为不变）', () {
      expect(NetworkPath.isSameVolume(r'C:\a', r'C:\b'), isTrue);
      expect(NetworkPath.isSameVolume(r'C:\a', r'c:\b'), isTrue);
    });
  });

  group('canonicalizeVolume', () {
    test('UNC 路径原样返回', () {
      expect(NetworkPath.canonicalizeVolume(r'\\host\share\Games\X'),
          r'\\host\share\Games\X');
    });

    test('长路径前缀被剥离', () {
      expect(NetworkPath.canonicalizeVolume(r'\\?\C:\Games\X'),
          r'C:\Games\X');
    });

    test('无法解析卷根的路径原样返回', () {
      expect(NetworkPath.canonicalizeVolume(r'rel\a'), r'rel\a');
      expect(NetworkPath.canonicalizeVolume(''), '');
    });
  });

  group('toUniversalPath（写注册表 Run 键用）', () {
    test('UNC 路径原样返回', () {
      expect(NetworkPath.toUniversalPath(r'\\host\share\CT\chrono_tide.exe'),
          r'\\host\share\CT\chrono_tide.exe');
    });

    test('长路径前缀被剥离（不把 \\\\?\\ 写进注册表）', () {
      expect(NetworkPath.toUniversalPath(r'\\?\C:\CT\chrono_tide.exe'),
          r'C:\CT\chrono_tide.exe');
    });

    test('无法解析卷根的路径原样返回（本地/相对路径零改动）', () {
      expect(NetworkPath.toUniversalPath(r'C:\CT\chrono_tide.exe'),
          r'C:\CT\chrono_tide.exe');
      expect(NetworkPath.toUniversalPath(r'rel\a.exe'), r'rel\a.exe');
      expect(NetworkPath.toUniversalPath(''), '');
    });
  });

  group('PathNormalizer.forCompare 与长路径前缀', () {
    test('带 \\\\?\\ 前缀与不带前缀的比较结果一致', () {
      expect(PathNormalizer.forCompare(r'\\?\C:\Games\X'),
          PathNormalizer.forCompare(r'C:\Games\X'));
    });

    test('本地盘规范化为小写 + \\ 分隔 + 去尾斜杠（既有语义不变）', () {
      expect(PathNormalizer.forCompare(r'C:\Games\A'), r'c:\games\a');
      expect(PathNormalizer.forCompare('C:/Games/A'), r'c:\games\a');
      expect(PathNormalizer.forCompare(r'C:\Games\'), r'c:\games');
    });

    test('折叠冗余段（既有语义不变）', () {
      expect(PathNormalizer.forCompare(r'C:\Games\Sub\..\A'), r'c:\games\a');
    });
  });

  group('isVolumeReachableAsync 降级', () {
    test('无法解析卷根时不阻断流程（返回 true）', () async {
      expect(await NetworkPath.isVolumeReachableAsync(r'rel\a'), isTrue);
    });

    test('本地已存在卷根可达', () async {
      expect(await NetworkPath.isVolumeReachableAsync(r'C:\Windows'), isTrue);
    });
  });
}
