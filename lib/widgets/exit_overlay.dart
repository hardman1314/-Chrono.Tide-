import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class ExitOverlay {
  static OverlayEntry? _overlayEntry;
  static bool _isShowing = false;

  static void show(BuildContext context) {
    if (_isShowing) return;
    _isShowing = true;

    _overlayEntry = OverlayEntry(
      builder: (context) => const _ExitWaitingWidget(),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  static void hide() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
      _isShowing = false;
    }
  }

  static bool get isShowing => _isShowing;
}

class _ExitWaitingWidget extends StatefulWidget {
  const _ExitWaitingWidget();

  @override
  State<_ExitWaitingWidget> createState() => _ExitWaitingWidgetState();
}

class _ExitWaitingWidgetState extends State<_ExitWaitingWidget> {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // UX-29: 移除容器旋转动画，仅保留 CircularProgressIndicator 自转
              SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.border,
                  ),
                  backgroundColor: AppColors.border.withOpacity(0.15),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                '正在退出',
                style: TextStyle(
                  fontSize: 22,
                  letterSpacing: 2,
                  color: AppColors.border,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '请稍候…',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '程序正在清理资源并安全关闭',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.border.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
