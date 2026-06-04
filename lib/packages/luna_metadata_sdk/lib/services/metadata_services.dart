import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';
import 'bangumi_service.dart';

class VNDBService implements MetadataSourceService {
  late Dio _dio;

  VNDBService({Dio? dio}) {
    _dio = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 25),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'LunaBox/2.0 (Metadata Scraper)',
          },
        ));
  }

  @override
  SourceType get sourceType => SourceType.vndb;

  @override
  String get sourceName => 'VNDB';

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.post(
        'https://api.vndb.org/kana/vn',
        data: {
          'filters': ['search', '=', 'test'],
          'fields': 'id, title',
          'sort': 'searchrank',
        },
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final response = await _dio.post(
        'https://api.vndb.org/kana/vn',
        data: {
          'filters': ['search', '=', name],
          'fields':
              'id, title, titles{lang, title, latin, official, main}, image{url}, description, rating, released, developers{name}, tags{name, rating, spoiler}',
          'sort': 'searchrank',
        },
      );

      if (response.statusCode != 200) {
        return MetadataResult(
            game: Game(id: '', name: '', sourceType: SourceType.vndb));
      }

      final json =
          response.data is String ? jsonDecode(response.data) : response.data;
      final results = safeList(json, 'results');

      if (results == null || results.isEmpty) {
        return MetadataResult(
            game: Game(id: '', name: '', sourceType: SourceType.vndb));
      }

      final result =
          results[0] is Map ? Map<String, dynamic>.from(results[0]) : null;
      if (result == null) {
        return MetadataResult(
            game: Game(id: '', name: '', sourceType: SourceType.vndb));
      }
      return _parseResponse(result);
    } catch (e) {
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.vndb));
    }
  }

  MetadataResult _parseResponse(Map<String, dynamic> json) {
    String name = safeString(json, 'title') ?? '';
    final titles = safeList(json, 'titles');
    if (titles != null && titles.isNotEmpty) {
      for (final t in titles) {
        if (t is! Map) continue;
        final titleMap = Map<String, dynamic>.from(t);
        final isMain = safeBool(titleMap, 'main') ?? false;
        final lang = safeString(titleMap, 'lang') ?? '';
        final titleText = safeString(titleMap, 'title') ?? '';
        final latinText = safeString(titleMap, 'latin') ?? '';

        if ((isMain || lang.startsWith('zh') || lang.startsWith('ja')) &&
            (titleText.isNotEmpty || latinText.isNotEmpty)) {
          name = titleText.isNotEmpty ? titleText : latinText;
          break;
        }
      }
    }

    String coverUrl = '';
    final image = safeMap(json, 'image');
    if (image != null) {
      coverUrl = safeString(image, 'url') ?? '';
    }

    String company = '';
    final developers = safeList(json, 'developers');
    if (developers != null && developers.isNotEmpty) {
      final devNames = <String>[];
      for (final dev in developers.take(5)) {
        if (dev is Map) {
          final devName = safeString(Map<String, dynamic>.from(dev), 'name');
          if (devName != null && devName.isNotEmpty) {
            devNames.add(devName);
          }
        }
      }
      company = devNames.join(', ');
    }

    double rating = safeDouble(json, 'rating') ?? 0.0;
    if (rating > 10) rating = rating / 10.0;

    List<TagItem> tags = [];
    final tagsData = safeList(json, 'tags');
    if (tagsData != null) {
      final filteredTags = <Map<String, dynamic>>[];
      for (final tag in tagsData) {
        if (tag is! Map) continue;
        final tagMap = Map<String, dynamic>.from(tag);
        final tagRating = safeDouble(tagMap, 'rating') ?? 0.0;
        if (tagRating >= 1.5) {
          filteredTags.add(tagMap);
        }
      }

      filteredTags.sort((a, b) {
        final rA = safeDouble(a, 'rating') ?? 0.0;
        final rB = safeDouble(b, 'rating') ?? 0.0;
        return rB.compareTo(rA);
      });

      for (final tag in filteredTags.take(10)) {
        final tagName = safeString(tag, 'name');
        final tagRating = safeDouble(tag, 'rating') ?? 0.0;
        if (tagName != null && tagName.isNotEmpty) {
          tags.add(TagItem(
            name: tagName,
            source: 'vndb',
            weight: (tagRating / 3.0).clamp(0.1, 10.0),
          ));
        }
      }
    }

    return MetadataResult(
      game: Game(
        id: safeString(json, 'id') ?? '',
        name: name,
        coverUrl: coverUrl,
        company: company,
        summary: safeString(json, 'description') ?? '',
        rating: rating,
        releaseDate: safeString(json, 'released') ?? '',
        sourceType: SourceType.vndb,
        sourceId: safeString(json, 'id') ?? '',
      ),
      tags: tags,
    );
  }
}

