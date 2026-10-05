/// Luna Metadata SDK - 元数据抓取库
///
/// 支持的数据源：
/// - Bangumi (原站，OAuth 优先 + 匿名兜底)
/// - VNDB
/// - Steam
/// - DLsite
/// - ErogameScape
/// - 月幕GAL
/// - TouchGal (需 Bearer Token)
/// - Hikarinagi (需 OAuth client_credentials 凭证)
/// - KunGal (公开 API)
/// - NextMoe (六源对齐目录，需应用密钥 nmk_)
///
/// 使用示例：
/// ```dart
/// import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
///
/// // 获取服务实例
/// final service = MetadataServiceFactory.getService(SourceType.bangumi);
///
/// // 测试连接
/// bool isConnected = await service.testConnection();
///
/// // 抓取元数据
/// final result = await service.fetchByName('CLANNAD');
/// if (result.isValid) {
///   print('游戏名称: ${result.game.name}');
///   print('封面URL: ${result.game.coverUrl}');
///   print('标签: ${result.tags.map((t) => t.name).join(', ')}');
/// }
/// ```

library luna_metadata_sdk;

export 'models/game.dart';
export 'models/tags.dart';

export 'services/metadata_base.dart';
export 'services/bangumi_service.dart';
export 'services/metadata_services.dart';
export 'services/touchgal_service.dart';
export 'services/tag_translator.dart';
export 'services/rate_limiter.dart';
export 'services/bangumi_oauth.dart';
export 'services/hikarinagi_service.dart';
export 'services/kun_service.dart';
export 'services/nextmoe_service.dart';
export 'services/ct_service.dart';
