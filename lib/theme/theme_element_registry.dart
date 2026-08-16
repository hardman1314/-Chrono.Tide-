import 'package:flutter/material.dart';

/// v3.0 P2：可编辑元素类型
enum ThemeElementType {
  /// 容器类（侧栏/标题栏/卡片等有 fill+stroke 的容器）
  container,

  /// 按钮类（有 fill+stroke+textColor）
  button,

  /// 文字类（只有 textColor）
  text,

  /// 装饰类（图标/星标/状态色等只有 fill 的元素）
  decoration,
}

/// v3.0 P2：颜色通道类型
enum ThemeChannel {
  fill,
  stroke,
  textColor,
}

/// v3.0 P2：单个颜色通道的元数据
@immutable
class ThemeProperty {
  final ThemeChannel channel;
  final String tokenField;

  const ThemeProperty(this.channel, this.tokenField);

  /// 显示名
  String get displayName {
    switch (channel) {
      case ThemeChannel.fill:
        return '填充';
      case ThemeChannel.stroke:
        return '描边';
      case ThemeChannel.textColor:
        return '文字色';
    }
  }
}

/// v3.0 P2：可编辑元素描述符
///
/// 每个 [ThemeElementDescriptor] 描述一个用户可在编辑器中点击选择并调色的 UI 区域。
/// 元素与底层 CTThemeData 颜色令牌的映射通过 [properties] 表达。
///
/// A2 决策：[impactLocations] 字段用于"影响范围提示"，
/// 列出此元素修改会影响的实际 UI 位置。
@immutable
class ThemeElementDescriptor {
  /// 元素唯一 id（如 'app_sidebar'）
  final String id;

  /// 显示名（如 '侧栏'）
  final String displayName;

  /// 元素类型
  final ThemeElementType type;

  /// 颜色通道列表
  /// 容器类: [fill, stroke]
  /// 按钮类: [fill, stroke, textColor]
  /// 文字类: [textColor]
  /// 装饰类: [fill]（可能多个 fill）
  final List<ThemeProperty> properties;

  /// 影响范围（A2 决策）：列出此元素修改影响的实际 UI 位置
  final List<String> impactLocations;

  /// 预览骨架中此元素的显示标签文字（如 "库" / "Chrono Tide"）
  /// null 表示该元素无文字标签
  final String? previewLabel;

  const ThemeElementDescriptor({
    required this.id,
    required this.displayName,
    required this.type,
    required this.properties,
    required this.impactLocations,
    this.previewLabel,
  });

  /// 该元素是否包含某通道
  bool hasChannel(ThemeChannel channel) =>
      properties.any((p) => p.channel == channel);

  /// 该元素是否可调 fill
  bool get canFill => hasChannel(ThemeChannel.fill);

  /// 该元素是否可调 stroke
  bool get canStroke => hasChannel(ThemeChannel.stroke);

  /// 该元素是否可调 textColor
  bool get canTextColor => hasChannel(ThemeChannel.textColor);
}

/// v3.0.1 修复3：图层树节点
@immutable
class LayerNode {
  final String elementId;
  final String displayName;
  final List<LayerNode> children;
  final IconData icon;

  const LayerNode({
    required this.elementId,
    required this.displayName,
    this.children = const [],
    this.icon = Icons.widgets_outlined,
  });
}

/// v3.0 P2：可编辑元素注册表
///
/// 集中定义全部 24 个可编辑元素。
/// 新增元素仅需追加一个 const [ThemeElementDescriptor] 到 [_all] 列表。
///
/// 元素 -> CTThemeData 令牌的映射是运行时的（不进 JSON 主题文件），
/// 保证主题 JSON 与 v1/v2 互导兼容。
class ThemeElementRegistry {
  ThemeElementRegistry._();

  static List<ThemeElementDescriptor>? _all;

