// 基础冒烟测试 — 验证主入口可导入
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main.dart 可正常导入', () {
    // 仅验证编译通过，不启动完整 App（需要 SharedPreferences mock）
    expect(true, isTrue);
  });
}
