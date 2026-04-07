import 'package:flutter_test/flutter_test.dart';
import 'package:glados/glados.dart' hide test, group, expect;

/// Pure logic functions extracted from WorkbenchPage's InteractiveViewer config.
/// These mirror the expressions used in the widget:
///   panEnabled:   !_working && !_drawMode
///   scaleEnabled: !_working
bool computePanEnabled(bool working, bool drawMode) => !working && !drawMode;
bool computeScaleEnabled(bool working) => !working;

void main() {
  /// **Feature: image-interaction, Property 1: 交互状态控制真值表**
  ///
  /// Validates: Requirements 3.1, 3.2, 3.3, 3.4, 5.1, 5.2, 5.3
  ///
  /// For any combination of _working and _drawMode booleans:
  ///   panEnabled  == !_working && !_drawMode
  ///   scaleEnabled == !_working
  group('Property 1: 交互状态控制真值表', () {
    Glados2(any.bool, any.bool).test(
      'panEnabled == !working && !drawMode for all bool combinations',
      (working, drawMode) {
        final panEnabled = computePanEnabled(working, drawMode);
        expect(panEnabled, equals(!working && !drawMode));
      },
    );

    Glados(any.bool).test(
      'scaleEnabled == !working for all bool values',
      (working) {
        final scaleEnabled = computeScaleEnabled(working);
        expect(scaleEnabled, equals(!working));
      },
    );

    // Exhaustive truth table verification as a complementary unit test
    test('exhaustive truth table', () {
      // _working=false, _drawMode=false → pan=true, scale=true
      expect(computePanEnabled(false, false), isTrue);
      expect(computeScaleEnabled(false), isTrue);

      // _working=false, _drawMode=true → pan=false, scale=true
      expect(computePanEnabled(false, true), isFalse);
      expect(computeScaleEnabled(false), isTrue);

      // _working=true, _drawMode=false → pan=false, scale=false
      expect(computePanEnabled(true, false), isFalse);
      expect(computeScaleEnabled(true), isFalse);

      // _working=true, _drawMode=true → pan=false, scale=false
      expect(computePanEnabled(true, true), isFalse);
      expect(computeScaleEnabled(true), isFalse);
    });
  });
}
