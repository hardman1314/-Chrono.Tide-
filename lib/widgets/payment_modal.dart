import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../core/backend_config.dart';
import '../theme/app_colors.dart';
import 'interactive_wrapper.dart';

enum PaymentMode { select, qr }

class PaymentModal extends StatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onBack;
  const PaymentModal({super.key, required this.onClose, required this.onBack});

  @override
  State<PaymentModal> createState() => _PaymentModalState();
}

class _PaymentModalState extends State<PaymentModal> {
  PaymentMode _mode = PaymentMode.select;
  int _selectedAmount = 5;
  bool _closeHovered = false;
  static const List<int> _amounts = [1, 5, 15];

  void _goToQR() {
    setState(() => _mode = PaymentMode.qr);
  }

  void _goBack() {
    setState(() => _mode = PaymentMode.select);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child:
            _mode == PaymentMode.select ? _buildSelectModal() : _buildQRModal(),
      ),
    );
  }

  Widget _buildSelectModal() {
    return Container(
      width: 420,
      height: 360,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(color: AppColors.border, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: AppColors.border,
            offset: const Offset(6, 8),
            blurRadius: 0,
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 40, 28, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSelectHeader(),
                const SizedBox(height: 20),
                _buildSelectSubtitle(),
                const SizedBox(height: 28),
                _buildAmountButtons(),
                const SizedBox(height: 28),
                _buildConfirmButton(),
              ],
            ),
          ),
          Positioned(
            top: 16,
            right: 14,
            child: _buildCloseButton(),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        SvgPicture.asset('assets/images/payment_charge_icon.svg',
            width: 28, height: 28),
        const SizedBox(width: 12),
        Text(
          '选择赞赏金额',
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w700,
            fontSize: 26,
            height: 32 / 26,
            color: AppColors.dangerRed,
          ),
        ),
      ],
    );
  }

  Widget _buildSelectSubtitle() {
    return SizedBox(
      width: double.infinity,
      child: Text(
        '你的支持是对纯爱世界最大的鼓励！(๑•̀ㅂ•́)و✧',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w700,
          fontSize: 16,
          height: 24 / 16,
          color: AppColors.primaryText,
        ),
      ),
    );
  }

  Widget _buildAmountButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: _amounts.map((amount) {
        final isSelected = _selectedAmount == amount;
        return Padding(
          padding: EdgeInsets.only(left: amount == 1 ? 0 : 12),
          child: InteractiveWrapper(
            onTap: () => setState(() => _selectedAmount = amount),
            child: Container(
              width: 110,
              height: 60,
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFFFFB6C1)
                    : AppColors.sidebarBackground,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected ? AppColors.dangerRed : AppColors.border,
                  width: 1.6,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isSelected ? AppColors.dangerRed : AppColors.border,
                    offset: const Offset(2, 3),
                    blurRadius: 0,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                '¥$amount',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  height: 28 / 20,
                  color: isSelected ? AppColors.dangerRed : AppColors.border,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildConfirmButton() {
    return InteractiveWrapper(
      onTap: _goToQR,
      child: Container(
        width: double.infinity,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFFFFE6EA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.dangerRed, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: AppColors.dangerRed,
              offset: const Offset(2, 3),
              blurRadius: 0,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset('assets/images/payment_heart_icon.svg',
                width: 20, height: 20),
            const SizedBox(width: 8),
            Text(
              '确认赞赏 (¥$_selectedAmount)',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w700,
                fontSize: 18,
                height: 28 / 18,
                color: AppColors.dangerRed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQRModal() {
    return Container(
      width: 420,
      height: 520,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(color: AppColors.border, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: AppColors.border,
            offset: const Offset(6, 8),
            blurRadius: 0,
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 40, 28, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildQRHeader(),
                const SizedBox(height: 20),
                _buildQRAmountRow(),
                const SizedBox(height: 24),
                _buildQRCodeArea(),
                const SizedBox(height: 24),
                _buildQRBottom(),
              ],
            ),
          ),
          Positioned(
            top: 16,
            left: 14,
            child: _buildBackButton(),
          ),
          Positioned(
            top: 16,
            right: 14,
            child: _buildCloseButton(),
          ),
        ],
      ),
    );
  }

  Widget _buildQRHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: 0.5,
          child: SvgPicture.asset('assets/images/payment_sparkle_icon.svg',
              width: 24, height: 24),
        ),
        const SizedBox(width: 12),
        Text(
          '感谢你的支持',
          style: TextStyle(
            fontFamily: 'ZhiMangXing',
            fontSize: 36,
            height: 40 / 36,
            letterSpacing: 2.0,
            color: AppColors.dangerRed,
          ),
        ),
        const SizedBox(width: 12),
        Opacity(
          opacity: 0.5,
          child: SvgPicture.asset('assets/images/payment_sparkle_icon.svg',
              width: 24, height: 24),
        ),
      ],
    );
  }

  Widget _buildQRAmountRow() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '本次赞赏金额',
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            fontSize: 16,
            height: 24 / 16,
            color: AppColors.primaryText,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '¥$_selectedAmount',
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w800,
            fontSize: 36,
            height: 44 / 36,
            color: AppColors.dangerRed,
          ),
        ),
      ],
    );
  }

  Widget _buildQRCodeArea() {
    return Container(
      width: 224,
      height: 224,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.6),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: const Color(0x338B7355),
            offset: const Offset(2, 3),
            blurRadius: 0,
          ),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.asset(
          'assets/images/reward_default.png',
          width: 200,
          height: 200,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            debugPrint('[PAYMENT] ❌ 赞赏码图片加载失败: $error');
            return Container(
              color: AppColors.background,
              child: Center(
                child: Text(
                  '图片加载失败',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: AppColors.secondaryText,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildQRBottom() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        '请用微信扫码，手动输入对应金额完成赞赏',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w500,
          fontSize: 14,
          height: 20 / 14,
          color: AppColors.secondaryText,
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _closeHovered = true),
      onExit: (_) => setState(() => _closeHovered = false),
      child: GestureDetector(
        onTap: widget.onClose,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            color: _closeHovered
                ? AppColors.primaryText.withOpacity(0.1)
                : AppColors.background,
            border: Border.all(
              color: _closeHovered
                  ? AppColors.border
                  : AppColors.border.withOpacity(0.5),
              width: _closeHovered ? 2 : 1.6,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: _closeHovered ? const Offset(1, 2) : const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.close,
            size: 18,
            color:
                _closeHovered ? AppColors.primaryText : AppColors.secondaryText,
          ),
        ),
      ),
    );
  }

  Widget _buildBackButton() {
    return InteractiveWrapper(
      onTap: widget.onBack ?? _goBack,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.background,
        ),
        alignment: Alignment.center,
        child: SvgPicture.asset('assets/images/payment_back_icon.svg',
            width: 18, height: 18),
      ),
    );
  }
}
