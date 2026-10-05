import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/big_picture/focus/bpm_zone_focus_controller.dart';

/// BPM 分层板块焦点系统 — 状态机单测
///
/// 对应用户 2026-09-20 规范第 1–7 条。测试只驱动纯状态转移，不依赖 widget 树，
/// 因此可以精确断言「板块边界停 / 不跨级 / 落点」这类容易回归的规则。
void main() {
  group('规范第 1 条 — 启动默认态', () {
    test('v3.19: 默认停用焦点体系（进 BPM = 键鼠模式，无焦点区域划分）', () {
      final c = BpmZoneFocusController();
      expect(c.enabled, isFalse,
          reason: '焦点模式 = 手柄模式专属；进 BPM 不得默认启用');
      expect(c.isZoneMode, isFalse,
          reason: '板块高亮不应在键鼠模式下出现');
      expect(c.isComponentMode, isFalse);
      // 状态机坐标仍保持可用的初始位（enable 后即刻生效）
      expect(c.level, BpmFocusLevel.global);
      expect(c.mode, BpmFocusMode.zone);
      expect(c.zone, BpmZoneId.rail);
      expect(c.page, 0);
    });

    test('v3.19: enableFocusMode 启用后回到板块模式；disableFocusMode 停用', () {
      final c = BpmZoneFocusController();
      c.enableFocusMode();
      expect(c.enabled, isTrue);
      expect(c.isZoneMode, isTrue);
      // 手柄方向键移动板块后停用 → 高亮与模式判定全部归零
      c.moveZone(TraversalDirection.down);
      c.disableFocusMode();
      expect(c.enabled, isFalse);
      expect(c.isZoneMode, isFalse);
      expect(c.isComponentMode, isFalse);
    });

    test('板块 → 层级映射: panel 不属于任何层级', () {
      expect(bpmLevelOfZone(BpmZoneId.rail), BpmFocusLevel.global);
      expect(bpmLevelOfZone(BpmZoneId.topBar), BpmFocusLevel.global);
      expect(bpmLevelOfZone(BpmZoneId.stage), BpmFocusLevel.global);
      expect(bpmLevelOfZone(BpmZoneId.homeSearch), BpmFocusLevel.page);
      expect(bpmLevelOfZone(BpmZoneId.homeShelf), BpmFocusLevel.page);
      expect(bpmLevelOfZone(BpmZoneId.libraryTools), BpmFocusLevel.page);
      expect(bpmLevelOfZone(BpmZoneId.libraryWall), BpmFocusLevel.page);
      expect(bpmLevelOfZone(BpmZoneId.panel), isNull);
    });

    test('页面二级板块列表: 主页 3 块 / 库页 2 块, 最后一项都是卡片列表', () {
      final c = BpmZoneFocusController();
      expect(c.pageZones, kBpmHomeZones);
      expect(c.cardListZone, BpmZoneId.homeShelf);
      c.landOnCardList(page: 1);
      expect(c.pageZones, kBpmLibraryZones);
      expect(c.cardListZone, BpmZoneId.libraryWall);
    });
  });

  group('规范第 3 条 — 一级板块方向键空间邻接', () {
    test('rail: ↑ → topBar, → → stage', () {
      final c = BpmZoneFocusController();
      expect(c.moveZone(TraversalDirection.up), isTrue);
      expect(c.zone, BpmZoneId.topBar);
      c.resetForTest(zone: BpmZoneId.rail);
      expect(c.moveZone(TraversalDirection.right), isTrue);
      expect(c.zone, BpmZoneId.stage);
    });

    test('topBar: ↓ → stage, ← → rail', () {
      final c = BpmZoneFocusController();
      c.resetForTest(zone: BpmZoneId.topBar);
      expect(c.moveZone(TraversalDirection.down), isTrue);
      expect(c.zone, BpmZoneId.stage);
      c.resetForTest(zone: BpmZoneId.topBar);
      expect(c.moveZone(TraversalDirection.left), isTrue);
      expect(c.zone, BpmZoneId.rail);
    });

    test('stage: ↑ → topBar, ← → rail', () {
      final c = BpmZoneFocusController();
      c.resetForTest(zone: BpmZoneId.stage);
      expect(c.moveZone(TraversalDirection.up), isTrue);
      expect(c.zone, BpmZoneId.topBar);
      c.resetForTest(zone: BpmZoneId.stage);
      expect(c.moveZone(TraversalDirection.left), isTrue);
      expect(c.zone, BpmZoneId.rail);
    });

    test('无邻接的方向不消费 (板块边界停)', () {
      final c = BpmZoneFocusController();
      expect(c.moveZone(TraversalDirection.down), isFalse);
      expect(c.zone, BpmZoneId.rail);
      c.resetForTest(zone: BpmZoneId.stage);
      expect(c.moveZone(TraversalDirection.down), isFalse);
      expect(c.moveZone(TraversalDirection.right), isFalse);
      expect(c.zone, BpmZoneId.stage);
      c.resetForTest(zone: BpmZoneId.topBar);
      expect(c.moveZone(TraversalDirection.right), isFalse);
      expect(c.zone, BpmZoneId.topBar);
    });

    test('一级三块互相可达', () {
      final c = BpmZoneFocusController();
      final seen = <BpmZoneId>{c.zone};
      c.moveZone(TraversalDirection.up); // rail → topBar
      seen.add(c.zone);
      c.moveZone(TraversalDirection.down); // topBar → stage
      seen.add(c.zone);
      c.moveZone(TraversalDirection.left); // stage → rail
      seen.add(c.zone);
      expect(seen, kBpmGlobalZones.toSet());
    });
  });

  group('规范第 3 条 — 二级板块只在页内切换', () {
    test('主页: ↓ 依次 搜索栏 → 卡片列表（v3.14 操作按钮板块已移除）', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page,
            zone: BpmZoneId.homeSearch,
            page: 0);
      expect(c.moveZone(TraversalDirection.down), isTrue);
      expect(c.zone, BpmZoneId.homeShelf);
      expect(c.moveZone(TraversalDirection.down), isFalse);
      expect(c.zone, BpmZoneId.homeShelf);
    });

    test('主页: 首块 ↑ 停、末块 ↓ 停 —— 不跨到一级板块', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page,
            zone: BpmZoneId.homeSearch,
            page: 0);
      expect(c.moveZone(TraversalDirection.up), isFalse);
      expect(c.level, BpmFocusLevel.page, reason: '不得跨到一级板块');
      expect(c.zone, BpmZoneId.homeSearch);

      c.resetForTest(
          level: BpmFocusLevel.page, zone: BpmZoneId.homeShelf, page: 0);
      expect(c.moveZone(TraversalDirection.down), isFalse);
      expect(c.level, BpmFocusLevel.page);
      expect(c.zone, BpmZoneId.homeShelf);
    });

    test('库页只有两块: ↑↓ 在筛选操作 ⇄ 卡片列表之间', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page,
            zone: BpmZoneId.libraryWall,
            page: 1);
      expect(c.moveZone(TraversalDirection.up), isTrue);
      expect(c.zone, BpmZoneId.libraryTools);
      expect(c.moveZone(TraversalDirection.up), isFalse);
      expect(c.zone, BpmZoneId.libraryTools);
    });

    test('二级板块模式下 ←/→ 无操作 (规范只定义了上下)', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page,
            // v3.14: homeActions 板块已移除，改用仍存在的搜索栏板块
            zone: BpmZoneId.homeSearch,
            page: 0);
      expect(c.moveZone(TraversalDirection.left), isFalse);
      expect(c.moveZone(TraversalDirection.right), isFalse);
      expect(c.zone, BpmZoneId.homeSearch);
    });

    test('一级 stage 高亮时方向键仍在**一级**三块之间切换 (未下钻前)', () {
      final c = BpmZoneFocusController()..resetForTest(zone: BpmZoneId.stage);
      expect(c.moveZone(TraversalDirection.left), isTrue);
      expect(c.zone, BpmZoneId.rail);
      expect(c.level, BpmFocusLevel.global);
    });
  });

  group('规范第 5 条 — A 键 (确认进入板块)', () {
    test('rail 板块模式 A → 组件模式, 焦点目标 = rail', () {
      final c = BpmZoneFocusController();
      expect(c.confirm(), BpmZoneId.rail);
      expect(c.mode, BpmFocusMode.component);
      expect(c.level, BpmFocusLevel.global);
    });

    test('topBar 板块模式 A → 组件模式, 焦点目标 = topBar', () {
      final c = BpmZoneFocusController()..resetForTest(zone: BpmZoneId.topBar);
      expect(c.confirm(), BpmZoneId.topBar);
      expect(c.mode, BpmFocusMode.component);
    });

    test('一级 stage A → 下钻二级板块层并高亮第一个二级板块 (不动焦点)', () {
      final c = BpmZoneFocusController()..resetForTest(zone: BpmZoneId.stage);
      expect(c.confirm(), isNull, reason: '下钻只换层级, 不移动焦点');
      expect(c.level, BpmFocusLevel.page);
      expect(c.mode, BpmFocusMode.zone);
      expect(c.zone, BpmZoneId.homeSearch);
    });

    test('库页二级板块 A → 组件模式, 焦点目标 = 该板块', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page, zone: BpmZoneId.libraryTools, page: 1);
      expect(c.confirm(), BpmZoneId.libraryTools);
      expect(c.mode, BpmFocusMode.component);
    });

    test('组件模式下 A 不由状态机消费 (shell 交给控件激活)', () {
      final c = BpmZoneFocusController()..resetForTest(mode: BpmFocusMode.component);
      expect(c.confirm(), isNull);
    });
  });

  group('规范第 5 条 — B 键 (层级回退)', () {
    test('组件模式 B → 板块模式, 层级与板块不变', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page,
            mode: BpmFocusMode.component,
            zone: BpmZoneId.homeShelf);
      expect(c.back(), isTrue);
      expect(c.mode, BpmFocusMode.zone);
      expect(c.level, BpmFocusLevel.page);
      expect(c.zone, BpmZoneId.homeShelf);
    });

    test('二级板块模式 B → 一级板块模式, 高亮回到 rail', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page, zone: BpmZoneId.libraryWall, page: 1);
      expect(c.back(), isTrue);
      expect(c.level, BpmFocusLevel.global);
      expect(c.zone, BpmZoneId.rail);
      expect(c.mode, BpmFocusMode.zone);
    });

    test('一级板块模式 B → 不消费 (保持「B 不误退大屏」的既有约定)', () {
      final c = BpmZoneFocusController();
      expect(c.back(), isFalse);
      expect(c.level, BpmFocusLevel.global);
      expect(c.mode, BpmFocusMode.zone);
      expect(c.zone, BpmZoneId.rail);
    });

    test('A → B 可逐级还原 (rail 进 → 退)', () {
      final c = BpmZoneFocusController();
      c.confirm();
      expect(c.mode, BpmFocusMode.component);
      c.back();
      expect(c.mode, BpmFocusMode.zone);
      expect(c.zone, BpmZoneId.rail);
    });
  });

  group('规范第 2 条 — 进入页面后的落点', () {
    test('主页: 落点 = 卡片列表板块 + 组件模式', () {
      final c = BpmZoneFocusController();
      expect(c.landOnCardList(page: 0), BpmZoneId.homeShelf);
      expect(c.level, BpmFocusLevel.page);
      expect(c.mode, BpmFocusMode.component);
      expect(c.zone, BpmZoneId.homeShelf);
    });

    test('库页: 落点 = 卡片列表板块 + 组件模式', () {
      final c = BpmZoneFocusController();
      expect(c.landOnCardList(page: 1), BpmZoneId.libraryWall);
      expect(c.level, BpmFocusLevel.page);
      expect(c.mode, BpmFocusMode.component);
    });

    test('完整链路: rail A 进组件 → 激活页面项 → landOnCardList', () {
      final c = BpmZoneFocusController();
      expect(c.confirm(), BpmZoneId.rail); // A: 进入 rail 板块
      expect(c.mode, BpmFocusMode.component);
      // rail 内选中「我的库」并被激活 → shell 调 landOnCardList
      expect(c.landOnCardList(page: 1), BpmZoneId.libraryWall);
      expect(c.zone, BpmZoneId.libraryWall);
    });
  });

  group('规范第 4 条 — 组件模式方向键不跨板块', () {
    test('组件模式下 moveZone 一律不消费', () {
      for (final dir in TraversalDirection.values) {
        final c = BpmZoneFocusController()
          ..resetForTest(
              level: BpmFocusLevel.page,
              mode: BpmFocusMode.component,
              zone: BpmZoneId.homeShelf);
        expect(c.moveZone(dir), isFalse, reason: '$dir 不得切换板块');
        expect(c.zone, BpmZoneId.homeShelf);
      }
    });

    test('卡片列表组件模式必须先 B 才能切板块', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page,
            mode: BpmFocusMode.component,
            zone: BpmZoneId.homeShelf);
      expect(c.moveZone(TraversalDirection.up), isFalse);
      expect(c.back(), isTrue); // B 退出组件模式
      expect(c.moveZone(TraversalDirection.up), isTrue); // 此时才切板块
      // v3.14: 操作按钮板块已移除 → homeShelf 的上一块是搜索栏
      expect(c.zone, BpmZoneId.homeSearch);
    });
  });

  group('焦点域注册与查询 (纯逻辑部分)', () {
    BpmZoneDomain domain(BpmZoneId zone, FocusScopeNode scope) => BpmZoneDomain(
          zone: zone,
          scope: scope,
          policy: ReadingOrderTraversalPolicy(),
        );

    test('未注册的板块: domainOf / entryFocusOf 为空, focusEntryOf 返回 false', () {
      final c = BpmZoneFocusController();
      expect(c.domainOf(BpmZoneId.rail), isNull);
      expect(c.entryFocusOf(BpmZoneId.rail), isNull);
      expect(c.focusEntryOf(BpmZoneId.rail), isFalse);
      expect(c.zoneOfScope(null), isNull);
    });

    test('registerDomain 覆盖同板块的旧域', () {
      final scopeA = FocusScopeNode(debugLabel: 'A');
      final scopeB = FocusScopeNode(debugLabel: 'B');
      final c = BpmZoneFocusController()
        ..registerDomain(domain(BpmZoneId.homeShelf, scopeA))
        ..registerDomain(domain(BpmZoneId.homeShelf, scopeB));
      expect(c.domainOf(BpmZoneId.homeShelf)?.scope, same(scopeB));
      addTearDown(() {
        scopeA.dispose();
        scopeB.dispose();
      });
    });

    test('zoneOfScope 按 scope 身份反查板块', () {
      final scope = FocusScopeNode(debugLabel: 'rail');
      final other = FocusScopeNode(debugLabel: 'other');
      final c = BpmZoneFocusController()
        ..registerDomain(domain(BpmZoneId.rail, scope));
      expect(c.zoneOfScope(scope), BpmZoneId.rail);
      expect(c.zoneOfScope(other), isNull,
          reason: '模态等外来 scope 必须返回 null, 否则会误改板块状态');
      addTearDown(() {
        scope.dispose();
        other.dispose();
      });
    });

    test('unregisterDomain 只在该域仍持此 scope 时移除 (防旧页 dispose 误删新域)', () {
      final oldScope = FocusScopeNode(debugLabel: 'old');
      final newScope = FocusScopeNode(debugLabel: 'new');
      final c = BpmZoneFocusController()
        ..registerDomain(domain(BpmZoneId.libraryWall, newScope));

      // 模拟 AnimatedSwitcher 过渡: 新页已登记新域, 旧页随后 dispose
      c.unregisterDomain(BpmZoneId.libraryWall, oldScope);
      expect(c.domainOf(BpmZoneId.libraryWall)?.scope, same(newScope));

      c.unregisterDomain(BpmZoneId.libraryWall, newScope);
      expect(c.domainOf(BpmZoneId.libraryWall), isNull);
      addTearDown(() {
        oldScope.dispose();
        newScope.dispose();
      });
    });
  });

  group('鼠标/键盘与板块模式的边界', () {
    test('focusIntoZone 把状态切回组件模式并归位层级', () {
      final c = BpmZoneFocusController();
      c.enableFocusMode(); // v3.19: 先启用手柄焦点体系
      expect(c.isZoneMode, isTrue);
      c.focusIntoZone(BpmZoneId.homeShelf);
      expect(c.mode, BpmFocusMode.component);
      expect(c.level, BpmFocusLevel.page);
      expect(c.zone, BpmZoneId.homeShelf);
    });

    test('focusIntoZone 对 panel 不做处理 (面板自有生命周期)', () {
      final c = BpmZoneFocusController();
      c.focusIntoZone(BpmZoneId.panel);
      expect(c.zone, BpmZoneId.rail);
      expect(c.mode, BpmFocusMode.zone);
    });

    test('exitZoneMode 只退模式, 不回退层级/板块, 且幂等', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page, zone: BpmZoneId.homeSearch, page: 0);
      c.exitZoneMode();
      expect(c.mode, BpmFocusMode.component);
      expect(c.level, BpmFocusLevel.page);
      expect(c.zone, BpmZoneId.homeSearch);

      var notices = 0;
      c.addListener(() => notices++);
      c.exitZoneMode();
      expect(notices, 0, reason: '已是组件模式 → 不再通知');
    });

    test('focusIntoZone 到一级板块时层级回到 global', () {
      final c = BpmZoneFocusController()
        ..landOnCardList(page: 1)
        ..focusIntoZone(BpmZoneId.topBar);
      expect(c.level, BpmFocusLevel.global);
      expect(c.zone, BpmZoneId.topBar);
      expect(c.mode, BpmFocusMode.component);
    });
  });

  group('详情面板 (覆盖式, 不进板块层级)', () {
    test('openPanel 快照当前层级并独占焦点', () {
      final c = BpmZoneFocusController()
        ..resetForTest(
            level: BpmFocusLevel.page, zone: BpmZoneId.libraryWall, page: 1);
      c.openPanel();
      expect(c.zone, BpmZoneId.panel);
      expect(c.mode, BpmFocusMode.component);
      expect(c.isPanelOpen, isTrue);
      c.closePanel();
      expect(c.zone, BpmZoneId.libraryWall);
      expect(c.level, BpmFocusLevel.page);
    });

    test('面板打开时 B 不由状态机消费 (交 shell 关面板)', () {
      final c = BpmZoneFocusController()..openPanel();
      expect(c.back(), isFalse);
      expect(c.isPanelOpen, isTrue);
    });

    test('面板关闭后回到组件模式 (焦点环恢复)', () {
      final c = BpmZoneFocusController()..openPanel();
      c.closePanel();
      expect(c.mode, BpmFocusMode.component);
    });
  });

  group('通知', () {
    test('状态确实变化才 notifyListeners', () {
      final c = BpmZoneFocusController();
      var count = 0;
      c.addListener(() => count++);

      c.moveZone(TraversalDirection.down); // 无邻接 → 不变
      expect(count, 0);

      c.moveZone(TraversalDirection.up); // rail → topBar
      expect(count, 1);

      c.back(); // 一级板块模式 → 不消费
      expect(count, 1);

      final scope = FocusScopeNode(debugLabel: 'rail');
      c.registerDomain(BpmZoneDomain(
        zone: BpmZoneId.rail,
        scope: scope,
        policy: ReadingOrderTraversalPolicy(),
      ));
      expect(count, 1, reason: '注册焦点域不属于状态转移, 不通知');
      addTearDown(scope.dispose);
    });
  });
}
