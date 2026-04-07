import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glados/glados.dart' hide test, group, expect;
import 'package:vector_math/vector_math_64.dart' as vm;

/// Pure coordinate conversion functions extracted from WorkbenchPage.
/// These mirror the exact math used in the widget without any widget dependency.

/// Forward: normalized coords → screen coords
/// Given an image rect [ir], normalized coords [norm], and a transform [matrix],
/// maps norm to canvas position then applies the forward matrix.
Offset normToScreen(Rect ir, Offset norm, Matrix4 matrix) {
  final canvasPos = Offset(
    ir.left + norm.dx * ir.width,
    ir.top + norm.dy * ir.height,
  );
  return MatrixUtils.transformPoint(matrix, canvasPos);
}

/// Inverse: screen coords → normalized coords
/// Given an image rect [ir], screen coords [screenPos], and a transform [matrix],
/// applies the inverse matrix then computes normalized coords.
Offset screenToNorm(Rect ir, Offset screenPos, Matrix4 matrix) {
  final inverseMatrix = Matrix4.inverted(matrix);
  final untransformed = MatrixUtils.transformPoint(inverseMatrix, screenPos);
  return Offset(
    (untransformed.dx - ir.left) / ir.width,
    (untransformed.dy - ir.top) / ir.height,
  );
}

/// Custom generators for coordinate roundtrip testing.
extension CoordinateGenerators on Any {
  /// Generates a double in [0, 1] range for normalized coordinates.
  Generator<double> get unitDouble =>
      any.intInRange(0, 1000000).map((i) => i / 1000000.0);

  /// Generates a double in [1.0, 10.0] range for scale factors.
  Generator<double> get scaleDouble =>
      any.intInRange(0, 1000000).map((i) => 1.0 + 9.0 * (i / 1000000.0));

  /// Generates a double in [-200, 200] range for translation offsets.
  Generator<double> get translationDouble =>
      any.intInRange(0, 1000000).map((i) => -200.0 + 400.0 * (i / 1000000.0));
}

void main() {
  // Fixed image rect for simplicity, as specified in the task
  final imageRect = Rect.fromLTWH(50, 30, 400, 300);

  /// **Feature: image-interaction, Property 3: 坐标转换往返一致性**
  ///
  /// **Validates: Requirements 5.4**
  ///
  /// For any valid transform matrix (scale in [1.0, 10.0]) and any normalized
  /// coordinate (x, y in [0, 1]), the roundtrip norm → screen → norm should
  /// equal the original within 1e-6 precision.
  group('Property 3: 坐标转换往返一致性', () {
    // Use combine to build a composite input: (normX, normY, scaleX, scaleY, tx, ty)
    final generator = any.combine2(
      // Normalized offset as (dx, dy)
      any.combine2(any.unitDouble, any.unitDouble,
          (double dx, double dy) => Offset(dx, dy)),
      // Transform matrix parameters: (scaleX, scaleY, translateX, translateY)
      any.combine2(
        any.combine2(any.scaleDouble, any.scaleDouble,
            (double sx, double sy) => [sx, sy]),
        any.combine2(any.translationDouble, any.translationDouble,
            (double tx, double ty) => [tx, ty]),
        (List<double> scales, List<double> translations) {
          final m = Matrix4.identity();
          m.scale(scales[0], scales[1]);
          m.setTranslation(
              vm.Vector3(translations[0], translations[1], 0));
          return m;
        },
      ),
      (Offset norm, Matrix4 matrix) => [norm, matrix],
    );

    Glados(generator, ExploreConfig(numRuns: 100)).test(
      'norm → screen → norm roundtrip preserves coordinates within 1e-6',
      (input) {
        final norm = input[0] as Offset;
        final matrix = input[1] as Matrix4;

        // Forward: norm → screen
        final screen = normToScreen(imageRect, norm, matrix);

        // Inverse: screen → norm
        final recovered = screenToNorm(imageRect, screen, matrix);

        // Verify roundtrip consistency within 1e-6
        expect(recovered.dx, closeTo(norm.dx, 1e-6),
            reason:
                'dx mismatch: original=${norm.dx}, recovered=${recovered.dx}');
        expect(recovered.dy, closeTo(norm.dy, 1e-6),
            reason:
                'dy mismatch: original=${norm.dy}, recovered=${recovered.dy}');
      },
    );
  });
}
