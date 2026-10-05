import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../big_picture_theme.dart';
import '../../theme/app_styles.dart';
import '../services/bpm_ime_bridge.dart';
import 'bpm_key_cap.dart';

/// BPM 自绘虚拟键盘（v3.19，v3.21 接入系统输入法）—— 纯手柄可完成输入 /
/// 确认 / 关闭，字母数字**走系统 IME（搜狗拼音组词）**。
///
/// 背景：osk.exe / TabTip 是独立系统窗口，手柄输入走 FFI 只到达本进程，
/// **永远操作不了它们** —— 这是「键盘弹出了但手柄没法输入」的根因。
/// 自绘键盘活在 Flutter 树里，手柄焦点可直接在键位间导航。
///
/// v3.21 输入链路（两层）：
/// - **字母 / 数字 / 空格 / 退格** → `BpmImeBridge`（Win32 SendInput 注入
///   **VK 码**）→ 系统输入法（搜狗）拦截组词 → 候选上屏到仍持焦点的
///   输入框。系统为英文输入态时等价直出字母，与旧行为一致；
/// - **符号 / 中文标点** → 仍直接改写 controller（`_type`，不参与拼音）。
///
/// 「中/EN」键 = 轻拍 Shift（常见中文输入法的默认中英切换热键）。
///
/// 交互：
/// - 手柄方向键在键位矩阵中移动（边缘停，BPM 规范第 4 条）；
/// - A = 按下当前键；B（shell 侧）= 关闭键盘；
/// - 鼠标/触摸同样可点（点击即激活该键位）；
/// - 「系统键盘」按钮保留 TabTip 入口（配合物理键盘 IME）。
class BpmVirtualKeyboard extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onClose;
  final VoidCallback onSystemKeyboard;

  const BpmVirtualKeyboard({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onSystemKeyboard,
  });

  @override
  State<BpmVirtualKeyboard> createState() => BpmVirtualKeyboardState();
}

/// 单个键位：文本键（插入字符）或动作键。
class _VkKey {
  final String? label;
  final String? insert;
  final _VkAction? action;

  const _VkKey.text(String s, {String? show})
      : label = show ?? s,
        insert = s,
        action = null;
  const _VkKey.act(this.action, this.label) : insert = null;
}

enum _VkAction {
  caps,
  pageToggle,
  space,
  backspace,
  paste,
  clear,
  confirm,
  systemKb,
  close,
}

class BpmVirtualKeyboardState extends State<BpmVirtualKeyboard> {
  static const List<List<_VkKey>> _letterLayout = [
    [
      _VkKey.text('1'), _VkKey.text('2'), _VkKey.text('3'), _VkKey.text('4'),
      _VkKey.text('5'), _VkKey.text('6'), _VkKey.text('7'), _VkKey.text('8'),
      _VkKey.text('9'), _VkKey.text('0'), _VkKey.text('-', show: '－'),
    ],
    [
      _VkKey.text('q'), _VkKey.text('w'), _VkKey.text('e'), _VkKey.text('r'),
      _VkKey.text('t'), _VkKey.text('y'), _VkKey.text('u'), _VkKey.text('i'),
      _VkKey.text('o'), _VkKey.text('p'),
    ],
    [
      _VkKey.text('a'), _VkKey.text('s'), _VkKey.text('d'), _VkKey.text('f'),
      _VkKey.text('g'), _VkKey.text('h'), _VkKey.text('j'), _VkKey.text('k'),
      _VkKey.text('l'),
    ],
    [
      _VkKey.act(_VkAction.caps, 'Caps'),
      _VkKey.text('z'), _VkKey.text('x'), _VkKey.text('c'), _VkKey.text('v'),
      _VkKey.text('b'), _VkKey.text('n'), _VkKey.text('m'),
      _VkKey.act(_VkAction.backspace, '⌫ 退格'),
    ],
  ];

  static const List<List<_VkKey>> _symbolLayout = [
    [
      _VkKey.text('!'), _VkKey.text('@'), _VkKey.text('#'), _VkKey.text('¥'),
      _VkKey.text('%'), _VkKey.text('^'), _VkKey.text('&'), _VkKey.text('*'),
      _VkKey.text('('), _VkKey.text(')'), _VkKey.text('_'), _VkKey.text('+'),
    ],
    [
      _VkKey.text('~'), _VkKey.text('`'), _VkKey.text('['), _VkKey.text(']'),
      _VkKey.text('{'), _VkKey.text('}'), _VkKey.text('\\'), _VkKey.text('|'),
      _VkKey.text(';'), _VkKey.text(':'), _VkKey.text("'"), _VkKey.text('"'),
    ],
    [
      _VkKey.text('、'), _VkKey.text('，'), _VkKey.text('。'), _VkKey.text('！'),
      _VkKey.text('？'), _VkKey.text('：'), _VkKey.text('；'), _VkKey.text('…'),
      _VkKey.text('—'), _VkKey.text('·'), _VkKey.text('《'), _VkKey.text('》'),
    ],
    [
      _VkKey.text('='), _VkKey.text('<'), _VkKey.text('>'), _VkKey.text('（'),
      _VkKey.text('）'), _VkKey.text('【'), _VkKey.text('】'), _VkKey.text('‘'),
      _VkKey.text('’'), _VkKey.text('“'), _VkKey.text('”'),
      _VkKey.act(_VkAction.backspace, '⌫ 退格'),
    ],
  ];

