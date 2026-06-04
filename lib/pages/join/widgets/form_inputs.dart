import 'dart:io';
import 'package:flutter/material.dart';
import '../join_controller.dart';
import '../../../widgets/interactive_wrapper.dart';

class CoverSection extends StatelessWidget {
  final JoinController controller;

  const CoverSection({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final hasCover = controller.coverFilePath != null;

    return InteractiveWrapper(
      onTap: () => controller.pickCover(),
      child: Transform.rotate(
        angle: -0.035,
        child: Container(
          width: 147,
          height: 220,
          decoration: BoxDecoration(
            color: const Color(0xFFE9E0D1),
            border: Border.all(color: const Color(0xFF8B7355), width: 2),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF8B7355),
                  offset: const Offset(4, 5),
                  blurRadius: 0)
            ],
            borderRadius: BorderRadius.circular(4),
          ),
          clipBehavior: Clip.hardEdge,
          child: hasCover
              ? Stack(fit: StackFit.expand, children: [
                  Transform.rotate(
                      angle: 0.035,
                      child: Image.file(File(controller.coverFilePath!),
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover)),
                  Positioned(
                      top: 6,
                      right: 6,
                      child: InteractiveWrapper(
                          onTap: () => controller.removeCover(),
                          hoverScale: 1.1,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(10)),
                            child: Icon(Icons.close_rounded,
                                size: 14, color: Colors.white),
                          )))
                ])
              : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.add, size: 40, color: const Color(0xFF8B7355)),
                  const SizedBox(height: 12),
                  Text('添加封面',
                      style: TextStyle(
                          fontFamily: 'Zhi Mang Xing',
                          fontSize: 20,
                          letterSpacing: 2.0,
                          color: const Color(0xFF8B7355)))
                ]),
        ),
      ),
    );
  }
}

class NameInput extends StatelessWidget {
  final JoinController controller;

  const NameInput({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 67,
      decoration: BoxDecoration(
          color: const Color(0xFFFDFBF7),
          border: Border.all(color: const Color(0xFF8B7355), width: 2),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFF8B7355).withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0)
          ]),
      padding: const EdgeInsets.all(14),
      child: TextField(
        controller: controller.nameController,
        style: TextStyle(
            fontFamily: 'Zhi Mang Xing',
            fontSize: 24,
            letterSpacing: 2.0,
            color: const Color(0xFFC4B3A1)),
        decoration: InputDecoration(
            hintText: '输入名字',
            hintStyle: TextStyle(
                fontFamily: 'Zhi Mang Xing',
                fontSize: 24,
                letterSpacing: 2.0,
                color: const Color(0xFFC4B3A1)),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isDense: true),
        onChanged: (_) => controller.notifyListeners(),
      ),
    );
  }
}

class TagsInput extends StatelessWidget {
  final JoinController controller;

  const TagsInput({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 51,
      decoration: BoxDecoration(
          color: const Color(0xFFFDFBF7),
          border: Border.all(color: const Color(0xFF8B7355), width: 2),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFF8B7355).withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0)
          ]),
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: controller.tagsController,
        style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: const Color(0xFFC4B3A1)),
        decoration: InputDecoration(
            hintText: '标签（如：治愈, 废萌）',
            hintStyle: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFC4B3A1)),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isDense: true),
      ),
    );
  }
}

class DeveloperInput extends StatelessWidget {
  final JoinController controller;

  const DeveloperInput({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 51,
      decoration: BoxDecoration(
          color: const Color(0xFFFDFBF7),
          border: Border.all(color: const Color(0xFF8B7355), width: 2),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFF8B7355).withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0)
          ]),
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: controller.developerController,
        style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: const Color(0xFFC4B3A1)),
        decoration: InputDecoration(
            hintText: '会社（开发商）',
            hintStyle: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFC4B3A1)),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isDense: true),
      ),
    );
  }
}

class DescInput extends StatelessWidget {
  final JoinController controller;

  const DescInput({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 360),
      decoration: BoxDecoration(
          color: const Color(0xFFFDFBF7),
          border: Border.all(color: const Color(0xFF8B7355), width: 2),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFF8B7355).withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0)
          ]),
      padding: const EdgeInsets.all(18),
      child: TextField(
        controller: controller.descController,
        style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: const Color(0xFFC4B3A1)),
        maxLines: null,
        expands: false,
        textAlignVertical: TextAlignVertical.top,
        decoration: InputDecoration(
            hintText: '输入游戏简介...',
            hintStyle: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFC4B3A1)),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isDense: true),
      ),
    );
  }
}