  /// 启动时调用一次（幂等）
  static void register() {
    if (_all != null) return;
    _all = const [
      // ============ 容器类 ============
      ThemeElementDescriptor(
        id: 'app_window',
        displayName: '主窗口背景',
        type: ThemeElementType.container,
        properties: [ThemeProperty(ThemeChannel.fill, 'background')],
        impactLocations: [
          '库页内容区',
          '探索页内容区',
          '主页内容区',
          '添加页内容区',
          '游戏详情页',
          '安装中心',
        ],
      ),
      ThemeElementDescriptor(
        id: 'app_sidebar',
        displayName: '侧栏',
        type: ThemeElementType.container,
        properties: [
          ThemeProperty(ThemeChannel.fill, 'sidebarBackground'),
          ThemeProperty(ThemeChannel.stroke, 'borderLight'),
        ],
        impactLocations: ['全应用侧栏（1 处，左侧固定）'],
        previewLabel: 'Chrono Tide',
      ),
      ThemeElementDescriptor(
        id: 'app_titlebar',
        displayName: '标题栏',
        type: ThemeElementType.container,
        properties: [ThemeProperty(ThemeChannel.fill, 'titleBarBackground')],
        impactLocations: ['标题栏（1 处，窗口顶部 kTitleBarHeight=32.0）'],
      ),
      ThemeElementDescriptor(
        id: 'app_card',
        displayName: '游戏卡片',
        type: ThemeElementType.container,
        properties: [
          ThemeProperty(ThemeChannel.fill, 'buttonBackground'),
          ThemeProperty(ThemeChannel.stroke, 'border'),
        ],
        impactLocations: [
          '库页游戏卡片背景（_LibraryCardWidget）',
          '探索页游戏卡片背景（_DiscoverCardWidget）',
          '主页游戏列表项背景',
          '注：库页/探索页两套独立 widget，颜色联动但样式细节独立',
        ],
        previewLabel: '游戏卡片',
      ),
      ThemeElementDescriptor(
        id: 'card_cover_placeholder',
        displayName: '卡片封面占位',
        type: ThemeElementType.container,
        properties: [
          ThemeProperty(ThemeChannel.fill, 'placeholderCover'),
        ],
        impactLocations: ['库页卡片占位封面', '探索页卡片占位封面'],
      ),
      ThemeElementDescriptor(
        id: 'button_bg',
        displayName: '通用按钮背景',
        type: ThemeElementType.container,
        properties: [ThemeProperty(ThemeChannel.fill, 'buttonBackground')],
        impactLocations: [
          '取消/确定按钮背景',
          '应用/编辑按钮背景',
          '导入/导出按钮背景',
          '一键抓取按钮背景',
          '设置项按钮背景',
          '更多操作菜单按钮背景',
          '注：游戏卡片背景也使用此令牌（联动变化）',
        ],
      ),

      // ============ 按钮类 ============
      ThemeElementDescriptor(
        id: 'nav_active',
        displayName: '侧栏激活按钮',
        type: ThemeElementType.button,
        properties: [
          ThemeProperty(ThemeChannel.fill, 'navActiveBg'),
          ThemeProperty(ThemeChannel.stroke, 'navActiveBorder'),
          ThemeProperty(ThemeChannel.textColor, 'primaryText'),
        ],
        impactLocations: ['侧栏当前激活的导航按钮（库/探索/添加 中 1 个）'],
        previewLabel: '库',
      ),
      ThemeElementDescriptor(
        id: 'nav_inactive',
        displayName: '侧栏非激活按钮',
        type: ThemeElementType.button,
        properties: [
          ThemeProperty(ThemeChannel.stroke, 'navInactiveBorder'),
          ThemeProperty(ThemeChannel.fill, 'cardHoverBg'),
          // v3.0.1 修复4：添加文字色通道（非激活按钮文字用 secondaryText）
          ThemeProperty(ThemeChannel.textColor, 'secondaryText'),
        ],
        impactLocations: ['侧栏 2 个未激活的导航按钮（自动联动）'],
        previewLabel: '探索',
      ),
      ThemeElementDescriptor(
        id: 'home_button',
        displayName: '主页按钮',
        type: ThemeElementType.button,
        properties: [
          ThemeProperty(ThemeChannel.fill, 'cardHoverBg'),
          ThemeProperty(ThemeChannel.stroke, 'border'),
          // v3.0.1 修复4：添加文字色通道（主页按钮非激活态用 secondaryText）
          ThemeProperty(ThemeChannel.textColor, 'secondaryText'),
        ],
        impactLocations: ['侧栏底部主页按钮（1 个）'],
        previewLabel: '主页',
      ),

      // ============ 文字类 ============
      ThemeElementDescriptor(
        id: 'app_titlebar_text',
        displayName: '标题栏文字',
        type: ThemeElementType.text,
        properties: [ThemeProperty(ThemeChannel.textColor, 'primaryText')],
        impactLocations: ['标题栏文字（窗口标题）'],
      ),
      ThemeElementDescriptor(
        id: 'sidebar_title',
        displayName: '侧栏大标题',
        type: ThemeElementType.text,
        properties: [
          ThemeProperty(ThemeChannel.textColor, 'titleBrown'),
        ],
        impactLocations: ['侧栏顶部 "Chrono Tide" 标题'],
        previewLabel: 'Chrono Tide',
      ),
      ThemeElementDescriptor(
        id: 'card_title',
        displayName: '卡片标题',
        type: ThemeElementType.text,
        properties: [ThemeProperty(ThemeChannel.textColor, 'primaryText')],
        impactLocations: [
          '库页游戏卡片标题（22 高标题栏）',
          '探索页游戏卡片标题（22 高标题栏）',
        ],
        previewLabel: '游戏标题',
      ),
      ThemeElementDescriptor(
        id: 'text_primary',
        displayName: '主要文字',
        type: ThemeElementType.text,
        properties: [ThemeProperty(ThemeChannel.textColor, 'primaryText')],
        impactLocations: [
          '库页/探索页游戏卡片标题（22 高标题栏）',
          '主页详情面板游戏大标题（ZhiMangXing 32 高）',
          '游戏详情页标题（ZhiMangXing 36 高）',
          '标题栏文字',
          '侧栏激活按钮文字',
          '通用按钮文字（取消/确定/应用等）',
          '设置项标题',
          '弹窗/对话框标题',
          '数量徽章文字（如"12 个主题"）',
          '标签芯片文字',
        ],
      ),
      ThemeElementDescriptor(
        id: 'text_secondary',
        displayName: '次要文字',
        type: ThemeElementType.text,
        properties: [ThemeProperty(ThemeChannel.textColor, 'secondaryText')],
        impactLocations: [
          '卡片制作方名（18 高，斜体）',
          '侧栏非激活按钮文字',
          '主页按钮文字',
          '游戏简介/描述正文',
          '设置项描述/辅助说明',
          '数量统计副文字（如"自定义主题"）',
          '日期/时间/大小文字',
          '更多操作菜单图标',
        ],
      ),
      ThemeElementDescriptor(
        id: 'text_placeholder',
        displayName: '占位文字',
        type: ThemeElementType.text,
        properties: [
          ThemeProperty(ThemeChannel.textColor, 'placeholderText'),
        ],
        impactLocations: [
          '搜索栏 placeholder（如"搜索游戏..."）',
          '命名弹窗输入框 placeholder',
          '路径输入框 placeholder',
          '标签输入框 placeholder',
          '描述输入框 placeholder',
          '空列表占位提示文字',
        ],
      ),
      ThemeElementDescriptor(
        id: 'button_text',
        displayName: '通用按钮文字',
        type: ThemeElementType.text,
        properties: [ThemeProperty(ThemeChannel.textColor, 'primaryText')],
        impactLocations: [
          '取消/确定按钮文字',
          '应用/编辑按钮文字',
          '导入/导出按钮文字',
          '一键抓取按钮文字',
          '入库/安装按钮文字',
          '所有通用操作按钮文字',
        ],
      ),

      // ============ 装饰类 ============
      ThemeElementDescriptor(
        id: 'accent_color',
        displayName: '主题强调色',
        type: ThemeElementType.decoration,
        properties: [ThemeProperty(ThemeChannel.fill, 'selectedAccent')],
        impactLocations: [
          '当前激活主题卡片边框',
          '侧栏激活按钮背景',
          '侧栏激活按钮边框',
          '主操作按钮背景（应用/确定）',
          '输入框聚焦边框',
          '选中态勾选标记',
          '主题设计器模式徽章（编辑模式）',
          '连锁影响提示图标',
        ],
      ),
      ThemeElementDescriptor(
        id: 'border_global',
        displayName: '全局边框',
        type: ThemeElementType.decoration,
        properties: [ThemeProperty(ThemeChannel.fill, 'border')],
        impactLocations: [
          '游戏卡片边框（激活态）',
          '主页按钮边框',
          '对话框/弹窗边框',
          '主题色预览圆描边',
          '我的主题区块外边框',
          '更多操作菜单边框',
          '命名弹窗边框',
        ],
      ),
      ThemeElementDescriptor(
        id: 'border_light_global',
        displayName: '全局浅边框',
        type: ThemeElementType.decoration,
        properties: [ThemeProperty(ThemeChannel.fill, 'borderLight')],
        impactLocations: [
          '侧栏边框',
          '游戏卡片边框（非激活态）',
          '次要按钮边框（取消等）',
          '更多操作按钮边框',
          '重命名输入框边框',
          '撤销/重做按钮边框',
          '分隔线',
        ],
      ),
      ThemeElementDescriptor(
        id: 'state_success',
        displayName: '成功状态',
        type: ThemeElementType.decoration,
        properties: [
          ThemeProperty(ThemeChannel.fill, 'successGreen'),
          ThemeProperty(ThemeChannel.fill, 'successBg'),
        ],
        impactLocations: [
          '成功提示 SnackBar',
          '"当前"主题徽章',
          '成功状态图标',
        ],
      ),
      ThemeElementDescriptor(
        id: 'state_danger',
        displayName: '危险状态',
        type: ThemeElementType.decoration,
        properties: [
          ThemeProperty(ThemeChannel.fill, 'dangerRed'),
          ThemeProperty(ThemeChannel.fill, 'errorBg'),
          ThemeProperty(ThemeChannel.fill, 'hoverCloseBg'),
          ThemeProperty(ThemeChannel.fill, 'hoverCloseBorder'),
        ],
        impactLocations: [
          '错误提示 SnackBar',
          '删除按钮及确认态',
          '关闭按钮 hover 态',
          '移除背景图按钮',
        ],
      ),
      ThemeElementDescriptor(
        id: 'state_info',
        displayName: '信息状态',
        type: ThemeElementType.decoration,
        properties: [
          ThemeProperty(ThemeChannel.fill, 'infoBlue'),
          ThemeProperty(ThemeChannel.fill, 'infoBg'),
          ThemeProperty(ThemeChannel.fill, 'brandBlue'),
        ],
        impactLocations: [
          '信息提示 SnackBar',
          '未保存修改指示器',
          '影响范围提示框',
          '新建主题模式徽章',
          '主题设计器入口渐变背景',
        ],
      ),
      ThemeElementDescriptor(
        id: 'state_star',
        displayName: '星级金色',
        type: ThemeElementType.decoration,
        properties: [ThemeProperty(ThemeChannel.fill, 'starGold')],
        impactLocations: ['评分星标'],
      ),

      // ============ 背景图 ============
      ThemeElementDescriptor(
        id: 'app_background_image',
        displayName: '应用背景图',
        type: ThemeElementType.decoration,
        properties: [], // 背景图通过独立控件处理
        impactLocations: ['3 个特色主题背景图 + 用户上传背景图'],
      ),
    ];
  }