  bool _symbolPage = false;
  bool _caps = false;
  int _selRow = 0;
  int _selCol = 0;

  List<List<_VkKey>> get _layout =>
      _symbolPage ? _symbolLayout : _letterLayout;

  _VkKey get _currentKey => _layout[_selRow][_selCol];

  // ============ 手柄入口（shell 经 GlobalKey 调用） ============

  void moveFocus(TraversalDirection dir) {
    final rows = _layout;
    int row = _selRow, col = _selCol;
    switch (dir) {
      case TraversalDirection.up:
        row = (row - 1 + rows.length) % rows.length;
        break;
      case TraversalDirection.down:
        row = (row + 1) % rows.length;
        break;
      case TraversalDirection.left:
        col = col - 1;
        if (col < 0) col = rows[row].length - 1;
        break;
      case TraversalDirection.right:
        col = col + 1;
        if (col >= rows[row].length) col = 0;
        break;
    }
    if (col >= rows[row].length) col = rows[row].length - 1;
    setState(() {
      _selRow = row;
      _selCol = col;
    });
  }

  void pressSelected() {
    final key = _currentKey;
    if (key.action != null) {
      _runAction(key.action!);
      return;
    }
    // v3.21: 字母/数字走系统 IME（SendInput 注入 VK → 搜狗拼音组词）；
    // Caps 仅影响字母大小写（Shift 注入），拼音组词不受影响。
    // 非 Windows（测试环境）降级为直插。
    final ch = _caps ? key.insert!.toUpperCase() : key.insert!;
    if (BpmImeBridge.isForwardingSupported && BpmImeBridge.isForwardable(ch)) {
      BpmImeBridge.sendTextAsKeys(ch, shift: _caps);
    } else {
      _type(ch);
    }
    _pulse();
  }

  /// 按键视觉反馈：短暂清零选中再弹回（无动画依赖，纯 setState 抖动）
  void _pulse() => setState(() {});

  // ============ 编辑注入 ============

