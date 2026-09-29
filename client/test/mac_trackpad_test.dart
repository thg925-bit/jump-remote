import 'package:flutter_test/flutter_test.dart';
import 'package:jump_viewer/src/mac_trackpad.dart';

void main() {
  // Tests run on the Mac, so the curve uses iPad-like 132 px/in.
  const pxPerInch = 132.0;
  double pointsPerInch(double inchesPerSecond, [double speed = 1.0]) =>
      MacTrackpad.gain(pxPerSecond: inchesPerSecond * pxPerInch, trackingSpeed: speed) * pxPerInch;

  test('matches the web viewer at tracking speed 1.0 (scale 0.55)', () {
    // speed(v) = 0.92v + 1.15v^2 + 0.18v^3; points/inch = speed(v)/v * 72 * 0.55
    expect(pointsPerInch(1), closeTo((0.92 + 1.14999 + 0.17999) * 72 * 0.55, 0.01)); // ~89
    expect(pointsPerInch(3), closeTo((0.92 + 1.14999 * 3 + 0.17999 * 9) * 72 * 0.55, 0.01)); // ~237
  });

  test('slow strokes are finer than fast ones', () {
    expect(pointsPerInch(0.2), lessThan(pointsPerInch(1)));
    expect(pointsPerInch(1), lessThan(pointsPerInch(4)));
  });

  test('curve is continuous at both tangents', () {
    for (final v in [7.0, 16.0]) {
      final below = pointsPerInch(v - 1e-6) * (v - 1e-6);
      final above = pointsPerInch(v + 1e-6) * (v + 1e-6);
      expect(above, closeTo(below, 0.01));
    }
  });

  test('faster tracking speed moves further', () {
    expect(pointsPerInch(2, 1.5), greaterThan(pointsPerInch(2, 1.0)));
    expect(pointsPerInch(2, 0.6875), lessThan(pointsPerInch(2, 1.0)));
  });
}