class SteamService implements MetadataSourceService {
  late Dio _dio;

  SteamService({Dio? dio}) {
    _dio = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 25),
          headers: {
            'User-Agent': 'LunaBox/2.0 (Metadata Scraper)',
          },
        ));
  }

  @override
  SourceType get sourceType => SourceType.steam;

  @override
  String get sourceName => 'Steam';

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.get(
        'https://store.steampowered.com/api/storesearch/',
        queryParameters: {'term': 'test', 'l': 'schinese', 'cc': 'CN'},
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final keyword = name.trim();
      if (keyword.isEmpty) {
        return _emptyResult();
      }

      final searchResults = await _searchByName(keyword);
      if (searchResults.isEmpty) {
        return _emptyResult();
      }

      final bestMatch = _pickBestMatch(searchResults, keyword);
      if (bestMatch['id'] == null) {
        return _emptyResult();
      }

      return await _fetchByAppID(bestMatch['id'] as int);
    } catch (e) {
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.steam));
    }
  }

  Future<List<Map<String, dynamic>>> _searchByName(String keyword) async {
    final response = await _dio.get(
      'https://store.steampowered.com/api/storesearch/',
      queryParameters: {
        'term': keyword,
        'l': 'schinese',
        'cc': 'CN',
      },
    );

    if (response.statusCode != 200) {
      return [];
    }

    final json =
        response.data is String ? jsonDecode(response.data) : response.data;
    final items = safeList(json, 'items');
    if (items == null || items.isEmpty) {
      return [];
    }

    return items.map((item) {
      if (item is Map) return Map<String, dynamic>.from(item);
      return <String, dynamic>{};
    }).toList();
  }

  Map<String, dynamic> _pickBestMatch(
      List<Map<String, dynamic>> items, String query) {
    if (items.isEmpty) return {};

    final specialChars = RegExp(r'[-_:(\)\[\]"]');
    final queryLower = query.toLowerCase().replaceAll(specialChars, ' ');
    Map<String, dynamic> bestResult = items[0];
    int bestScore = -1;

    for (final item in items) {
      final itemName = (safeString(item, 'name') ?? '').toLowerCase();
      final itemId = safeInt(item, 'id') ?? 0;

      int score = 0;
      if (itemName == queryLower) score += 100;
      if (itemName.startsWith(queryLower)) score += 40;
      if (itemName.contains(queryLower)) score += 20;

      if (score > bestScore && itemId > 0) {
        bestScore = score;
        bestResult = item;
      }
    }

    return bestResult;
  }

  Future<MetadataResult> _fetchByAppID(int appID) async {
    final response = await _dio.get(
      'https://store.steampowered.com/api/appdetails',
      queryParameters: {
        'appids': appID,
        'l': 'schinese',
        'cc': 'CN',
      },
    );

    if (response.statusCode != 200) {
      return _emptyResult();
    }

    final json =
        response.data is String ? jsonDecode(response.data) : response.data;
    final appIDStr = appID.toString();
    final appData = safeMap(json, appIDStr);

    if (appData == null) {
      return _emptyResult();
    }

    final success = safeBool(appData, 'success') ?? false;
    if (!success) {
      return _emptyResult();
    }

    final data = safeMap(appData, 'data');
    if (data == null) {
      return _emptyResult();
    }

    return _parseAppDetails(data, appIDStr);
  }

  MetadataResult _parseAppDetails(Map<String, dynamic> data, String appIDStr) {
    final name = safeString(data, 'name')?.trim() ?? '';
    if (name.isEmpty) {
      return _emptyResult();
    }

    double rating = 0.0;
    final metacritic = safeMap(data, 'metacritic');
    if (metacritic != null) {
      final metaScore = safeInt(metacritic, 'score') ?? 0;
      if (metaScore > 0) {
        rating = metaScore / 10.0;
      }
    }

    List<TagItem> tags = [];
    final genres = safeList(data, 'genres');
    if (genres != null) {
      int index = 0;
      for (final genre in genres.take(8)) {
        String genreName = '';
        if (genre is String) {
          genreName = genre;
        } else if (genre is Map) {
          genreName =
              safeString(Map<String, dynamic>.from(genre), 'description') ?? '';
        }
        genreName = genreName.trim();
        if (genreName.isNotEmpty) {
          tags.add(TagItem(
            name: genreName,
            source: 'steam',
            weight: genres.length > 0
                ? (1.0 - index++ / genres.length).clamp(0.3, 1.0)
                : 1.0,
          ));
        }
      }
    }

    final developers = safeList(data, 'developers');
    String company = '';
    if (developers != null && developers.isNotEmpty) {
      final devNames = developers
          .where((d) => d is String)
          .map((d) => d.toString().trim())
          .where((s) => s.isNotEmpty)
          .take(3)
          .toList();
      company = devNames.join(', ');
    }

    String releaseDate = '';
    final releaseData = safeMap(data, 'release_date');
    if (releaseData != null) {
      releaseDate = safeString(releaseData, 'date') ?? '';
      if (releaseDate.isNotEmpty) {
        final dateRegex = RegExp(r'(\d{4})\D+(\d{1,2})\D+(\d{1,2})');
        final match = dateRegex.firstMatch(releaseDate);
        if (match != null) {
          final year = int.tryParse(match.group(1) ?? '') ?? 0;
          final month = int.tryParse(match.group(2) ?? '') ?? 0;
          final day = int.tryParse(match.group(3) ?? '') ?? 0;
          if (year > 0 && month > 0 && day > 0) {
            releaseDate =
                '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
          }
        }
      }
    }

    return MetadataResult(
      game: Game(
        id: appIDStr,
        name: name,
        coverUrl: safeString(data, 'header_image')?.trim() ?? '',
        company: company,
        summary: safeString(data, 'short_description')?.trim() ?? '',
        rating: rating.clamp(0.0, 10.0),
        releaseDate: releaseDate,
        sourceType: SourceType.steam,
        sourceId: appIDStr,
      ),
      tags: tags,
    );
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.steam));
  }
}