  void _type(String s) {
    final c = widget.controller;
    final text = c.text;
    final sel = c.selection;
    int start =
        (sel.start >= 0 && sel.start <= text.length) ? sel.start : text.length;
    int end = (sel.end >= start && sel.end <= text.length) ? sel.end : start;
    final newText = text.replaceRange(start, end, s);
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + s.length),
    );
  }

  void _backspace() {
    final c = widget.controller;
    final text = c.text;
    final sel = c.selection;
    if (sel.start >= 0 && sel.end > sel.start && sel.end <= text.length) {
      c.value = TextEditingValue(
        text: text.replaceRange(sel.start, sel.end, ''),
        selection: TextSelection.collapsed(offset: sel.start),
      );
      return;
    }
    if (sel.start > 0 && sel.start <= text.length) {
      int delStart = sel.start - 1;
      // UTF-16 代理对：低代理前面还有高代理时一并删除（emoji 等）
      if (delStart > 0) {
        final cu = text.codeUnitAt(delStart);
        if (cu >= 0xDC00 && cu <= 0xDFFF) delStart--;
      }
      c.value = TextEditingValue(
        text: text.replaceRange(delStart, sel.start, ''),
        selection: TextSelection.collapsed(offset: delStart),
      );
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _type(text);
    _pulse();
  }

  void _runAction(_VkAction action) {
    switch (action) {
      case _VkAction.caps:
        setState(() => _caps = !_caps);
        break;
      case _VkAction.pageToggle:
        setState(() {
          _symbolPage = !_symbolPage;
          _selRow = 0;
          _selCol = 0;
        });
        break;
      case _VkAction.space:
        // v3.21: 走 IME —— 组词态 = 确认当前候选词（原生行为），非组词态 = 空格
        if (BpmImeBridge.isForwardingSupported) {
          BpmImeBridge.sendSpace();
        } else {
          _type(' ');
        }
        _pulse();
        break;
      case _VkAction.backspace:
        // v3.21: 走 IME —— 组词态 = 删拼音字母，非组词态 = 删字符
        if (BpmImeBridge.isForwardingSupported) {
          BpmImeBridge.sendBackspace();
        } else {
          _backspace();
        }
        _pulse();
        break;
      case _VkAction.paste:
        _paste();
        break;
      case _VkAction.clear:
        widget.controller.clear();
        _pulse();
        break;
      case _VkAction.confirm:
      case _VkAction.close:
        widget.onClose();
        break;
      case _VkAction.systemKb:
        widget.onSystemKeyboard();
        break;
    }
  }

  // ============ UI ============

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 160),
        padding: const EdgeInsets.all(14),
        width: 760,
        decoration: BoxDecoration(
          color: BpmColors.deepPanel.withOpacity(0.96),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BpmColors.cherryRoseBorder, width: 1),
          boxShadow: const [
            BoxShadow(color: Color(0xB3000000), blurRadius: 32, spreadRadius: 4),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // v3.21 顶部提示行：手柄导航语义 + 拼音输入说明（总开关关闭不显示）
            if (BpmGuideScope.enabledOf(context)) _buildHintBar(),
            for (int r = 0; r < _layout.length; r++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    for (int c = 0; c < _layout[r].length; c++)
                      _buildKey(r, c, _layout[r].length),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            _buildFunctionRow(),
          ],
        ),
      ),
    );
  }

  /// v3.21 键盘操作提示（一行小字 + 键帽）。
  Widget _buildHintBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
      child: Row(
        children: [
          const BpmKeyCap(BpmKeyCapType.stick, size: 14),
          const SizedBox(width: 3),
          Text('选位', style: kGuideHintStyle),
          const SizedBox(width: 8),
          const BpmKeyCap(BpmKeyCapType.gamepadA, size: 15),
          const SizedBox(width: 3),
          Text('按键', style: kGuideHintStyle),
          const SizedBox(width: 8),
          const BpmKeyCap(BpmKeyCapType.gamepadB, size: 15),
          const SizedBox(width: 3),
          Text('关闭', style: kGuideHintStyle),
          const Spacer(),
          Text('字母数字经系统输入法（拼音组词）', style: kGuideHintStyle),
          const SizedBox(width: 8),
          const BpmKeyCap(BpmKeyCapType.keycap, label: '中/EN', size: 15),
        ],
      ),
    );
  }

  Widget _buildKey(int row, int col, int rowCount) {
    final key = _layout[row][col];
    final selected = row == _selRow && col == _selCol;
    final isCaps = key.action == _VkAction.caps && _caps;
    // 最后一行尾部的退格键给更大的权重
    final int flex = rowCount <= 9 ? 2 : 1;
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          height: 42,
          decoration: BoxDecoration(
            color: selected
                ? BpmColors.selectedAccent.withOpacity(0.30)
                : (isCaps
                    ? BpmColors.selectedAccent.withOpacity(0.16)
                    : BpmColors.deepBase.withOpacity(0.65)),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? BpmColors.selectedAccent
                  : BpmColors.cherryRoseBorder.withOpacity(0.45),
              width: selected ? 1.6 : 1,
            ),
            boxShadow: selected
                ? [BoxShadow(
                    color: BpmColors.selectedAccent.withOpacity(0.35),
                    blurRadius: 12,
                    spreadRadius: 1,
                  )]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                setState(() {
                  _selRow = row;
                  _selCol = col;
                });
                pressSelected();
              },
              child: Center(
                child: Text(
                  key.label ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: selected ? 15.5 : 14.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? Colors.white
                        : BpmColors.textPrimary.withOpacity(0.82),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFunctionRow() {
    return Row(
      children: [
        _fnKey(_symbolPage ? 'ABC' : '#+=', () {
          setState(() {
            _symbolPage = !_symbolPage;
            _selRow = 0;
            _selCol = 0;
          });
        }),
        _fnKey('粘贴', _paste),
        _fnKey('清空', () {
          widget.controller.clear();
          _pulse();
        }),
        // v3.21: 轻拍 Shift 切换输入法中/英文（搜狗等输入法的默认热键）
        _fnKey('中/EN', BpmImeBridge.sendShiftTap),
        _fnKey('系统键盘', widget.onSystemKeyboard),
        _fnKey('关闭', widget.onClose),
      ],
    );
  }

  Widget _fnKey(String label, VoidCallback onTap) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            color: BpmColors.deepBase.withOpacity(0.45),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: BpmColors.cherryRoseBorder.withOpacity(0.35),
              width: 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 13,
                    color: BpmColors.textPrimary.withOpacity(0.75),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
