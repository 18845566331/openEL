import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';

/// Pure math extraction of `_BoxPainter._imageRect` from workbench_page.dart.
/// Computes the BoxFit.contain image rectangle within a container.
Rect imageRect(Size containerSize, double imageAspectRatio) {
  if (imageAspectRatio <= 0) {
    return Rect.fromLTWH(0, 0, containerSize.width, containerSize.height);
  }
  final containerAR = containerSize.width / containerSize.height;
  double imgW, imgH;
  if (imageAspectRatio > containerAR) {
    // Image wider than container → fill width, letterbox top/bottom
    imgW = containerSize.width;
    imgH = containerSize.width / imageAspectRatio;
  } else {
    // Image taller than container → fill height, pillarbox left/right
    imgH = containerSize.height;
    imgW = containerSize.height * imageAspectRatio;
  }
  final offsetX = (containerSize.width - imgW) / 2;
  final offsetY = (containerSize.height - imgH) / 2;
  return Rect.fromLTWH(offsetX, offsetY, imgW, imgH);
}

/// Pure math extraction of `_BoxPainter._mapNormToCanvas` from workbench_page.dart.
/// Maps a normalized rect (0~1) to canvas pixel coordinates.
Rect mapNormToCanvas(Rect norm, Size containerSize, double imageAspectRatio) {
  final ir = imageRect(containerSize, imageAspectRatio);
  return Rect.fromLTRB(
    ir.left + norm.left * ir.width,
    ir.top + norm.top * ir.height,
    ir.left + norm.right * ir.width,
    ir.top + norm.bottom * ir.height,
  );
}

