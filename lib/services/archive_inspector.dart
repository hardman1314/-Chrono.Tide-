import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pffi;

import '../core/path_helper.dart';
import 'unpack_plan.dart';
import 'unpack_store.dart';

/// 压缩包魔数嗅探与真实格式判定 —— 智能解压 Phase 1/2（方案
/// docs/DEV/features/join_archive_smart_unpack_plan.md §4.2）。
///
/// 背景：单文件导入此前 100% 按扩展名判定文件类型（join_controller.dart
/// detectFileType / ExtractManager._detectFormatsFromName），分享者把
/// .zip 改名成 .mp4/.mov 后，包会被当普通文件拒绝或错误入库。
///
/// 实现范式参照 lib/theme/background_media.dart:92 的
/// 「魔数与扩展名交叉核对：防改名伪装」；Phase 0 探针
/// （dev_probe/probe_unpack_phase0.py T13/T14）实测：
/// - 加密不影响魔数（加密 7z/zip 头部与明文完全一致）；
/// - 7z 23.01 对改后缀文件按内容识别（后缀免疫），嗅探结果可直接喂给 7z。

/// 魔数嗅探结果
class ArchiveSniffResult {
  const ArchiveSniffResult({
    required this.path,
    required this.format,
    required this.declaredExt,
  });

  /// 嗅探的文件绝对路径（用于校验结果归属，防止「选 A 嗅探后选 B」错配）
  final String path;

  /// 魔数判定的真实格式（与 ExtractManager 格式命名对齐）：
  /// 'zip'/'7z'/'rar'/'lz4'/'zst'/'gz'/'bz2'/'xz'/'cab'/'arj'/'iso'/'tar'/'enc'
  /// null = 无法按魔数识别（可能真不是压缩包，或属于表外格式）
  final String? format;

  /// 文件声明的扩展名（小写、含点；多层后缀原样，如 '.zip.lz4'）
  final String declaredExt;

  /// 是否压缩包（魔数命中）
  bool get isArchive => format != null;

  /// 是否伪装包：魔数识别为压缩格式，但扩展名不是该格式的常规后缀
  /// （如 .zip 内容 + .mp4 后缀）。扩展名比对见 [_isPlausibleExtFor]。
  bool get disguised {
    if (format == null) return false;
    return !_isPlausibleExtFor(format!, declaredExt);
  }

  /// 格式的常规扩展名（用于伪装判定；多层组合如 .tar.gz 按尾部段比对）
  static const Map<String, List<String>> _plausibleExts = {
    'zip': ['.zip'],
    '7z': ['.7z'],
    'rar': ['.rar'],
    'lz4': ['.lz4', '.zip.lz4', '.rar.lz4', '.7z.lz4', '.tar.lz4'],
    'zst': ['.zst', '.tar.zst'],
    'gz': ['.gz', '.tar.gz'],
    'bz2': ['.bz2', '.tar.bz2'],
    'xz': ['.xz', '.tar.xz'],
    'cab': ['.cab'],
    'arj': ['.arj'],
    'iso': ['.iso'],
    'tar': ['.tar', '.tar.gz', '.tar.bz2', '.tar.xz', '.tar.zst'],
    // S.S.E. File Encryptor v4 加密容器（解密产物为 zip，走续链）
    'enc': ['.enc'],
  };

  /// 扩展名是否与格式吻合（伪装判定用）：比对声明的扩展名的尾部若干段。
  /// 例：'.zip.lz4' 对 lz4 合理；'.mp4' 对 zip 不合理 → disguised。
  static bool _isPlausibleExtFor(String format, String declaredExt) {
    final candidates = _plausibleExts[format];
    if (candidates == null) return true; // 表外格式不做伪装判定
    return candidates.any(declaredExt.endsWith);
  }
}

/// ★ Phase C（join_unpack_scenarios_v2.md §1.1）：分卷组识别结果。
class VolumeGroup {
  const VolumeGroup({
    required this.stem,
    required this.kind,
    required this.firstVolumePath,
    required this.volumes,
    required this.missingNumbers,
    required this.missingFilenames,
  });