class DLsiteService implements MetadataSourceService {
  late Dio _dio;

  DLsiteService({Dio? dio}) {
    _dio = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 25),
          receiveTimeout: const Duration(seconds: 30),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'ja,en;q=0.8',
            'Cookie': 'adultchecked=1; locale=ja',
          },
        ));
  }

  @override
  SourceType get sourceType => SourceType.dlsite;

  @override
  String get sourceName => 'DLsite';

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.get('https://www.dlsite.com/maniax/');
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final keyword = name.trim();
      if (keyword.isEmpty) {
        return _emptyResult();
      }

      final searchItems = await _searchByName(keyword);
      if (searchItems.isEmpty) {
        return _emptyResult();
      }

      final bestMatch = _pickBestMatch(searchItems, keyword);
      if (bestMatch['id'] == null || bestMatch['id'].toString().isEmpty) {
        return _emptyResult();
      }

      return await _fetchByID(bestMatch['id'].toString());
    } catch (e) {
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.dlsite));
    }
  }

  Future<List<Map<String, dynamic>>> _searchByName(String keyword) async {
    final encodedKeyword = Uri.encodeComponent(keyword).replaceAll('%20', '+');
    final url =
        'https://www.dlsite.com/maniax/fsr/=/language/jp/keyword/$encodedKeyword/';

    final response = await _dio.get(url);

    if (response.statusCode != 200) {
      return [];
    }

    final document = html_parser.parse(response.data);
    final items = <Map<String, dynamic>>[];

    document
        .querySelectorAll('.search_result_img_box_inner')
        .forEach((element) {
      String? id = element.attributes['data-list_item_product_id'];
      if (id == null || id.isEmpty) {
        final link = element.querySelector('a.work_thumb_inner');
        final href = link?.attributes['href'] ?? '';
        final idMatch =
            RegExp(r'(RJ|RE|VJ)\d{4,}', caseSensitive: false).firstMatch(href);
        if (idMatch != null) {
          id = idMatch.group(0)?.toUpperCase();
        }
      }

      if (id == null || id.isEmpty) return;

      final idRegExp = RegExp(r'^[RV][EJ]\d+$', caseSensitive: false);
      if (!idRegExp.hasMatch(id)) return;

      final nameLink = element.querySelector('.work_name a');
      String itemName = nameLink?.attributes['title']?.trim() ?? '';
      if (itemName.isEmpty) {
        itemName = nameLink?.text.trim() ?? '';
      }
      if (itemName.isEmpty) return;

      items.add({
        'id': id.toUpperCase(),
        'name': itemName,
      });
    });

    return items;
  }

  Map<String, dynamic> _pickBestMatch(
      List<Map<String, dynamic>> items, String query) {
    if (items.isEmpty) return {};
    final queryLower = query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    Map<String, dynamic> bestResult = items[0];
    int bestScore = -1;

    for (final item in items) {
      final itemName = (safeString(item, 'name') ?? '').toLowerCase();
      int score = 0;
      if (itemName == queryLower) score += 100;
      if (itemName.contains(queryLower)) score += 20;
      if (score > bestScore) {
        bestScore = score;
        bestResult = item;
      }
    }

    return bestResult;
  }

  Future<MetadataResult> _fetchByID(String id) async {
    final prefix = id.toUpperCase().startsWith('VJ') ? 'pro' : 'maniax';
    final url =
        'https://www.dlsite.com/$prefix/work/=/product_id/${id.toUpperCase()}.html';

    final response = await _dio.get(url);

    if (response.statusCode != 200) {
      return _emptyResult();
    }

    final document = html_parser.parse(response.data);

    final titleEl = document.querySelector('#work_name');
    String title = titleEl?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    if (title.isEmpty) {
      return _emptyResult();
    }

    String coverUrl = '';
    document.querySelectorAll('img, source').forEach((element) {
      if (coverUrl.isNotEmpty) return;

      final candidates = [
        element.attributes['data-src'],
        _extractFirstSrcSet(element.attributes['srcset']),
        element.attributes['src'],
      ];

      for (final candidate in candidates) {
        if (candidate == null || candidate.isEmpty) continue;
        final normalized = _normalizeURL(candidate);
        if (normalized.isEmpty) continue;

        if (normalized.contains('_img_main')) {
          coverUrl = normalized;
          return;
        }
        if (coverUrl.isEmpty && normalized.contains('_img_smp')) {
          coverUrl = normalized;
        }
      }
    });

    String company = '';
    final makerEl = document.querySelector('.maker_name a');
    if (makerEl != null) {
      company = makerEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    String summary = '';
    final descEl = document.querySelector('[itemprop="description"]');
    if (descEl != null) {
      summary = descEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    String releaseDate = '';
    document.querySelectorAll('th').forEach((th) {
      if (releaseDate.isNotEmpty) return;
      final label = th.text.replaceAll(RegExp(r'\s+'), ' ');
      if (label.contains('販売日') ||
          label.contains('発売日') ||
          label.toLowerCase().contains('release')) {
        final td = th.nextElementSibling;
        if (td != null) {
          releaseDate = _normalizeJapaneseDate(td.text);
        }
      }
    });

    List<TagItem> tags = [];
    document.querySelectorAll('.main_genre a').forEach((a) {
      final tagName = a.text.trim();
      if (tagName.isNotEmpty) {
        tags.add(TagItem(name: tagName, source: 'dlsite', weight: 1.0));
      }
    });

    return MetadataResult(
      game: Game(
        id: id,
        name: title,
        coverUrl: coverUrl,
        company: company,
        summary: summary,
        releaseDate: releaseDate,
        sourceType: SourceType.dlsite,
        sourceId: id,
      ),
      tags: tags,
    );
  }

  String? _extractFirstSrcSet(String? srcset) {
    if (srcset == null || srcset.isEmpty) return null;
    final first = srcset.split(',').first.trim();
    if (first.isEmpty) return null;
    return first.split(RegExp(r'\s+')).first;
  }

  String _normalizeURL(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('http://') || value.startsWith('https://'))
      return value;
    if (value.startsWith('/')) return 'https://www.dlsite.com$value';
    return value;
  }

  String _normalizeJapaneseDate(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), '').trim();
    if (text.isEmpty) return '';

    var replaced = text
        .replaceAll('年', '-')
        .replaceAll('月', '-')
        .replaceAll('日', '')
        .replaceAll('.', '-')
        .replaceAll('/', '-');

    final parts = replaced.split('-');
    if (parts.length >= 3) {
      final year = int.tryParse(parts[0].trim()) ?? 0;
      final month = int.tryParse(parts[1].trim()) ?? 0;
      final day = int.tryParse(parts[2].trim()) ?? 0;
      if (year > 1900 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      }
    }

    return text;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.dlsite));
  }
}

