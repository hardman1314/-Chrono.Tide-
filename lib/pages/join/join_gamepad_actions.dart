// ============================================================================
// JoinPage 交给「BPM 手柄操作条」的动作集合（v3.10.3）
//
// 🔴 为什么需要这个中间类型：
//
// JoinPage 及其复用的全部桌面控件（文件拖放区、确认入库、取消…）建立在
// `lib/widgets/interactive_wrapper.dart` 的 `InteractiveWrapper` / `HoverButton`
// 之上，而那个基座里**一个 `Focus` 都没有** —— 它只处理鼠标 hover / tap，
// 完全不在 Flutter 焦点树里。于是手柄侧的 `findFirstFocus` 与 `inDirection`
// 根本"看不见"这些控件：BPM 里用手柄打开导入窗口后，除了 TextField 之外无处
// 可落焦，「确认入库」「选择文件」都按不到。
//
// 解法有两条：
//   A. 给 `InteractiveWrapper` 本体加焦点支持 —— 它有数十处桌面调用，
//      且会插入边框容器影响既有布局（MEMORY §11 明确禁止改本体）；
//   B. 让 JoinPage 把它**已有的**动作交出来，由 BPM 渲染一条可聚焦的操作条。
//
// 选 B。本文件就是 B 的契约：BPM 只用这些回调，**不复制任何业务逻辑**
// （校验、状态、二次确认都仍在 JoinPage 内部，保证与桌面按钮同一条路径）。
// ============================================================================

import 'join_controller.dart';
import 'batch_import_controller.dart';
import 'widgets/swipe_switcher.dart' show ImportMode;

/// JoinPage 暴露给 BPM 手柄操作条的动作与状态句柄。
///
/// 所有字段都是 JoinPage **自己持有的实例/方法引用**（不是副本），
/// 因此手柄操作与桌面操作在小到状态、大到入库链路上完全一致。
class JoinGamepadActions {
  const JoinGamepadActions({
    required this.mode,
    required this.single,
    required this.batch,
    required this.submitBatch,
    required this.cancel,
  });

  /// 当前导入模式（决定操作条显示单文件还是批量的一组按钮）
  final ImportMode mode;

  /// 单文件表单控制器（`pickFile` / `submitAddGame` / `canSubmit` /
  /// `clearFileSelection` / `selectedFilePath` 等均在此）
  final JoinController single;

  /// 批量控制器（`pickFolders` / `hasGames` / `isProcessingQueue` /
  /// `submitBatchImport` / `clearAll` 等均在此）
  ///
  /// ⚠️ BPM 侧传入的是 MainContainer 持有的**全局**控制器，
  /// 与桌面模式同源（切页不丢批量队列）。
  final BatchImportController batch;

  /// 批量入库。等价于桌面「批量入库」按钮 —— 含「先保存当前编辑」
  /// 与 IMP-09 的两道守卫（无游戏 / 抓取队列仍在跑），**不要绕开它**直接调
  /// `batch.submitBatchImport()`，否则会丢掉用户正在编辑的那一份改动。
  final Future<void> Function() submitBatch;

  /// 取消 / 清空（带二次确认），等价于桌面「取消」按钮。
  final Future<void> Function() cancel;
}
