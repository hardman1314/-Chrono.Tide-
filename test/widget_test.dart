// 占位测试文件
//
// 原默认 counter 测试引用不存在的 MyApp,会阻断 `flutter test` 运行。
// 替换为最小可编译占位,保持 test/ 目录结构。
// BPM 相关组件的测试位于 test/big_picture/。

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder', () {
    expect(true, isTrue);
  });
}