class ErogameScapeService implements MetadataSourceService {
  late Dio _dio;
  static const String _baseURL =
      'https://erogamescape.org/~ap2/ero/toukei_kaiseki';

  ErogameScapeService({Dio? dio}) {
    _dio = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 25),
          receiveTimeout: const Duration(seconds: 30),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'ja,en;q=0.8',
            'Referer': _baseURL,
          },
        ));
  }

  @override
  SourceType get sourceType => SourceType.erogamescape;

  @override
  String get sourceName => 'ErogameScape';

  @override
  Future<bool> testConnection() async {
    try {
      final response = await _dio.get(_baseURL);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final keyword = name.trim();
      if (keyword.isEmpty) {
        return _emptyResult();
      }

      final searchItems = await _searchByName(keyword);
      if (searchItems.isEmpty) {
        return _emptyResult();
      }

      final bestMatch = _pickBestMatch(searchItems, keyword);
      if (bestMatch['id'] == null || bestMatch['id'].toString().isEmpty) {
        return _emptyResult();
      }

      return await _fetchByID(bestMatch['id'].toString());
    } catch (e) {
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.erogamescape));
    }
  }

  Future<List<Map<String, dynamic>>> _searchByName(String keyword) async {
    final response = await _dio.get(
      '$_baseURL/kensaku.php',
      queryParameters: {
        'category': 'game',
        'word_category': 'name',
        'mode': 'normal',
        'word': keyword,
      },
    );

    if (response.statusCode != 200) {
      return [];
    }

    final document = html_parser.parse(response.data);
    final items = <Map<String, dynamic>>[];

    int nameCol = 0;
    document.querySelectorAll('#result tr').asMap().forEach((index, row) {
      if (index == 0) {
        row.querySelectorAll('th').asMap().forEach((colIdx, cell) {
          final text = cell.text.trim();
          if (text == 'ゲーム名') nameCol = colIdx;
        });
        return;
      }

      final cells = row.querySelectorAll('td');
      if (cells.length <= nameCol) return;

      final nameCell = cells[nameCol];
      final link = nameCell.querySelector('a');
      if (link == null) return;

      final href = link.attributes['href'] ?? '';
      final idMatch = RegExp(r'[?&#/]game=(\d+)').firstMatch(href);
      if (idMatch == null) return;

      final id = idMatch.group(1)?.replaceFirst(RegExp(r'^0+'), '');
      final gameName =
          '${link.text.trim()} ${nameCell.querySelector('span')?.text.trim() ?? ''}'
              .trim();

      if (id != null && id.isNotEmpty && gameName.isNotEmpty) {
        items.add({'id': id, 'name': gameName});
      }
    });

    return items;
  }

  Map<String, dynamic> _pickBestMatch(
      List<Map<String, dynamic>> items, String query) {
    if (items.isEmpty) return {};
    final queryLower = query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    Map<String, dynamic> bestResult = items[0];
    int bestScore = -1;

    for (final item in items) {
      final itemName = (safeString(item, 'name') ?? '').toLowerCase();
      int score = 0;
      if (itemName == queryLower) score += 100;
      if (itemName.contains(queryLower)) score += 20;
      if (score > bestScore) {
        bestScore = score;
        bestResult = item;
      }
    }

    return bestResult;
  }

  Future<MetadataResult> _fetchByID(String id) async {
    final response = await _dio.get(
      '$_baseURL/game.php',
      queryParameters: {'game': id},
    );

    if (response.statusCode != 200) {
      return _emptyResult();
    }

    final document = html_parser.parse(response.data);

    String title = '';
    final titleEl = document.querySelector('#soft-title span.bold');
    if (titleEl != null) {
      title = titleEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    if (title.isEmpty) {
      final fallbackTitle = document.querySelector('#soft-title .bold');
      if (fallbackTitle != null) {
        title = fallbackTitle.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
    }
    if (title.isEmpty) {
      return _emptyResult();
    }

    String coverUrl = '';
    final imgEl = document.querySelector('#main_image img');
    if (imgEl != null) {
      final src = imgEl.attributes['src'] ?? '';
      if (src.isNotEmpty) {
        coverUrl = src.startsWith('http')
            ? src
            : '$_baseURL${src.startsWith('/') ? '' : '/'}$src';
      }
    }

    String company = '';
    final brandEl = document.querySelector('#brand td');
    if (brandEl != null) {
      company = brandEl.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    String releaseDate = '';
    final dateEl = document.querySelector('#sellday td');
    if (dateEl != null) {
      releaseDate = _normalizeJapaneseDate(dateEl.text);
    }

    double rating = 0.0;
    for (final selector in ['#median td', '#average td']) {
      final el = document.querySelector(selector);
      if (el != null) {
        final ratingText = el.text.trim();
        final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(ratingText);
        if (match != null) {
          rating = double.tryParse(match.group(1) ?? '') ?? 0.0;
          if (rating > 10) rating = rating / 10.0;
          break;
        }
      }
    }

    List<TagItem> tags = [];

    final erogameCell = document.querySelector('#erogame td');
    if (erogameCell != null) {
      final erogameText = erogameCell.text;
      for (final token in ['18禁', '非18禁', '抜きゲー', '非抜きゲー', '和姦もの', '陵辱もの']) {
        if (erogameText.contains(token)) {
          tags.add(TagItem(name: token, source: 'erogamescape', weight: 1.0));
        }
      }
    }

    final allowedHeaders = {
      '公式ジャンル': true,
      'ジャンル': true,
      'タグ': true,
      'シチュエーション': true,
      'エロシーン': true,
    };

    document.querySelectorAll('#att_pov_table tr').forEach((row) {
      final header = row.querySelector('th');
      if (header == null) return;
      final labelText = header.text.trim();
      if (!allowedHeaders.containsKey(labelText)) return;

      row.querySelectorAll('td a').forEach((a) {
        final tagName = a.text.trim();
        if (tagName.isNotEmpty) {
          tags.add(TagItem(name: tagName, source: 'erogamescape', weight: 1.0));
        }
      });
    });

    return MetadataResult(
      game: Game(
        id: id,
        name: title,
        coverUrl: coverUrl,
        company: company,
        releaseDate: releaseDate,
        rating: rating.clamp(0.0, 10.0),
        sourceType: SourceType.erogamescape,
        sourceId: id,
      ),
      tags: tags,
    );
  }

  String _normalizeJapaneseDate(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), '').trim();
    if (text.isEmpty) return '';

    var replaced = text
        .replaceAll('年', '-')
        .replaceAll('月', '-')
        .replaceAll('日', '')
        .replaceAll('.', '-')
        .replaceAll('/', '-');

    final parts = replaced.split('-');
    if (parts.length >= 3) {
      final year = int.tryParse(parts[0].trim()) ?? 0;
      final month = int.tryParse(parts[1].trim()) ?? 0;
      final day = int.tryParse(parts[2].trim()) ?? 0;
      if (year > 1900 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      }
    }

    return text;
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.erogamescape));
  }
}

