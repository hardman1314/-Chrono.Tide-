import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

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

class _ExitWaitingWidgetState extends State<_ExitWaitingWidget>
    with TickerProviderStateMixin {
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();

    _rotationController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFDFBF7),
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
              AnimatedBuilder(
                animation: _rotationController,
                builder: (context, child) {
                  return Transform.rotate(
                    angle: _rotationController.value * 6.28318,
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(
                        strokeWidth: 4,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          const Color(0xFF8B7355),
                        ),
                        backgroundColor:
                            const Color(0xFF8B7355).withOpacity(0.15),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 28),
              const Text(
                '正在退出',
                style: TextStyle(
                  fontFamily: 'Zhi Mang Xing',
                  fontSize: 22,
                  letterSpacing: 2,
                  color: Color(0xFF8B7355),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '请稍候…',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF6D5B4D),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '程序正在清理资源并安全关闭',
                style: TextStyle(
                  fontFamily: 'Mali',
                  fontSize: 13,
                  color: const Color(0xFF8B7355).withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
