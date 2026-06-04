import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_colors.dart';
import 'interactive_wrapper.dart';

class DiscoverDisclaimerDialog extends StatefulWidget {
  final VoidCallback onAgreed;

  const DiscoverDisclaimerDialog({super.key, required this.onAgreed});

  static const String _storageKey = 'discover_disclaimer_agreed';

  static Future<bool> hasAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_storageKey) ?? false;
  }

  static Future<void> markAsAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, true);
  }

  static void showIfNeeded({
    required BuildContext context,
    required VoidCallback onAgreed,
  }) async {
    final agreed = await hasAgreed();
    if (!agreed && context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => DiscoverDisclaimerDialog(
          onAgreed: () {
            Navigator.of(ctx).pop();
            onAgreed();
          },
        ),
      );
    }
  }

  @override
  State<DiscoverDisclaimerDialog> createState() =>
      _DiscoverDisclaimerDialogState();
}

class _DiscoverDisclaimerDialogState extends State<DiscoverDisclaimerDialog> {
  bool _agreed = false;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border, width: 1.5),
      ),
      child: Container(
        width: 600,
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Flexible(
                child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(28, 0, 28, 8),
                    child: _buildBody())),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE9E0D1), width: 1)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 24, color: AppColors.border),
          SizedBox(width: 10),
          Text(
            '探索页功能说明',
            style: TextStyle(
              fontFamily: 'Zhi Mang Xing',
              fontSize: 20,
              letterSpacing: 1.2,
              color: AppColors.border,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '探索页为圈内玩家共建的游戏作品资讯汇总板块，收录全网公开流传的游戏作品基础资讯，包含作品封面、名称、题材标签、剧情简介内容，方便圈内同好快速查阅、寻找心仪作品。',
          style: TextStyle(
              fontFamily: 'Mali',
              fontSize: 14,
              color: AppColors.primaryText,
              height: 1.7),
        ),
        SizedBox(height: 12),
        _buildBullet('页面仅汇总对外公开流通的作品，软件不存储、托管任何游戏本体程序文件；'),
        _buildBullet('内置搜索栏，可输入名称或标签关键词，便于玩家自行寻找对应作品；'),
        _buildBullet(
            '收录的作品大多已完成汉化，所有汉化内容版权归对应民间汉化组所有，由衷感谢各大汉化组无偿为爱产出汉化内容，推动圈内作品交流传播；'),
        SizedBox(height: 4),
        Padding(
          padding: EdgeInsets.only(left: 12),
          child: Text(
            '软件核心定位是本地游戏收藏库管理工具，希望大家喜欢。',
            style: TextStyle(
                fontFamily: 'Mali',
                fontSize: 14,
                color: AppColors.primaryText,
                height: 1.7),
          ),
        ),
        SizedBox(height: 20),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border:
                Border(left: BorderSide(color: Color(0xFFD4183D), width: 3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined, size: 18, color: Color(0xFFD4183D)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '免责须知',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFD4183D),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        Text(
          '探索页面向圈内爱好者打造，仅整理网络公开流传的圈内作品资讯，页面展示内容均来自每位善良网友的公开分享，软件不参与作品原版传播、分享行为。',
          style: TextStyle(
              fontFamily: 'Mali',
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.75),
        ),
        SizedBox(height: 8),
        Text(
          '圈内作品的获取、游玩行为均由使用者个人自主决定，如有能力请转正。软件仅提供信息查阅与本地收藏管理的辅助能力，开发者不会干预、引导用户获取各类作品。',
          style: TextStyle(
              fontFamily: 'Mali',
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.75),
        ),
        SizedBox(height: 8),
        Text(
          '使用者需自行评判所接触作品的合规性，因个人游玩、使用作品引发的圈内纠纷、各类问题，均由使用者本人自行承担，软件作者不负相关责任。',
          style: TextStyle(
              fontFamily: 'Mali',
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.75),
        ),
        SizedBox(height: 8),
        Text(
          '若圈内创作者、相关人员认为页面展示资讯存在不妥，可通过卡片举报入口反馈，我方会及时下架对应作品条目。',
          style: TextStyle(
              fontFamily: 'Mali',
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.75),
        ),
      ],
    );
  }

  Widget _buildBullet(String text) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: EdgeInsets.only(top: 9),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
                color: AppColors.secondaryText, shape: BoxShape.circle),
          ),
          SizedBox(width: 12),
          Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontFamily: 'Mali',
                      fontSize: 14,
                      color: AppColors.primaryText,
                      height: 1.7))),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFE9E0D1), width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InteractiveWrapper(
            onTap: () => setState(() => _agreed = !_agreed),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                        color: _agreed
                            ? AppColors.border
                            : AppColors.secondaryText,
                        width: 1.5),
                    color: _agreed ? AppColors.border : Colors.transparent,
                  ),
                  child: _agreed
                      ? Icon(Icons.check, size: 14, color: Colors.white)
                      : null,
                ),
                SizedBox(width: 10),
                Flexible(
                  child: Text(
                    '勾选同意即代表理解圈内交流规则，自愿使用本探索功能。',
                    style: TextStyle(
                        fontFamily: 'Mali',
                        fontSize: 13.5,
                        color: AppColors.primaryText),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 16),
          InteractiveWrapper(
            onTap: _agreed ? _handleConfirm : null,
            cursor: _agreed
                ? SystemMouseCursors.click
                : SystemMouseCursors.forbidden,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 40, vertical: 11),
              decoration: BoxDecoration(
                color: _agreed ? AppColors.border : Color(0xFFD0C4B8),
                borderRadius: BorderRadius.circular(6),
                boxShadow: _agreed
                    ? <BoxShadow>[
                        BoxShadow(
                            color: AppColors.border.withOpacity(0.15),
                            offset: Offset(0, 2),
                            blurRadius: 6)
                      ]
                    : null,
              ),
              child: Text(
                '进入探索页',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _agreed ? Colors.white : Color(0xFFA08264),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleConfirm() {
    if (!_agreed) return;
    DiscoverDisclaimerDialog.markAsAgreed();
    widget.onAgreed();
  }
}