class YmgalService implements MetadataSourceService {
  late Dio _dio;
  String? _cachedToken;
  DateTime? _tokenExpiresAt;

  YmgalService({Dio? dio}) {
    _dio = dio ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 25),
          headers: {
            'User-Agent': 'LunaBox/2.0 (Metadata Scraper)',
            'version': '1',
            'Accept': 'application/json;charset=utf-8',
          },
        ));
  }

  @override
  SourceType get sourceType => SourceType.ymgal;

  @override
  String get sourceName => '月幕GAL';

  @override
  Future<bool> testConnection() async {
    try {
      final token = await _getToken();
      return token != null;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    try {
      final keyword = name.trim();
      if (keyword.isEmpty) {
        return _emptyResult();
      }

      final token = await _getToken();
      if (token == null) {
        return _emptyResult();
      }

      final response = await _dio.get(
        'https://www.ymgal.games/open/archive/search-game',
        queryParameters: {
          'mode': 'accurate',
          'keyword': keyword,
          'similarity': '70',
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );

      if (response.statusCode != 200) {
        return _emptyResult();
      }

      final json =
          response.data is String ? jsonDecode(response.data) : response.data;
      final success = safeBool(json, 'success');
      if (success != true) {
        return _emptyResult();
      }

      final data = safeMap(json, 'data');
      if (data == null) {
        return _emptyResult();
      }

      final game = safeMap(data, 'game');
      if (game == null) {
        return _emptyResult();
      }

      return _parseYmgalResponse(game);
    } catch (e) {
      return MetadataResult(
          game: Game(id: '', name: '', sourceType: SourceType.ymgal));
    }
  }

  Future<String?> _getToken() async {
    if (_cachedToken != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!)) {
      return _cachedToken;
    }

    try {
      final response = await _dio.get(
        'https://www.ymgal.games/oauth/token',
        queryParameters: {
          'grant_type': 'client_credentials',
          'client_id': 'ymgal',
          'client_secret': 'luna0327',
          'scope': 'public',
        },
      );

      if (response.statusCode != 200) {
        return null;
      }

      final json =
          response.data is String ? jsonDecode(response.data) : response.data;
      final accessToken = safeString(json, 'access_token');
      final expiresIn = safeInt(json, 'expires_in') ?? 3600;

      if (accessToken != null && accessToken.isNotEmpty) {
        _cachedToken = accessToken;
        _tokenExpiresAt = DateTime.now()
            .add(Duration(seconds: expiresIn))
            .subtract(const Duration(seconds: 60));
        return accessToken;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  MetadataResult _parseYmgalResponse(Map<String, dynamic> json) {
    List<TagItem> tags = [];
    final tagsData = safeList(json, 'tags');
    if (tagsData != null) {
      for (final tag in tagsData.take(10)) {
        String? tagName;
        if (tag is String) {
          tagName = tag;
        } else if (tag is Map) {
          tagName = safeString(Map<String, dynamic>.from(tag), 'name');
        }
        if (tagName != null && tagName.isNotEmpty) {
          tags.add(TagItem(name: tagName, source: 'ymgal', weight: 1.0));
        }
      }
    }

    String name = safeString(json, 'chineseName') ?? '';
    if (name.isEmpty) name = safeString(json, 'name') ?? '';

    double rating = 0.0;
    final scoreRaw = json['score'];
    if (scoreRaw is num) {
      rating = scoreRaw.toDouble();
    } else if (scoreRaw is String) {
      rating = double.tryParse(scoreRaw) ?? 0.0;
    }
    if (rating > 10) rating = rating / 10.0;

    return MetadataResult(
      game: Game(
        id: (safeInt(json, 'gid') ?? safeString(json, 'id')).toString(),
        name: name,
        coverUrl: safeString(json, 'mainImg') ??
            safeString(json, 'cover_url') ??
            safeString(json, 'image') ??
            '',
        company: safeString(json, 'brand_name') ??
            safeString(json, 'company') ??
            safeString(json, 'developer_name'),
        summary: safeString(json, 'introduction') ??
            safeString(json, 'summary') ??
            '',
        rating: rating,
        releaseDate: safeString(json, 'release_date') ??
            safeString(json, 'publish_date') ??
            '',
        sourceType: SourceType.ymgal,
        sourceId: (safeInt(json, 'gid') ?? safeString(json, 'id')).toString(),
      ),
      tags: tags,
    );
  }

  MetadataResult _emptyResult() {
    return MetadataResult(
        game: Game(id: '', name: '', sourceType: SourceType.ymgal));
  }
}

class MetadataServiceFactory {
  static MetadataSourceService getService(SourceType sourceType) {
    if (sourceType == SourceType.bangumi) {
      return BangumiMirrorService();
    } else if (sourceType == SourceType.vndb) {
      return VNDBService();
    } else if (sourceType == SourceType.steam) {
      return SteamService();
    } else if (sourceType == SourceType.dlsite) {
      return DLsiteService();
    } else if (sourceType == SourceType.erogamescape) {
      return ErogameScapeService();
    } else if (sourceType == SourceType.ymgal) {
      return YmgalService();
    } else {
      throw ArgumentError('Unsupported source type: $sourceType');
    }
  }
}