void main() {
  /// **Validates: Requirements 4.2**
  ///
  /// Unit tests for _BoxPainter normalized coordinate mapping.
  /// Verifies that _mapNormToCanvas correctly maps normalized (0~1)
  /// coordinates to canvas pixel coordinates for various aspect ratios.
  group('_BoxPainter 归一化坐标映射 (Normalized coordinate mapping)', () {
    // ── Square image in square container (1:1) ──

    test('square image in square container: full rect (0,0,1,1) fills entire container', () {
      const container = Size(400, 400);
      const aspectRatio = 1.0; // 1:1
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0, 0, 1, 1),
        container,
        aspectRatio,
      );
      expect(result.left, closeTo(0, 1e-9));
      expect(result.top, closeTo(0, 1e-9));
      expect(result.right, closeTo(400, 1e-9));
      expect(result.bottom, closeTo(400, 1e-9));
    });

    test('square image in square container: center point (0.5,0.5) maps to (200,200)', () {
      const container = Size(400, 400);
      const aspectRatio = 1.0;
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0.5, 0.5, 0.5, 0.5),
        container,
        aspectRatio,
      );
      expect(result.left, closeTo(200, 1e-9));
      expect(result.top, closeTo(200, 1e-9));
    });

    // ── Wide image in square container (letterboxed) ──

    test('wide image (2:1) in square container (400x400): letterboxed with top/bottom bars', () {
      const container = Size(400, 400);
      const aspectRatio = 2.0; // 2:1 → wider than container
      // Image fills width: imgW=400, imgH=400/2=200
      // offsetY = (400-200)/2 = 100
      final ir = imageRect(container, aspectRatio);
      expect(ir.left, closeTo(0, 1e-9));
      expect(ir.top, closeTo(100, 1e-9));
      expect(ir.width, closeTo(400, 1e-9));
      expect(ir.height, closeTo(200, 1e-9));

      // Full norm rect maps to the image area
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0, 0, 1, 1),
        container,
        aspectRatio,
      );
      expect(result.left, closeTo(0, 1e-9));
      expect(result.top, closeTo(100, 1e-9));
      expect(result.right, closeTo(400, 1e-9));
      expect(result.bottom, closeTo(300, 1e-9));
    });

    test('wide image (2:1) in square container: center (0.5,0.5) maps to (200,200)', () {
      const container = Size(400, 400);
      const aspectRatio = 2.0;
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0.5, 0.5, 0.5, 0.5),
        container,
        aspectRatio,
      );
      // imgW=400, imgH=200, offsetX=0, offsetY=100
      // x = 0 + 0.5*400 = 200, y = 100 + 0.5*200 = 200
      expect(result.left, closeTo(200, 1e-9));
      expect(result.top, closeTo(200, 1e-9));
    });

    // ── Tall image in square container (pillarboxed) ──

    test('tall image (0.5:1) in square container (400x400): pillarboxed with left/right bars', () {
      const container = Size(400, 400);
      const aspectRatio = 0.5; // 1:2 → taller than container
      // Image fills height: imgH=400, imgW=400*0.5=200
      // offsetX = (400-200)/2 = 100
      final ir = imageRect(container, aspectRatio);
      expect(ir.left, closeTo(100, 1e-9));
      expect(ir.top, closeTo(0, 1e-9));
      expect(ir.width, closeTo(200, 1e-9));
      expect(ir.height, closeTo(400, 1e-9));

      // Full norm rect maps to the image area
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0, 0, 1, 1),
        container,
        aspectRatio,
      );
      expect(result.left, closeTo(100, 1e-9));
      expect(result.top, closeTo(0, 1e-9));
      expect(result.right, closeTo(300, 1e-9));
      expect(result.bottom, closeTo(400, 1e-9));
    });

    test('tall image (0.5:1) in square container: center (0.5,0.5) maps to (200,200)', () {
      const container = Size(400, 400);
      const aspectRatio = 0.5;
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0.5, 0.5, 0.5, 0.5),
        container,
        aspectRatio,
      );
      // imgW=200, imgH=400, offsetX=100, offsetY=0
      // x = 100 + 0.5*200 = 200, y = 0 + 0.5*400 = 200
      expect(result.left, closeTo(200, 1e-9));
      expect(result.top, closeTo(200, 1e-9));
    });

    // ── Image matching container aspect ratio ──

    test('image matching container AR (800x400 container, 2:1 image): no bars', () {
      const container = Size(800, 400);
      const aspectRatio = 2.0; // matches 800/400
      final ir = imageRect(container, aspectRatio);
      expect(ir.left, closeTo(0, 1e-9));
      expect(ir.top, closeTo(0, 1e-9));
      expect(ir.width, closeTo(800, 1e-9));
      expect(ir.height, closeTo(400, 1e-9));

      final result = mapNormToCanvas(
        const Rect.fromLTRB(0, 0, 1, 1),
        container,
        aspectRatio,
      );
      expect(result.left, closeTo(0, 1e-9));
      expect(result.top, closeTo(0, 1e-9));
      expect(result.right, closeTo(800, 1e-9));
      expect(result.bottom, closeTo(400, 1e-9));
    });

    // ── Edge coordinates (0,0), (1,1), (0.5,0.5) ──

    test('edge coordinates: origin (0,0) maps to image rect top-left', () {
      const container = Size(600, 400);
      const aspectRatio = 1.5; // matches 600/400 exactly
      final ir = imageRect(container, aspectRatio);
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0, 0, 0, 0),
        container,
        aspectRatio,
      );
      expect(result.left, closeTo(ir.left, 1e-9));
      expect(result.top, closeTo(ir.top, 1e-9));
    });

    test('edge coordinates: (1,1) maps to image rect bottom-right', () {
      const container = Size(600, 400);
      const aspectRatio = 1.5;
      final ir = imageRect(container, aspectRatio);
      final result = mapNormToCanvas(
        const Rect.fromLTRB(1, 1, 1, 1),
        container,
        aspectRatio,
      );
      expect(result.left, closeTo(ir.right, 1e-9));
      expect(result.top, closeTo(ir.bottom, 1e-9));
    });

    test('edge coordinates: (0.5,0.5) maps to image rect center', () {
      const container = Size(600, 400);
      const aspectRatio = 1.5;
      final ir = imageRect(container, aspectRatio);
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0.5, 0.5, 0.5, 0.5),
        container,
        aspectRatio,
      );
      expect(result.left, closeTo(ir.center.dx, 1e-9));
      expect(result.top, closeTo(ir.center.dy, 1e-9));
    });

    // ── imageAspectRatio <= 0 fallback ──

    test('imageAspectRatio = 0: image rect fills entire container', () {
      const container = Size(500, 300);
      final ir = imageRect(container, 0);
      expect(ir.left, closeTo(0, 1e-9));
      expect(ir.top, closeTo(0, 1e-9));
      expect(ir.width, closeTo(500, 1e-9));
      expect(ir.height, closeTo(300, 1e-9));

      final result = mapNormToCanvas(
        const Rect.fromLTRB(0.25, 0.25, 0.75, 0.75),
        container,
        0,
      );
      expect(result.left, closeTo(125, 1e-9));
      expect(result.top, closeTo(75, 1e-9));
      expect(result.right, closeTo(375, 1e-9));
      expect(result.bottom, closeTo(225, 1e-9));
    });

    // ── Partial norm rect mapping ──

    test('partial norm rect (0.1, 0.2, 0.6, 0.8) in wide image', () {
      const container = Size(400, 400);
      const aspectRatio = 2.0;
      // imgW=400, imgH=200, offsetX=0, offsetY=100
      final result = mapNormToCanvas(
        const Rect.fromLTRB(0.1, 0.2, 0.6, 0.8),
        container,
        aspectRatio,
      );
      // left = 0 + 0.1*400 = 40
      // top = 100 + 0.2*200 = 140
      // right = 0 + 0.6*400 = 240
      // bottom = 100 + 0.8*200 = 260
      expect(result.left, closeTo(40, 1e-9));
      expect(result.top, closeTo(140, 1e-9));
      expect(result.right, closeTo(240, 1e-9));
      expect(result.bottom, closeTo(260, 1e-9));
    });
  });
}