  /// 获取全部元素
  static List<ThemeElementDescriptor> get all {
    if (_all == null) register();
    return _all!;
  }

  /// 通过 id 获取元素
  static ThemeElementDescriptor? byId(String id) {
    for (final e in all) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 默认选中元素（编辑器打开时）
  static String get defaultElementId => 'app_window';

  // ============ v3.0.1 修复3：图层树结构 ============

  /// 图层树根节点列表
  /// 结构反映 UI 视觉层级：窗口 → 标题栏/侧栏/内容区 → 子组件
  static List<LayerNode> get layerTree {
    return [
      LayerNode(
        elementId: 'app_window',
        displayName: '主窗口背景',
        icon: Icons.crop_landscape_outlined,
        children: [
          LayerNode(
            elementId: 'app_titlebar',
            displayName: '标题栏',
            icon: Icons.title_outlined,
            children: [
              LayerNode(
                elementId: 'app_titlebar_text',
                displayName: '标题栏文字',
                icon: Icons.text_fields_outlined,
              ),
            ],
          ),
          LayerNode(
            elementId: 'app_sidebar',
            displayName: '侧栏',
            icon: Icons.view_sidebar_outlined,
            children: [
              LayerNode(
                elementId: 'sidebar_title',
                displayName: '侧栏大标题',
                icon: Icons.text_fields_outlined,
              ),
              LayerNode(
                elementId: 'nav_active',
                displayName: '侧栏激活按钮',
                icon: Icons.toggle_on_outlined,
              ),
              LayerNode(
                elementId: 'nav_inactive',
                displayName: '侧栏非激活按钮',
                icon: Icons.toggle_off_outlined,
              ),
              LayerNode(
                elementId: 'home_button',
                displayName: '主页按钮',
                icon: Icons.home_outlined,
              ),
            ],
          ),
          LayerNode(
            elementId: 'app_card',
            displayName: '游戏卡片',
            icon: Icons.grid_view_outlined,
            children: [
              LayerNode(
                elementId: 'card_cover_placeholder',
                displayName: '卡片封面占位',
                icon: Icons.image_outlined,
              ),
              // v3.0.1 修复：恢复 card_title 到图层树。
              // 设计规范明确：_LibraryCardWidget = Column[Expanded(封面) + SizedBox(5)
              //   + 标题(22, gameTitle, primaryText) + 制作方(18, secondaryText italic)]
              // 卡片确有可见标题文字（22 高度的标题栏），原"无可见标题"判断有误。
              LayerNode(
                elementId: 'card_title',
                displayName: '卡片标题',
                icon: Icons.text_fields_outlined,
              ),
            ],
          ),
        ],
      ),
      LayerNode(
        elementId: 'button_bg',
        displayName: '通用按钮背景',
        icon: Icons.smart_button_outlined,
        children: [
          LayerNode(
            elementId: 'button_text',
            displayName: '通用按钮文字',
            icon: Icons.text_fields_outlined,
          ),
        ],
      ),
      LayerNode(
        elementId: 'text_primary',
        displayName: '主要文字',
        icon: Icons.text_fields_outlined,
      ),
      LayerNode(
        elementId: 'text_secondary',
        displayName: '次要文字',
        icon: Icons.text_fields_outlined,
      ),
      LayerNode(
        elementId: 'text_placeholder',
        displayName: '占位文字',
        icon: Icons.text_fields_outlined,
      ),
      LayerNode(
        elementId: 'accent_color',
        displayName: '主题强调色',
        icon: Icons.star_outline,
      ),
      LayerNode(
        elementId: 'border_global',
        displayName: '全局边框',
        icon: Icons.border_outer_outlined,
      ),
      LayerNode(
        elementId: 'border_light_global',
        displayName: '全局浅边框',
        icon: Icons.border_outer_outlined,
      ),
      LayerNode(
        elementId: 'state_success',
        displayName: '成功状态',
        icon: Icons.check_circle_outline,
      ),
      LayerNode(
        elementId: 'state_danger',
        displayName: '危险状态',
        icon: Icons.error_outline,
      ),
      LayerNode(
        elementId: 'state_info',
        displayName: '信息状态',
        icon: Icons.info_outline,
      ),
      LayerNode(
        elementId: 'state_star',
        displayName: '星级金色',
        icon: Icons.star_outline,
      ),
      LayerNode(
        elementId: 'app_background_image',
        displayName: '应用背景图',
        icon: Icons.wallpaper_outlined,
      ),
    ];
  }

  // ============ v3.0.1 修复3：连锁影响计算 ============

  /// 获取与指定元素共享令牌的所有其他元素
  /// 返回 (elementId, displayName, sharedTokens, impactLocations) 列表，
  /// 用于"连锁影响"提示——不仅显示连锁元素名称，还显示其影响的实际 UI 位置，
  /// 让用户明确知道修改此元素会连带影响哪些区域。
  static List<({
    String elementId,
    String displayName,
    List<String> sharedTokens,
    List<String> impactLocations,
  })> getChainedImpacts(String elementId) {
    final target = byId(elementId);
    if (target == null) return [];

    final targetTokens = target.properties
        .map((p) => p.tokenField)
        .toSet();

    final result = <({
      String elementId,
      String displayName,
      List<String> sharedTokens,
      List<String> impactLocations,
    })>[];

    for (final e in all) {
      if (e.id == elementId) continue;
      final shared = e.properties
          .where((p) => targetTokens.contains(p.tokenField))
          .map((p) => p.tokenField)
          .toSet()
          .toList();
      if (shared.isNotEmpty) {
        result.add((
          elementId: e.id,
          displayName: e.displayName,
          sharedTokens: shared,
          impactLocations: e.impactLocations,
        ));
      }
    }

    return result;
  }
}
