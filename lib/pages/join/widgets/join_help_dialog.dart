import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/interactive_wrapper.dart';

/// 单文件导入「使用说明」弹窗（2026-10-05 需求 #2/#3）。
///
/// 内容对应单文件导入的两大功能：
/// ① 游戏本体导入 —— 选启动程序 → 填数据 → 入库；
/// ② 解压功能 —— 资源获取 → 导入压缩/伪压缩包 → 解压计划设置 →
///    实际解压 → 完成后续，附常见问题。
///
/// 设计基调：轻量卡片 + 紧凑排版，文字简洁、详略得当。
Future<void> showJoinHelpDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const _JoinHelpDialog(),
  );
}

class _JoinHelpDialog extends StatelessWidget {
  const _JoinHelpDialog();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 470,
          constraints: const BoxConstraints(maxHeight: 560),
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 2),
            boxShadow: const [
              BoxShadow(offset: Offset(4, 5), blurRadius: 0, color: Colors.black26),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- 头部 ----
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: AppColors.border, width: 1.4)),
                ),
                child: Row(
                  children: [
                    const Text('使用说明',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    InteractiveWrapper(
                      onTap: () => Navigator.of(context).pop(),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded,
                            size: 16, color: AppColors.secondaryText),
                      ),
                    ),
                  ],
                ),
              ),
              // ---- 内容 ----
              const Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _HelpSectionTitle('一、游戏本体导入'),
                      _HelpStep('1.', '选择游戏的启动程序（.exe 文件），'
                          '或直接把游戏文件夹拖入本页面。'),
                      _HelpStep('2.', '导入后左侧表单会自动预填标题，'
                          '可继续填写/编辑名称、简介、标签、封面等数据。'),
                      _HelpStep('3.', '点「确认入库」完成导入；'
                          '入库后随时可在库页面编辑修改。'),
                      _HelpDivider(),
                      _HelpSectionTitle('二、解压功能（压缩包 / 伪压缩包）'),
                      _HelpStep('1.', '资源获取：社区分享的资源通常是压缩包，'
                          '也可能是改了后缀的「伪压缩包」（如 .mp4 / .exe '
                          '实际是压缩包）——软件按文件内容自动识别真实格式，'
                          '无需手动改名。'),
                      _HelpStep('2.', '导入压缩包：把文件拖入或选择到本页面，'
                          '主按钮会变为「执行解压」，点击即开始。'),
                      _HelpStep('3.', '解压计划设置：弹窗中「设定」板块可预设'
                          '密码组与密码库，「后缀」板块可查看/自定义伪装后缀'
                          '的自动改名链。配置会保存，解压时自动应用'
                          '（右下角「打开解压计划窗口」可随时进入）。'),
                      _HelpStep('4.', '实际解压：填写本次密码（可选用预设密码组）、'
                          '选择解压位置后开始。多层压缩包会自动逐层解压，'
                          '遇到需要密码、多个疑似本体、文件损坏等情况时会'
                          '弹窗询问，按提示操作即可。'),
                      _HelpStep('5.', '解压完成：确认文件夹名（可勾选删除源压缩包）'
                          '后解压流程结束。解压 ≠ 入库——回到本页面自行'
                          '填写数据、点「确认入库」才算导入完成。'),
                      _HelpDivider(),
                      _HelpSectionTitle('常见问题'),
                      _HelpQa('提示密码错误？',
                          '解压会自动尝试历史密码组与预设密码组；'
                          '全失败时弹窗补输，输入正确密码即可继续。'),
                      _HelpQa('解压中断/失败？',
                          '可能缺分卷或下载不完整：补齐文件后点'
                          '「继续重试」；确认放弃则产物会保留在解压位置。'),
                      _HelpQa('解压到哪了？',
                          '默认解压到压缩包所在文件夹，'
                          '也可在实际解压时选择其他位置。'),
                      SizedBox(height: 6),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- 私有小部件 ----------

class _HelpSectionTitle extends StatelessWidget {
  const _HelpSectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.titleBrown)),
    );
  }
}

class _HelpStep extends StatelessWidget {
  const _HelpStep(this.no, this.text);
  final String no;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(no,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.infoBlue)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style:
                    TextStyle(fontSize: 11.5, height: 1.5, color: AppColors.secondaryText)),
          ),
        ],
      ),
    );
  }
}

class _HelpQa extends StatelessWidget {
  const _HelpQa(this.q, this.a);
  final String q;
  final String a;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded,
                  size: 12, color: AppColors.infoBlue),
              const SizedBox(width: 5),
              Expanded(
                child: Text(q,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.secondaryText)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 17, top: 2),
            child: Text(a,
                style: TextStyle(
                    fontSize: 11, height: 1.45, color: AppColors.placeholderText)),
          ),
        ],
      ),
    );
  }
}

class _HelpDivider extends StatelessWidget {
  const _HelpDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Divider(height: 1, color: AppColors.border),
    );
  }
}
