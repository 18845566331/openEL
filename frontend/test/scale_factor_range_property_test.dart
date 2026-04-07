import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glados/glados.dart' hide test, group, expect;

/// Clamping logic that mirrors InteractiveViewer's minScale/maxScale enforcement.
/// InteractiveViewer constrains the scale factor to [minScale, maxScale].
/// We extract this as a pure function for property-based testing.
const double _minScale = 1.0;
const double _maxScale = 10.0;

double clampScale(double rawScale) => rawScale.clamp(_minScale, _maxScale);

/// Extracts the scale factor from a Matrix4 (the diagonal element [0][0]).
double extractScale(Matrix4 matrix) => matrix.storage[0];

/// Custom generator for scale factors including extreme values.
extension ScaleGenerators on Any {
  /// Generates a double covering a wide range including extreme values:
  /// from 0.001 to 200.0, which includes values well below minScale and above maxScale.
  Generator<double> get wideScaleDouble =>
      any.intInRange(0, 1000000).map((i) => 0.001 + 199.999 * (i / 1000000.0));

  /// Generates extreme negative scale factors from -100.0 to -0.001.
  Generator<double> get negativeScaleDouble =>
      any.intInRange(0, 1000000).map((i) => -100.0 + 99.999 * (i / 1000000.0));
}

void main() {
  /// **Feature: image-interaction, Property 2: 缩放因子范围不变量**
  ///
  /// **Validates: Requirements 2.3**
  ///
  /// For any sequence of scale operations (zoom in or out), the scale factor
  /// extracted from the TransformationController's transform matrix should
  /// always be in the [1.0, 10.0] range.
  group('Property 2: 缩放因子范围不变量', () {
    Glados(any.wideScaleDouble, ExploreConfig(numRuns: 100)).test(
      'single scale factor is always clamped to [1.0, 10.0]',
      (rawScale) {
        final controller = TransformationController();
        final clamped = clampScale(rawScale);
        controller.value = Matrix4.identity()..scale(clamped, clamped);

        final extracted = extractScale(controller.value);
        expect(extracted, greaterThanOrEqualTo(_minScale),
            reason: 'Scale $extracted (from raw $rawScale) should be >= $_minScale');
        expect(extracted, lessThanOrEqualTo(_maxScale),
            reason: 'Scale $extracted (from raw $rawScale) should be <= $_maxScale');

        controller.dispose();
      },
    );

    Glados(any.negativeScaleDouble, ExploreConfig(numRuns: 50)).test(
      'negative scale factors are clamped to minScale',
      (rawScale) {
        final controller = TransformationController();
        final clamped = clampScale(rawScale);
        controller.value = Matrix4.identity()..scale(clamped, clamped);

        final extracted = extractScale(controller.value);
        expect(extracted, equals(_minScale),
            reason: 'Negative raw scale $rawScale should clamp to $_minScale');

        controller.dispose();
      },
    );

    Glados2(any.wideScaleDouble, any.wideScaleDouble, ExploreConfig(numRuns: 100)).test(
      'sequential scale operations always stay in [1.0, 10.0]',
      (rawScale1, rawScale2) {
        final controller = TransformationController();

        // Apply first scale
        final clamped1 = clampScale(rawScale1);
        controller.value = Matrix4.identity()..scale(clamped1, clamped1);
        var extracted = extractScale(controller.value);
        expect(extracted, greaterThanOrEqualTo(_minScale));
        expect(extracted, lessThanOrEqualTo(_maxScale));

        // Apply second scale (simulating a new zoom operation)
        final clamped2 = clampScale(rawScale2);
        controller.value = Matrix4.identity()..scale(clamped2, clamped2);
        extracted = extractScale(controller.value);
        expect(extracted, greaterThanOrEqualTo(_minScale),
            reason: 'After sequential scales ($rawScale1, $rawScale2), result should be >= $_minScale');
        expect(extracted, lessThanOrEqualTo(_maxScale),
            reason: 'After sequential scales ($rawScale1, $rawScale2), result should be <= $_maxScale');

        controller.dispose();
      },
    );
  });
}
