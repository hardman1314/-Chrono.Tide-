/// Luna Metadata SDK - 元数据抓取库
///
/// 支持的数据源：
/// - Bangumi (镜像站，匿名访问)
/// - VNDB
/// - Steam
/// - DLsite
/// - ErogameScape
/// - 月幕GAL
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
