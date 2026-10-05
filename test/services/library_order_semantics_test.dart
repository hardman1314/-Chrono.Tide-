// 库页显示顺序语义 · Phase 0 技术验证
//
// 锁死两条语义（方案文档 §4.1）：
// 1. 「渲染列表 = 操作列表」——重排只作用在传入的显示列表上，返回新列表；
// 2. 「视图隔离」——收藏夹 / 搜索 / 筛选视图下的拖拽**不得**改动全局顺序，
//    该守卫由 `resolveGlobalOrderAfterDrag` 在 API 层强制，
//    使 P0（筛选视图拖拽写乱全局手动顺序）在构造上不可能再发生。

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/utils/library_order_utils.dart';

void main() {
  group('T0-2 重排语义', () {
    test('插入式：向下移动，目标索引左移一位', () {
      final result = insertDisplayItem(['A', 'B', 'C', 'D'], 0, 2);
      // 移除 A 后为 [B,C,D]，原目标 2 左移为 1 → [B,A,C,D]
      expect(result, ['B', 'A', 'C', 'D']);
    });

    test('插入式：向上移动', () {
      final result = insertDisplayItem(['A', 'B', 'C', 'D'], 3, 1);
      expect(result, ['A', 'D', 'B', 'C']);
    });

    test('插入式：移动到最后一位', () {
      final result = insertDisplayItem(['A', 'B', 'C'], 0, 3);
      expect(result, ['B', 'C', 'A']);
    });

    test('插入式：原位（to == from）内容不变', () {
      final src = ['A', 'B', 'C'];
      expect(insertDisplayItem(src, 1, 1), src);
    });

    test('插入式：负数目标被收敛为 0（防御）', () {
      expect(insertDisplayItem(['A', 'B', 'C'], 2, -1), ['C', 'A', 'B']);
    });

    test('交换式：两位置互换', () {
      expect(swapDisplayItems(['A', 'B', 'C'], 0, 2), ['C', 'B', 'A']);
    });

    test('交换式：相同索引内容不变', () {
      final src = ['A', 'B'];
      expect(swapDisplayItems(src, 1, 1), src);
    });

    test('越界索引被忽略，内容不变（防御）', () {
      final src = ['A', 'B'];
      expect(swapDisplayItems(src, 0, 9), src);
      expect(insertDisplayItem(src, 9, 0), src);
      expect(insertDisplayItem([], 0, 0), isEmpty);
    });

    test('不修改入参（不可变性）', () {
      final src = ['A', 'B', 'C'];
      insertDisplayItem(src, 0, 2);
      swapDisplayItems(src, 0, 2);
      reorderDisplayList(src, 0, 2);
      expect(src, ['A', 'B', 'C'], reason: '调用方列表不得被就地改动');
    });

    test('统一入口按模式分派', () {
      // swap：0 与 2 互换
      expect(
        reorderDisplayList(['A', 'B', 'C'], 0, 2,
            mode: DisplayReorderMode.swap),
        ['C', 'B', 'A'],
      );
      // insert：to 表示"插入到原列表该索引的元素之前"，故 from=0,to=2
      // 移除 A 后目标左移为 1 → [B, A, C]（与库页原 _endDrag 语义一致）
      expect(
        reorderDisplayList(['A', 'B', 'C'], 0, 2,
            mode: DisplayReorderMode.insert),
        ['B', 'A', 'C'],
      );
      // to == length 才是"移动到末尾"
      expect(
        reorderDisplayList(['A', 'B', 'C'], 0, 3,
            mode: DisplayReorderMode.insert),
        ['B', 'C', 'A'],
      );
      expect(
        reorderDisplayList(['A', 'B', 'C'], 0, 2,
            mode: DisplayReorderMode.insert),
        insertDisplayItem(['A', 'B', 'C'], 0, 2),
        reason: '统一入口默认模式应与 insertDisplayItem 等价',
      );
    });

    test('属性：随机重排后长度与元素集合不变', () {
      final rng = Random(20260914);
      for (var i = 0; i < 200; i++) {
        final n = 1 + rng.nextInt(20);
        final src = List<String>.generate(n, (k) => 'g$k');
        final from = rng.nextInt(n);
        final to = rng.nextInt(n + 1);
        for (final mode in DisplayReorderMode.values) {
          final out = reorderDisplayList(src, from, to, mode: mode);
          expect(out.length, n, reason: '长度必须守恒');
          expect(out.toSet(), src.toSet(), reason: '元素集合必须守恒');
          expect(src, List<String>.generate(n, (k) => 'g$k'),
              reason: '入参不得被修改');
        }
      }
    });
  });

  group('T0-2 门控矩阵', () {
    ReorderTarget resolve({
      bool manualSort = true,
      bool hasSearch = false,
      bool hasDeveloperFilter = false,
      bool inCollection = false,
      bool collectionReorderEnabled = true,
    }) =>
        resolveReorderTarget(
          manualSort: manualSort,
          hasSearch: hasSearch,
          hasDeveloperFilter: hasDeveloperFilter,
          inCollection: inCollection,
          collectionReorderEnabled: collectionReorderEnabled,
        );

    test('全部视图 + 手动序 + 无筛选 → 写全局顺序', () {
      expect(resolve(), ReorderTarget.globalOrder);
    });

    test('非手动排序 → 不响应（即使无筛选）', () {
      expect(resolve(manualSort: false), ReorderTarget.none);
      expect(resolve(manualSort: false, inCollection: true),
          ReorderTarget.none);
    });

    test('搜索激活 → 不响应', () {
      expect(resolve(hasSearch: true), ReorderTarget.none);
    });

    test('会社筛选激活 → 不响应', () {
      expect(resolve(hasDeveloperFilter: true), ReorderTarget.none);
    });

    test('收藏夹视图 + 能力已启用 → 写收藏夹内顺序', () {
      expect(resolve(inCollection: true), ReorderTarget.collectionOrder);
    });

    test('收藏夹视图 + 能力未启用（分阶段落地期间）→ 不响应', () {
      expect(
        resolve(inCollection: true, collectionReorderEnabled: false),
        ReorderTarget.none,
      );
    });

    test('收藏夹视图 + 搜索 → 仍不响应（搜索优先级更高）', () {
      expect(resolve(inCollection: true, hasSearch: true),
          ReorderTarget.none);
    });
  });

  group('Phase 3 收藏夹内顺序 applyCollectionOrder', () {
    List<String> reorder(List<String> members, List<String> order) =>
        applyCollectionOrder(members, order, keyOf: (e) => e);

    test('已登记成员按 order 排列', () {
      expect(reorder(['A', 'B', 'C'], ['C', 'A', 'B']), ['C', 'A', 'B']);
    });

    test('未登记者排在已登记者之后，且保持传入时的相对次序', () {
      // members 顺序 A,B,C,D；order 只登记了 C,A → 结果 C,A,B,D
      expect(reorder(['A', 'B', 'C', 'D'], ['C', 'A']), ['C', 'A', 'B', 'D']);
    });

    test('order 中的未知键被忽略（游戏已移出收藏夹/已删除）', () {
      expect(reorder(['A', 'B'], ['X', 'B', 'A']), ['B', 'A']);
    });

    test('order 中的重复键只取首次出现的位置', () {
      expect(reorder(['A', 'B', 'C'], ['B', 'B', 'A']), ['B', 'A', 'C']);
    });

    test('空 order（未自定义）→ 原样返回传入顺序', () {
      expect(reorder(['A', 'B'], []), ['A', 'B']);
    });

    test('不修改入参', () {
      final members = ['A', 'B', 'C'];
      final order = ['C', 'A', 'B'];
      applyCollectionOrder(members, order, keyOf: (e) => e);
      expect(members, ['A', 'B', 'C']);
      expect(order, ['C', 'A', 'B']);
    });

    test('属性：元素集合守恒 + 未登记成员相对次序不变（随机 200 组）', () {
      final rng = Random(20260915);
      for (var i = 0; i < 200; i++) {
        final n = 2 + rng.nextInt(12);
        final members = List<String>.generate(n, (k) => 'g$k');
        final registeredCount = rng.nextInt(n + 1);
        final registered =
            members.take(registeredCount).toList()..shuffle(rng);
        // 允许掺入未知键（模拟已移出收藏夹的残留）
        final order = [...registered, if (rng.nextBool()) 'ghost'];

        final out = applyCollectionOrder(members, order, keyOf: (e) => e);
        expect(out.length, n);
        expect(out.toSet(), members.toSet());
        expect(members, List<String>.generate(n, (k) => 'g$k'),
            reason: '入参不得被修改');

        // 未登记成员之间的相对次序 = 它们在 members 中的原次序
        final registeredSet = registered.toSet();
        final unregisteredIn = members
            .where((e) => !registeredSet.contains(e))
            .toList();
        final unregisteredOut = out
            .where((e) => !registeredSet.contains(e))
            .toList();
        expect(unregisteredOut, unregisteredIn,
            reason: '未登记的成员不得互相换位');
      }
    });
  });

  group('T0-2 视图隔离守卫', () {
    test('目标非 globalOrder 时，全局顺序原样返回（P0 回归锁）', () {
      final global = ['A', 'B', 'C', 'D'];
      final reorderedDisplay = ['C', 'A'];

      for (final target in [
        ReorderTarget.none,
        ReorderTarget.collectionOrder,
      ]) {
        final after = resolveGlobalOrderAfterDrag(
          globalList: global,
          reorderedDisplay: reorderedDisplay,
          target: target,
        );
        expect(after, global, reason: '$target 下全局顺序绝不允许被改动');
      }
    });

    test('目标为 globalOrder 时，采用显示列表的新顺序', () {
      final after = resolveGlobalOrderAfterDrag(
        globalList: ['A', 'B', 'C', 'D'],
        reorderedDisplay: ['B', 'A', 'C', 'D'],
        target: ReorderTarget.globalOrder,
      );
      expect(after, ['B', 'A', 'C', 'D']);
    });

    test('属性：随机组合下，非 globalOrder 目标永不改动全局顺序', () {
      final rng = Random(20260914);
      final global = List<String>.generate(12, (k) => 'g$k');
      for (var i = 0; i < 200; i++) {
        final target = ReorderTarget.values[rng.nextInt(3)];
        // 模拟"显示列表"是全局列表的任意子集重排（搜索/收藏夹视图的真实形态）
        final subset = global.where((_) => rng.nextBool()).toList();
        final shuffled = List<String>.from(subset)..shuffle(rng);
        final after = resolveGlobalOrderAfterDrag(
          globalList: global,
          reorderedDisplay: shuffled,
          target: target,
        );
        if (target == ReorderTarget.globalOrder) {
          expect(after, shuffled);
        } else {
          expect(after, global,
              reason: 'target=$target 时全局顺序必须逐元素不变');
        }
      }
    });
  });
}