  /// 主干名（小写，不含分卷后缀）
  final String stem;

  /// '7z' | 'zip' | 'rar'
  final String kind;

  /// 解压入口（首卷/主卷）绝对路径；缺卷时可能是尚不存在的预期路径
  final String firstVolumePath;

  /// 已发现的全组成员绝对路径（旧式入口在首，其余按序号升序）
  final List<String> volumes;

  /// 缺失卷序号（-1 = 旧式入口主卷/尾卷缺失；空表 = 组完整）
  final List<int> missingNumbers;

  /// 缺失卷的预期文件名（按兄弟卷位宽重构，供报因文案）
  final List<String> missingFilenames;
}

class ArchiveInspector {
  ArchiveInspector._();

  /// 魔数表：前缀 → 格式名。只收录标准压缩容器，普通游戏资源格式
  /// （.pfs/.arc 等自定义包）一律不认，防止把游戏内部资源误当压缩包（方案 §4.8）。
  static const List<(List<int>, String)> _magicTable = [
    // zip（含空包 EOCD 与 spanned 标记）
    ([0x50, 0x4B, 0x03, 0x04], 'zip'),
    ([0x50, 0x4B, 0x05, 0x06], 'zip'),
    ([0x50, 0x4B, 0x07, 0x08], 'zip'),
    // 7z
    ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], '7z'),
    // rar（RAR4/RAR5 共享前缀）
    ([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], 'rar'),
    // S.S.E. File Encryptor v4 容器（"SSEFE" + version=4 + algo + params）
    // —— v1-v3 旧版头不同（"SSE" 起始但第 4 字节非 'F'），一期只认 v4 前缀
    ([0x53, 0x53, 0x45, 0x46, 0x45], 'enc'),
    // lz4 frame
    ([0x04, 0x22, 0x4D, 0x18], 'lz4'),
    // zstandard frame
    ([0x28, 0xB5, 0x2F, 0xFD], 'zst'),
    // gzip
    ([0x1F, 0x8B], 'gz'),
    // xz
    ([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], 'xz'),
    // cab
    ([0x4D, 0x53, 0x43, 0x46], 'cab'),
    // arj
    ([0x60, 0xEA], 'arj'),
  ];

  /// 嵌套包识别用的压缩后缀（与 extract_manager._detectFormatsFromName
  /// 的 singleExts 对齐 + 双格式组合）
  static const List<String> _archiveExtHints = [
    '.zip', '.rar', '.7z', '.lz4', '.tar', '.gz', '.bz2', '.xz',
    '.iso', '.cab', '.arj', '.zst', '.lzma',
    '.tar.gz', '.tar.bz2', '.tar.xz', '.tar.zst',
    '.zip.lz4', '.rar.lz4', '.7z.lz4', '.tar.lz4',
    '.zip.7z', '.rar.7z', '.tar.7z',
    '.enc',
  ];

  /// 同步嗅探：读文件头判定真实格式。
  /// 只读前 16 字节（ISO/tar 额外一次 seek 读），O(1)、微秒级，
  /// 可安全在同步上下文（handleFileSelected）中调用。
  static ArchiveSniffResult sniffSync(String path) {
    final declaredExt = _declaredExtOf(path);
    try {
      final f = File(path);
      if (!f.existsSync()) {
        return ArchiveSniffResult(
            path: path, format: null, declaredExt: declaredExt);
      }
      final raf = f.openSync();
      try {
        final head = _readAt(raf, 0, 16);
        String? fmt;
        for (final (magic, name) in _magicTable) {
          if (_startsWith(head, magic)) {
            fmt = name;
            break;
          }
        }
        // ISO 9660：volume descriptor 位于 0x8001 起 "CD001"
        fmt ??= _sniffIso(raf);
        // tar：ustar 魔数位于头 257 偏移
        fmt ??= _sniffTar(raf);
        // ★ 2026-10-05 尾部拼接 zip（网盘过审壳）：头部是视频等正常容器，
        //   zip 数据整体拼在文件尾部，靠 EOCD 签名反查（_sniffTrailingZip）。
        fmt ??= _sniffTrailingZip(raf);
        return ArchiveSniffResult(
            path: path, format: fmt, declaredExt: declaredExt);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      // 读取失败（权限/占用等）按未知处理，交回原有扩展名逻辑
      return ArchiveSniffResult(
          path: path, format: null, declaredExt: declaredExt);
    }
  }

  // ================= 计划探测（Phase 2） =================

  /// 构建解压计划（只读探测，零落盘）。
  ///
  /// 探测策略（Phase 0 实测边界）：
  /// - 第 0 层格式：魔数嗅探优先，扩展名兜底（.lzma 等无魔数格式）；
  /// - 内容清单：`7z l -slt` 尝试列出——成功则统计条目/体积并识别
  ///   嵌套压缩包（记录为 layer 1+，内容未知）；失败且报
  ///   "Cannot open encrypted archive"（Phase 0 T2）→ 加密文件名包，
  ///   needsPassword=true、contentKnown=false，执行期靠重扫续链；
  /// - .lz4 单流：7z 23.01 不支持（Phase 0 T15），内容不可预知但无加密；
  /// - 加密与否对「文件名不加密」的包（ZipCrypto/AES zip，Phase 0 T4/T5）
  ///   探测期不强制判定——解压期由密码候选队列兜底。
  /// - ★ Phase C：分卷组识别（§1.1）——拖入任一分卷 → 以首卷为探测/
  ///   解压入口；缺卷 → 返回空层计划 + 明确报因（用户拍板：直接失败）。
  ///
  /// 探测含一次 7z l 子进程（GB 级包 1-2s），调用方在 async 上下文执行。
  static Future<UnpackPlan> buildPlan(String path) async {
    // ★ Phase C（§1.1）：分卷组识别先行——非首卷的魔数不可靠（.7z.002 无
    //   7z 魔数、.z01 是 spanned 标记），必须先归组再嗅探。
    final vg = detectVolumeGroup(path);
    final warnings = <String>[];
    var probePath = path;
    String? firstVolumePath;
    if (vg != null) {
      if (vg.missingNumbers.isNotEmpty) {
        // 用户拍板（2026-10-04）：缺卷直接失败 + 明确报因，不挂起不试解
        return UnpackPlan(
          sourcePath: path,
          firstVolumePath: vg.firstVolumePath,
          layers: const [],
          suffixMappings: UnpackStore.instance.mappings,
          warnings: [
            '分卷压缩包不完整（已发现 ${vg.volumes.length} 段）：'
                '缺少 ${vg.missingFilenames.join('、')}，请补齐后重新导入',
          ],
        );
      }
      probePath = vg.firstVolumePath;
      firstVolumePath = vg.firstVolumePath;
      final droppedBase =
          path.split('/').last.split('\\').last.toLowerCase();
      final probeBase =
          probePath.split('/').last.split('\\').last.toLowerCase();
      if (droppedBase != probeBase) {
        warnings.add(
            '已识别分卷组（${vg.volumes.length} 段），解压入口为首卷: '
            '${probePath.split('/').last.split('\\').last}');
      } else {
        warnings.add('分卷压缩包（共 ${vg.volumes.length} 段）');
      }
    }
    final sniff = sniffSync(probePath);
    final layers = <ArchiveLayer>[];

    // 第 0 层格式：魔数优先，扩展名兜底（.lzma 等无魔数格式走老判定）
    final format = sniff.format ?? _formatFromExt(sniff.declaredExt);
    if (format == null) {
      return UnpackPlan(
        sourcePath: path,
        layers: const [],
        suffixMappings: UnpackStore.instance.mappings,
        warnings: const ['无法识别压缩格式（魔数与扩展名均未命中）'],
      );
    }

    final declaredExt = sniff.declaredExt.isNotEmpty
        ? sniff.declaredExt
        : '.$format';

    var contentKnown = false;
    var needsPassword = false;
    int? totalSize;
    final nestedCandidates = <String>[];

    if (format == 'enc') {
      // ★ S.S.E. File Encryptor v4 加密容器：7z 不识别该容器，内容不可
      // 预览；解密必需密码（计划第 1 层密码框）。解密产物为 zip，
      // 执行期解密落临时层后走既有嵌套续链（extract_manager _executePlanExtract）。
      contentKnown = false;
      needsPassword = true;
      warnings.add('S.S.E. File Encryptor 加密容器（.enc）：'
          '解密需密码（用「第 1 层密码」），解密后自动继续解压');
    } else if (format == 'lz4') {
      // lz4 单流无容器结构，内容解压后确认；无加密概念
      contentKnown = false;
      warnings.add('LZ4 单流压缩：内容在解压后确认（通常解出 .zip/.rar）');
    } else {
      final l = await _sevenZipList(probePath);
      if (l.exitCode == 0) {
        contentKnown = true;
        totalSize = l.totalSize;
        nestedCandidates.addAll(l.nestedArchives);
      } else if (l.encryptedArchive) {
        // "Cannot open encrypted archive. Wrong password?"（Phase 0 T2）
        contentKnown = false;
        needsPassword = true;
        warnings.add('加密压缩包（文件名已加密）：开始解压前需提供本层密码');
      } else {
        contentKnown = false;
        warnings.add('内容预览失败（${l.errorLine}）：解压后自动重新扫描');
      }
    }

    layers.add(ArchiveLayer(
      layerIndex: 0,
      realFormat: format,
      declaredExt: declaredExt,
      disguised: sniff.disguised,
      needsPassword: needsPassword,
      passwordKnown: needsPassword &&
          UnpackStore.instance
              .recallPassword(probePath, format) !=
              null,
      contentKnown: contentKnown,
      sizeBytes: totalSize,
    ));

    // 嵌套压缩包 → 记录为后续层（内容未知，执行期重扫续链）
    for (var i = 0; i < nestedCandidates.length; i++) {
      final entry = nestedCandidates[i];
      final entryExt = _declaredExtOfEntry(entry);
      layers.add(ArchiveLayer(
        layerIndex: i + 1,
        realFormat: _formatFromExt(entryExt) ?? 'zip',
        declaredExt: entryExt,
        needsPassword: false,
        contentKnown: false,
        sourceEntryPath: entry,
      ));
    }
    if (nestedCandidates.length > 1) {
      warnings.add('发现 ${nestedCandidates.length} 个嵌套压缩包，将按顺序解压');
    }

    // 磁盘空间预检（方案 §4.8：zip 炸弹 / 磁盘护栏）
    if (totalSize != null) {
      final freeBytes = _freeDiskBytesOf(probePath);
      if (freeBytes != null && totalSize > freeBytes) {
        warnings.add('⚠ 磁盘剩余空间可能不足：'
            '需约 ${(totalSize / 1024 / 1024 / 1024).toStringAsFixed(1)}GB');
      }
    }

    return UnpackPlan(
      sourcePath: path,
      firstVolumePath: firstVolumePath,
      layers: layers,
      suffixMappings: UnpackStore.instance.mappings,
      warnings: warnings,
    );
  }

  /// ★ Phase C（join_unpack_scenarios_v2.md §1.1）：分卷组识别——拖入任一
  /// 分卷 → 按「文件名主干 + 卷序号模式」定位同目录全组（主干须一致，
  /// 防跨包误归并）。五种社区命名（大小写不敏感）：
  /// - 7z 多卷:  base.7z.001/002/...（入口 .001，7z 自动找同目录后续卷）
  /// - zip 多卷: base.zip.001/...（入口 .001）
  /// - rar 新式: base.part1.rar / part2.rar / ...（入口 .part1.rar）
  /// - rar 旧式: base.rar + base.r00/.r01/...（入口 .rar 主卷）
  /// - zip 旧式: base.z01/.z02/... + base.zip（入口 .zip 尾卷）
  /// 普通单文件 zip/rar（无编号兄弟）→ null，不算分卷。
  static VolumeGroup? detectVolumeGroup(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    List<FileSystemEntity> items;
    try {
      items = f.parent.listSync(followLinks: false);
    } catch (_) {
      return null;
    }
    String baseName(String p) => p.split('/').last.split('\\').last;
    final dropped = baseName(path).toLowerCase();

    String? stem;
    var kind = '';
    var oldStyle = false; // true = rar 旧式（.rNN）/ zip 旧式（.zNN+尾卷入口）
    var entryName = '';
    RegExp? sibRe;
    final m7z = RegExp(r'^(.+)\.7z\.(\d+)$').firstMatch(dropped);
    final mzipN = RegExp(r'^(.+)\.zip\.(\d+)$').firstMatch(dropped);
    final mrarP = RegExp(r'^(.+)\.part(\d+)\.rar$').firstMatch(dropped);
    final mrNN = RegExp(r'^(.+)\.r(\d{2,})$').firstMatch(dropped);
    final mzNN = RegExp(r'^(.+)\.z(\d{2,})$').firstMatch(dropped);
    if (m7z != null) {
      stem = m7z.group(1);
      kind = '7z';
      entryName = '${stem!}.7z.001';
      sibRe = RegExp('^${RegExp.escape(stem)}\\.7z\\.(\\d+)\$');
    } else if (mzipN != null) {
      stem = mzipN.group(1);
      kind = 'zip';
      entryName = '${stem!}.zip.001';
      sibRe = RegExp('^${RegExp.escape(stem)}\\.zip\\.(\\d+)\$');
    } else if (mrarP != null) {
      stem = mrarP.group(1);
      kind = 'rar';
      entryName = '${stem!}.part1.rar';
      sibRe = RegExp('^${RegExp.escape(stem)}\\.part(\\d+)\\.rar\$');
    } else if (mrNN != null) {
      stem = mrNN.group(1);
      kind = 'rar';
      oldStyle = true;
      entryName = '${stem!}.rar';
      sibRe = RegExp('^${RegExp.escape(stem)}\\.r(\\d+)\$');
    } else if (mzNN != null) {
      stem = mzNN.group(1);
      kind = 'zip';
      oldStyle = true;
      entryName = '${stem!}.zip';
      sibRe = RegExp('^${RegExp.escape(stem)}\\.z(\\d+)\$');
    } else if (dropped.endsWith('.rar')) {
      // 可能是旧式 rar 主卷：仅当存在 .rNN 编号兄弟才算分卷组
      stem = dropped.substring(0, dropped.length - '.rar'.length);
      kind = 'rar';
      oldStyle = true;
      entryName = dropped;
      sibRe = RegExp('^${RegExp.escape(stem)}\\.r(\\d+)\$');
    } else if (dropped.endsWith('.zip')) {
      // 可能是旧式 spanned zip 尾卷：仅当存在 .zNN 编号兄弟才算分卷组
      stem = dropped.substring(0, dropped.length - '.zip'.length);
      kind = 'zip';
      oldStyle = true;
      entryName = dropped;
      sibRe = RegExp('^${RegExp.escape(stem)}\\.z(\\d+)\$');
    } else {
      return null;
    }

    // 扫描同目录同主干成员（保留真实路径大小写）
    final numbered = <int, String>{};
    String? entryPath;
    var width = 0;
    for (final e in items) {
      if (e is! File) continue;
      final n = baseName(e.path).toLowerCase();
      if (n == entryName) entryPath = e.path;
      final m = sibRe.firstMatch(n);
      if (m != null) {
        final s = m.group(1)!;
        if (s.length > width) width = s.length;
        numbered[int.parse(s)] = e.path;
      }
    }
    // 资格：拖入的是编号卷 → 必是组；拖入主卷/尾卷 → 需有编号兄弟
    final droppedIsNumbered = m7z != null ||
        mzipN != null ||
        mrarP != null ||
        mrNN != null ||
        mzNN != null;
    if (!droppedIsNumbered && numbered.isEmpty) return null;

    String pad(int n) => n.toString().padLeft(width < 2 ? 2 : width, '0');
    String missingName(int n) {
      switch (kind) {
        case '7z':
          return '$stem.7z.${pad(n)}';
        case 'rar':
          return oldStyle ? '$stem.r${pad(n)}' : '$stem.part$n.rar';
        default: // zip
          return oldStyle ? '$stem.z${pad(n)}' : '$stem.zip.${pad(n)}';
      }
    }

    // 缺卷计算：编号卷要求 1..max 连续；旧式还要求入口主卷/尾卷存在
    final missing = <int>[];
    final missingNames = <String>[];
    if (!oldStyle && !numbered.containsKey(1)) {
      missing.add(1);
      missingNames.add(entryName);
    }
    if (oldStyle && entryPath == null) {
      missing.add(-1); // 入口主卷/尾卷缺失（无编号语义，-1 占位）
      missingNames.add(entryName);
    }
    if (numbered.isNotEmpty) {
      final keys = numbered.keys.toList()..sort();
      for (var i = keys.first; i <= keys.last; i++) {
        if (!numbered.containsKey(i)) {
          missing.add(i);
          missingNames.add(missingName(i));
        }
      }
    }

    // 全组成员（按序：旧式入口在首，编号卷按序号升序）
    final volumes = <String>[
      if (oldStyle && entryPath != null) entryPath,
      ...[
        for (final k in numbered.keys.toList()..sort()) numbered[k]!
      ],
    ];
    return VolumeGroup(
      stem: stem,
      kind: kind,
      firstVolumePath: entryPath ??
          '${f.parent.path}${Platform.pathSeparator}$entryName',
      volumes: volumes,
      missingNumbers: missing,
      missingFilenames: missingNames,
    );
  }

  /// `7z l -slt` 解析：返回条目数、总体积、嵌套压缩包路径
  static Future<_ListResult> _sevenZipList(String archivePath) async {
    try {
      final result = await Process.run(
        PathHelper.bundled7zPath,
        ['l', '-slt', '-sccUTF-8', '-p', archivePath],
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      final out = (result.stdout as String?) ?? '';
      final err = (result.stderr as String?) ?? '';
      final combined = out + err;

      if (result.exitCode != 0) {
        final encryptedArchive =
            combined.contains('Cannot open encrypted archive');
        final errorLines = combined
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.startsWith('ERROR') || s.contains('Error'))
            .toList();
        final line = errorLines.isNotEmpty
            ? errorLines.first
            : 'exitCode=${result.exitCode}';
        return _ListResult(
          exitCode: result.exitCode,
          encryptedArchive: encryptedArchive,
          errorLine: line,
        );
      }

      // -slt 输出按空行分块，每块含 Path = ... / Size = ... 等键值
      var totalSize = 0;
      final nested = <String>[];
      String? currentPath;
      for (final raw in out.split('\n')) {
        final line = raw.trim();
        if (line.startsWith('Path = ')) {
          currentPath = line.substring(7).trim();
        } else if (line.startsWith('Size = ') && currentPath != null) {
          final size = int.tryParse(line.substring(7).trim());
          if (size != null) totalSize += size;
          if (_entryLooksLikeArchive(currentPath)) {
            nested.add(currentPath);
          }
          currentPath = null;
        }
      }
      return _ListResult(
          exitCode: 0, totalSize: totalSize, nestedArchives: nested);
    } catch (e) {
      return _ListResult(exitCode: -1, errorLine: '$e');
    }
  }

  /// 条目路径是否指向嵌套压缩包
  static bool _entryLooksLikeArchive(String entryPath) {
    final p = entryPath.toLowerCase();
    return _archiveExtHints.any(p.endsWith);
  }

  /// 声明后缀提取（条目路径 → 尾部含点后缀；双格式取两段）
  static String _declaredExtOfEntry(String entryPath) {
    final name = entryPath.split('/').last.split('\\').last.toLowerCase();
    for (final ext in _archiveExtHints) {
      if (name.endsWith(ext)) return ext;
    }
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot) : '';
  }

  static String? _formatFromExt(String declaredExt) {
    // 双格式（.zip.lz4）按外层格式处理；tar.* 组合按 tar
    final ext = declaredExt.toLowerCase();
    for (final candidate in _archiveExtHints) {
      if (ext.endsWith(candidate)) {
        if (candidate.startsWith('.tar')) return 'tar';
        return candidate.substring(1);
      }
    }
    if (ext.endsWith('.lzma')) return 'lzma';
    return null;
  }

  /// 磁盘剩余空间粗护栏：GetDiskFreeSpaceExW FFI（★ Phase F，scenarios_v2
  /// §2「zip 炸弹/磁盘耗尽唯一无防线风险」的补落地；FFI 风格随
  /// lib/utils/network_path.dart 先例）。
  ///
  /// 降级原则（与 NetworkPath 一致）：非 Windows / FFI 异常 / 路径无盘符
  /// （UNC 网络路径）→ 返回 null，预检静默跳过，不阻断流程；执行期 7z
  /// 写盘报错仍作最后兜底。
  static int? _freeDiskBytesOf(String path) {
    // 取盘根：'D:/CTLIB/x' → 'D:\'；UNC/相对路径无盘符 → 跳过预检
    final m = RegExp(r'^([A-Za-z]:)').firstMatch(path);
    if (m == null) return null;
    final root = '${m.group(1)}\\';
    ffi.DynamicLibrary kernel32;
    try {
      kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    } catch (_) {
      return null; // 非 Windows / 被安全策略拦截
    }
    try {
      final getDiskFreeSpaceExW = kernel32.lookupFunction<
          ffi.Int32 Function(
              ffi.Pointer<pffi.Utf16>,
              ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>),
          int Function(
              ffi.Pointer<pffi.Utf16>,
              ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>,
              ffi.Pointer<ffi.Uint64>)>('GetDiskFreeSpaceExW');
      final rootPtr = root.toNativeUtf16();
      final freeAvail = pffi.malloc<ffi.Uint64>();
      final total = pffi.malloc<ffi.Uint64>();
      final totalFree = pffi.malloc<ffi.Uint64>();
      try {
        final ok = getDiskFreeSpaceExW(rootPtr, freeAvail, total, totalFree);
        if (ok == 0) return null; // 盘未挂载/离线：预检跳过（执行期兜底）
        return freeAvail.value;
      } finally {
        pffi.malloc.free(rootPtr);
        pffi.malloc.free(freeAvail);
        pffi.malloc.free(total);
        pffi.malloc.free(totalFree);
      }
    } catch (_) {
      return null;
    }
  }

  // ---------- 内部 ----------

  static String _declaredExtOf(String path) {
    final name = path.split('/').last.split('\\').last.toLowerCase();
    final dot = name.indexOf('.');
    if (dot < 0) return '';
    return name.substring(dot);
  }

  static bool _startsWith(List<int> head, List<int> magic) {
    if (head.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (head[i] != magic[i]) return false;
    }
    return true;
  }

  static String? _sniffIso(RandomAccessFile raf) {
    try {
      if (raf.lengthSync() < 0x8006) return null;
      final tag = _readAt(raf, 0x8001, 5);
      // "CD001"
      if (tag.length == 5 &&
          tag[0] == 0x43 &&
          tag[1] == 0x44 &&
          tag[2] == 0x30 &&
          tag[3] == 0x30 &&
          tag[4] == 0x31) {
        return 'iso';
      }
    } catch (_) {}
    return null;
  }

  static String? _sniffTar(RandomAccessFile raf) {
    try {
      if (raf.lengthSync() < 512) return null;
      final tag = _readAt(raf, 257, 5);
      // "ustar"
      if (tag.length == 5 &&
          tag[0] == 0x75 &&
          tag[1] == 0x73 &&
          tag[2] == 0x74 &&
          tag[3] == 0x61 &&
          tag[4] == 0x72) {
        return 'tar';
      }
    } catch (_) {}
    return null;
  }

  /// ★ 2026-10-05 尾部拼接 zip 嗅探（实机反馈：用户资源
  /// `Wu5U4_重力势能【PC】.mp4` 为「真 MP4 头 + 8.3MB 起拼接近 2.6GB zip」
  /// 的网盘过审壳，zip 内是 .rar 再包一层）。
  ///
  /// 原理：zip 的 EOCD（End Of Central Directory，签名 PK\x05\x06）
  /// 位于压缩包数据末尾，无论整个 zip 被拼在宿主文件哪个位置，EOCD
  /// 都跟着 zip 尾部走——从文件尾向前扫 EOCD 即可反查。内置 7z 23.01
  /// 按 EOCD 定位打开此类文件完全无视前缀（dev_probe/_probe_7z_mp4.txt
  /// 实测 2.6GB mp4 壳直解成功），嗅探命中后无需预剥离前缀。
  ///
  /// 误报防御（两路结构校验）：视频数据尾部随机撞上 4 字节 EOCD 签名
  /// 但同时通过结构校验的概率可忽略——
  /// - 路径 A：EOCD 内 central directory size/offset 字段（小端 u32）
  ///   非 ZIP64 占位 0xFFFFFFFF 且 offset+size ≤ 文件长度；
  /// - 路径 B（ZIP64 兜底）：EOCD 紧前方 20 字节是 ZIP64 locator
  ///   （PK\x06\x07，20 字节定长，标准布局紧贴 EOCD）。
  ///
  /// 扫描窗口 256KB：EOCD 离文件尾的距离 = zip 注释（≤64KB 上限）+
  /// 宿主壳收尾结构（实测 mp4 壳 ~11.3KB）；超窗的极端壳不识别，
  /// 保持「普通文件」原行为。
  static String? _sniffTrailingZip(RandomAccessFile raf) {
    try {
      final len = raf.lengthSync();
      if (len < 22) return null; // EOCD 自身就 22 字节
      const window = 256 * 1024;
      final start = len > window ? len - window : 0;
      final tail = _readAt(raf, start, len - start);
      // 从后向前找 EOCD 签名（PK\x05\x06）；越靠后越可能是真 EOCD
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] != 0x50 ||
            tail[i + 1] != 0x4B ||
            tail[i + 2] != 0x05 ||
            tail[i + 3] != 0x06) {
          continue;
        }
        // 路径 A：central directory size/offset 结构校验（小端 u32）
        final cdSize = _u32le(tail, i + 12);
        final cdOffset = _u32le(tail, i + 16);
        const zip64Mask = 0xFFFFFFFF;
        if (cdSize != zip64Mask &&
            cdOffset != zip64Mask &&
            cdOffset + cdSize <= len) {
          return 'zip';
        }
        // 路径 B：ZIP64 包 offset/size 字段是 0xFFFFFFFF 占位，真值在
        // ZIP64 EOCD——其 20 字节 locator 标准布局紧贴普通 EOCD 前方
        if (i >= 20 &&
            tail[i - 20] == 0x50 &&
            tail[i - 19] == 0x4B &&
            tail[i - 18] == 0x06 &&
            tail[i - 17] == 0x07) {
          return 'zip';
        }
      }
    } catch (_) {
      // 尾部读取失败按未知处理，交回调用方的原判定
    }
    return null;
  }

  /// 小端 u32 读取（EOCD 字段解析用）
  static int _u32le(List<int> b, int off) =>
      b[off] |
      (b[off + 1] << 8) |
      (b[off + 2] << 16) |
      (b[off + 3] << 24);

  static List<int> _readAt(RandomAccessFile raf, int offset, int count) {
    raf.setPositionSync(offset);
    return raf.readSync(count);
  }
}

/// `7z l` 结果
class _ListResult {
  const _ListResult({
    required this.exitCode,
    this.totalSize,
    this.nestedArchives = const [],
    this.encryptedArchive = false,
    this.errorLine = '',
  });

  final int exitCode;
  final int? totalSize;
  final List<String> nestedArchives;
  final bool encryptedArchive;
  final String errorLine;
}
