import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/game_resource_model.dart';

/// 模拟 PocketBase RecordModel 的最小替身
///
/// `GameResourceModel.fromPBRecord` 只用到四个入口：
/// `id` / `getStringValue()` / `getListValue()` / `data[]`。
class _FakeRecord {
  @override
  final String id;
  final Map<String, dynamic> _data;

  _FakeRecord(this.id, this._data);

  Map<String, dynamic> get data => _data;

  String? getStringValue(String field) {
    final v = _data[field];
    if (v == null) return null;
    return v.toString();
  }

  List<dynamic> getListValue(String field) {
    final v = _data[field];
    if (v is List) return v;
    return const [];
  }
}

void main() {
  group('GameResourceModel.fromPBRecord — 基础字段', () {
    test('完整记录：逐字段解析正确', () {
      final rec = _FakeRecord('rec1234567890ab', {
        'game': 'game1234567890a',
        'kind': 'community',
        'title': '百度网盘 · 汉化版',
        'url': 'https://pan.baidu.com/s/abc',
        'link_type': 'netdisk',
        'netdisk_provider': 'baidu',
        'extract_code': 'ab12',
        'file_size': '10.98 GB',
        'owner': 'user1234567890a',
        'owner_name': '某位分享者',
        'source_note': '自购分享',
        'note': '解压前请关闭杀软',
        'status': 'published',
        'reject_reason': '',
        'report_count': 0,
        'resource_type': ['游戏本体'],
        'languages': ['简体中文'],
        'platforms': ['Windows'],
        'unzip_code': '1122,3344',
        'download_count': 245,
        'like_count': 244,
        'created': '2026-09-30 09:30:00.000Z',
        'updated': '2026-10-01 01:00:00.000Z',
      });

      final m = GameResourceModel.fromPBRecord(rec);

      expect(m.id, 'rec1234567890ab');
      expect(m.gameId, 'game1234567890a');
      expect(m.kind, ResourceKind.community);
      expect(m.title, '百度网盘 · 汉化版');
      expect(m.url, 'https://pan.baidu.com/s/abc');
      expect(m.linkType, ResourceLinkType.netdisk);
      expect(m.netdiskProvider, 'baidu');
      expect(m.netdiskProviderLabel, '百度网盘');
      expect(m.extractCode, 'ab12');
      expect(m.fileSize, '10.98 GB');
      expect(m.ownerId, 'user1234567890a');
      expect(m.ownerName, '某位分享者');
      expect(m.status, ResourceStatus.published);
      expect(m.resourceTypes, ['游戏本体']);
      expect(m.languages, ['简体中文']);
      expect(m.platforms, ['Windows']);
      expect(m.downloadCount, 245);
      expect(m.likeCount, 244);

      expect(m.isCommunity, isTrue);
      expect(m.isOfficial, isFalse);
      expect(m.isPublished, isTrue);
      expect(m.hasUrl, isTrue);
      expect(m.hasDownloadPath, isFalse);
      expect(m.hasExtractCode, isTrue);
      expect(m.createdDateLabel, '2026-09-30');
    });

    test('official 记录：走 downloadPath，owner 为看板娘名', () {
      final rec = _FakeRecord('off1234567890ab', {
        'game': 'game1234567890a',
        'kind': 'official',
        'title': 'Chrono Tide 官方来源',
        'download_path': '/games/999/ChronoTide',
        'version': '',
        'version_note': 'v1.02 汉化版',
        'owner': 'kanban123456789',
        'owner_name': '时之 汐乃',
        'status': 'published',
        'resource_type': ['游戏本体', '民间汉化'],
        'platforms': ['Windows'],
        'download_count': 128,
        'like_count': 244,
        'created': '2026-09-01 00:00:00.000Z',
      });

      final m = GameResourceModel.fromPBRecord(rec);

      expect(m.isOfficial, isTrue);
      expect(m.hasDownloadPath, isTrue);
      expect(m.displayOwnerName, '时之 汐乃');
      expect(m.resourceTypes, ['游戏本体', '民间汉化'], reason: '多选字段');
      // versionLabel 优先取 versionNote
      expect(m.versionLabel, 'v1.02 汉化版');
      expect(m.downloadCount, 128);
    });
  });

  group('GameResourceModel — 容错', () {
    test('字段全缺：不抛异常，全部退化为默认值', () {
      final rec = _FakeRecord('onlyid123456789', {});

      final m = GameResourceModel.fromPBRecord(rec);

      expect(m.id, 'onlyid123456789');
      expect(m.gameId, '');
      expect(m.kind, ResourceKind.community);
      expect(m.status, ResourceStatus.pending);
      expect(m.resourceTypes, isEmpty);
      expect(m.downloadCount, 0);
      expect(m.likeCount, 0);
      expect(m.linkType, isNull);
      expect(m.netdiskProviderLabel, '');
      expect(m.unzipCodeList, isEmpty);
      expect(m.displayOwnerName, '');
      expect(m.versionLabel, '');
    });

    test('未知枚举值：回退到安全默认（community / pending）', () {
      final rec = _FakeRecord('x1234567890abcd', {
        'kind': 'weird_kind',
        'status': 'weird_status',
        'link_type': 'weird',
      });

      final m = GameResourceModel.fromPBRecord(rec);

      expect(m.kind, ResourceKind.community);
      expect(m.status, ResourceStatus.pending);
      expect(m.linkType, isNull, reason: '未知外链类型 → null，UI 不展示');
    });

    test('select 多选字段：List 与逗号字符串两种形态都能解析', () {
      final asList = GameResourceModel.fromPBRecord(
        _FakeRecord('a1234567890abcd', {
          'languages': ['简体中文', '日本語'],
        }),
      );
      expect(asList.languages, ['简体中文', '日本語']);

      final asCsv = GameResourceModel.fromPBRecord(
        _FakeRecord('b1234567890abcd', {
          'languages': '简体中文,日本語',
        }),
      );
      expect(asCsv.languages, ['简体中文', '日本語'],
          reason: '回退路径：按逗号切分并去空白');
    });

    test('number 字段：int / num / 字符串 三种输入都归一化为 int', () {
      final m = GameResourceModel.fromPBRecord(
        _FakeRecord('c1234567890abcd', {
          'download_count': '77',
          'like_count': 12.0,
          'report_count': 0,
        }),
      );
      expect(m.downloadCount, 77);
      expect(m.likeCount, 12);
      expect(m.reportCount, 0);
    });
  });

  group('GameResourceModel — 派生 getter', () {
    test('unzipCodeList：按逗号拆分并保持顺序、剔除空项', () {
      final m = GameResourceModel.fromPBRecord(
        _FakeRecord('d1234567890abcd', {'unzip_code': '1111, 2222 ,, 3333'}),
      );
      expect(m.unzipCodeList, ['1111', '2222', '3333'],
          reason: '顺序即解压顺序，不可排序或去重');
    });

    test('versionLabel：versionNote 优先于 version', () {
      final a = GameResourceModel.fromPBRecord(
        _FakeRecord('e1234567890abcd', {'version': 'v1', 'version_note': ''}),
      );
      expect(a.versionLabel, 'v1');

      final b = GameResourceModel.fromPBRecord(
        _FakeRecord('f1234567890abcd', {'version': 'v1', 'version_note': '备注'}),
      );
      expect(b.versionLabel, '备注');

      final c = GameResourceModel.fromPBRecord(
        _FakeRecord('g1234567890abcd', {}),
      );
      expect(c.versionLabel, '');
    });

    test('createdDateLabel：个位数月份 / 日期补零', () {
      final m = GameResourceModel.fromPBRecord(
        _FakeRecord('h1234567890abcd', {
          'created': '2026-01-05 08:00:00.000Z',
        }),
      );
      expect(m.createdDateLabel, '2026-01-05');
    });

    test('createdAgeLabel：刚刚 / 小时 / 天 / 月 / 年 五档（含未来时间兜底）', () {
      GameResourceModel mk(DateTime t) => GameResourceModel(
            id: 'x', created: t, updated: t,
          );
      final now = DateTime(2026, 10, 1, 12);
      expect(mk(now.subtract(const Duration(minutes: 5))).createdAgeLabel(now: now),
          '刚刚');
      expect(mk(now.subtract(const Duration(hours: 5))).createdAgeLabel(now: now),
          '5 小时前');
      expect(mk(now.subtract(const Duration(days: 3))).createdAgeLabel(now: now),
          '3 天前');
      expect(mk(now.subtract(const Duration(days: 120))).createdAgeLabel(now: now),
          '4 个月前');
      expect(mk(now.subtract(const Duration(days: 800))).createdAgeLabel(now: now),
          '2 年前');
      // 服务端时钟比客户端快 → 差值为负，不得输出「-1 天前」
      expect(mk(now.add(const Duration(hours: 2))).createdAgeLabel(now: now),
          '刚刚');
    });

    test('netdiskProviderLabelOf：全部 wire 值都有中文名', () {
      expect(GameResourceModel.netdiskProviderLabelOf('baidu'), '百度网盘');
      expect(GameResourceModel.netdiskProviderLabelOf('quark'), '夸克网盘');
      expect(GameResourceModel.netdiskProviderLabelOf('aliyun'), '阿里云盘');
      expect(GameResourceModel.netdiskProviderLabelOf('xunlei'), '迅雷云盘');
      expect(GameResourceModel.netdiskProviderLabelOf('115'), '115 网盘');
      expect(GameResourceModel.netdiskProviderLabelOf('onedrive'), 'OneDrive');
      expect(GameResourceModel.netdiskProviderLabelOf('mega'), 'MEGA');
      expect(GameResourceModel.netdiskProviderLabelOf('google_drive'),
          'Google Drive');
      expect(GameResourceModel.netdiskProviderLabelOf('other'), '其他网盘');
      expect(GameResourceModel.netdiskProviderLabelOf('unknown'), '',
          reason: '未知值返回空串，UI 应跳过该徽章');
    });
  });

  group('ResourceStatus / ResourceKind — 枚举语义', () {
    test('status 中文标签', () {
      expect(ResourceStatus.pending.label, '审核中');
      expect(ResourceStatus.published.label, '有效');
      expect(ResourceStatus.rejected.label, '已驳回');
      expect(ResourceStatus.hidden.label, '已隐藏');
    });

    test('wire 值与 PB Values 完全一致（写回服务端不会 400）', () {
      expect(ResourceKind.official.wire, 'official');
      expect(ResourceKind.community.wire, 'community');
      expect(ResourceStatus.pending.wire, 'pending');
      expect(ResourceStatus.published.wire, 'published');
      expect(ResourceStatus.rejected.wire, 'rejected');
      expect(ResourceStatus.hidden.wire, 'hidden');
      expect(ResourceLinkType.netdisk.wire, 'netdisk');
      expect(ResourceLinkType.direct.wire, 'direct');
      expect(ResourceLinkType.other.wire, 'other');
    });
  });

  group('toSubmitBody — 不得携带受控字段', () {
    test('body 里不出现 kind / status / owner / 计数字段', () {
      final m = GameResourceModel(
        id: 'x',
        kind: ResourceKind.community,
        title: 't',
        url: 'https://example.com',
        fileSize: '1 GB',
        status: ResourceStatus.published,
        ownerId: 'u1',
        downloadCount: 9,
        likeCount: 8,
        reportCount: 7,
        created: DateTime(2026),
        updated: DateTime(2026),
      );

      final body = m.toSubmitBody();

      for (final forbidden in [
        'kind',
        'status',
        'owner',
        'download_count',
        'like_count',
        'report_count',
      ]) {
        expect(body.containsKey(forbidden), isFalse,
            reason: '$forbidden 由服务端规则/Hook 管控，客户端传入会被拦或还原');
      }
      expect(body['title'], 't');
      expect(body['url'], 'https://example.com');
    });
  });
}
