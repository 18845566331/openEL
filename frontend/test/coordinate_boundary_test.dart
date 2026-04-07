import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure math extraction of `_containerToNorm` from WorkbenchPage.
/// Mirrors the exact logic: inverse-transform the screen point, then
/// compute normalized coords relative to [ir], clamped to [0, 1].
Offset containerToNorm(Rect ir, Offset localPos, Matrix4 matrix) {
  final inverseMatrix = Matrix4.inverted(matrix);
  final untransformed = MatrixUtils.transformPoint(inverseMatrix, localPos);
  return Offset(
    ((untransformed.dx - ir.left) / ir.width).clamp(0, 1),
    ((untransformed.dy - ir.top) / ir.height).clamp(0, 1),
  );
}

void main() {
  // Fixed image rect as specified in the task
  final imageRect = Rect.fromLTWH(50, 30, 400, 300);
  final identity = Matrix4.identity();

  /// **Validates: Requirements 5.4**
  ///
  /// Boundary value tests for coordinate conversion clamping and
  /// identity-matrix behaviour.
  group('坐标转换边界值 (Coordinate boundary values)', () {
    // --- Clamp tests: screen coords outside image rect ---

    test('screen coord far left of image rect → dx clamped to 0', () {
      // x = -100 is well left of ir.left (50)
      final result = containerToNorm(imageRect, const Offset(-100, 180), identity);
      expect(result.dx, 0.0);
    });

    test('screen coord far right of image rect → dx clamped to 1', () {
      // x = 600 is well right of ir.right (450)
      final result = containerToNorm(imageRect, const Offset(600, 180), identity);
      expect(result.dx, 1.0);
    });

    test('screen coord far above image rect → dy clamped to 0', () {
      // y = -50 is well above ir.top (30)
      final result = containerToNorm(imageRect, const Offset(250, -50), identity);
      expect(result.dy, 0.0);
    });

    test('screen coord far below image rect → dy clamped to 1', () {
      // y = 500 is well below ir.bottom (330)
      final result = containerToNorm(imageRect, const Offset(250, 500), identity);
      expect(result.dy, 1.0);
    });

    // --- Identity matrix: basic mapping correctness ---

    test('identity matrix: screen coord at image rect center → norm (0.5, 0.5)', () {
      final center = imageRect.center; // (250, 180)
      final result = containerToNorm(imageRect, center, identity);
      expect(result.dx, closeTo(0.5, 1e-9));
      expect(result.dy, closeTo(0.5, 1e-9));
    });

    test('identity matrix: screen coord at image rect top-left → norm (0, 0)', () {
      final topLeft = imageRect.topLeft; // (50, 30)
      final result = containerToNorm(imageRect, topLeft, identity);
      expect(result.dx, closeTo(0.0, 1e-9));
      expect(result.dy, closeTo(0.0, 1e-9));
    });

    test('identity matrix: screen coord at image rect bottom-right → norm (1, 1)', () {
      final bottomRight = imageRect.bottomRight; // (450, 330)
      final result = containerToNorm(imageRect, bottomRight, identity);
      expect(result.dx, closeTo(1.0, 1e-9));
      expect(result.dy, closeTo(1.0, 1e-9));
    });
  });
}
