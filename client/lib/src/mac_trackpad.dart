import 'dart:io' show Platform;
import 'dart:math' as math;

/// macOS pointer acceleration, so the stick moves like a MacBook trackpad: relative motion
/// where slow strokes are precise and quick flicks travel far.
///
/// These are the host Mac's own IOHIDFamily parametric "HIDAccelCurves", one per System
/// Settings tracking-speed step: finger speed in inches/s in, cursor speed in inches/s out.
/// Kept in sync with the web viewer (host/Resources/web/index.html).
class MacTrackpad {
  /// Tracking-speed steps offered in the app, as (label, macOS index).
  static const speeds = <String, (String, double)>{
    'slow': ('느림', 0.6875),
    'normal': ('보통', 1.0),
    'fast': ('빠름', 1.5),
  };

  static const _pointsPerInch = 72.0;

  /// Glass under a fingertip isn't a MacBook trackpad: 1:1 felt too fast.
  static const _scale = 0.55;

  /// Logical pixels per physical inch (Android dp are 160/in; iPad points are ~132/in).
  static final double _pxPerInch = Platform.isAndroid ? 160 : 132;

  static final _curves = <double, List<double>>{
    // index: [gainLinear, gainParabolic, gainCubic, gainQuartic, tangentLinear, tangentParabolicRoot]
    0.0: [1.0, 0.0, 0.0, 0.0, 7.39999, 21.0],
    0.125: [0.99001, 0.5, 0.08, 0.0, 7.3, 20.0],
    0.5: [0.98, 0.66, 0.10001, 0.0, 7.2, 19.0],
    0.6875: [0.96001, 0.83, 0.12, 0.0, 7.10001, 18.0],
    0.875: [0.94, 1.0, 0.14999, 0.0, 7.0, 17.0],
    1.0: [0.92, 1.14999, 0.17999, 0.0, 7.0, 16.0],
    1.5: [0.89, 1.3, 0.21001, 0.0, 7.0, 15.0],
    2.0: [0.86, 1.45, 0.24001, 0.0, 7.0, 14.0],
    2.5: [0.83, 1.66, 0.28, 0.0, 7.0, 13.0],
    3.0: [1.0, 1.88, 0.36, 0.0, 7.0, 12.0],
  };

  static final _prepared = <double, _Curve>{};

  /// Mac points of cursor travel per logical pixel of finger travel at this finger speed.
  static double gain({required double pxPerSecond, required double trackingSpeed}) {
    final curve = _prepared.putIfAbsent(trackingSpeed, () => _Curve(_curves[trackingSpeed] ?? _curves[1.0]!));
    final inchesPerSecond = pxPerSecond / _pxPerInch;
    final factor = inchesPerSecond > 0.05 ? curve.speed(inchesPerSecond) / inchesPerSecond : curve.g1;
    return factor * _pointsPerInch * _scale / _pxPerInch;
  }
}

/// Polynomial up to the first tangent, then its tangent line, then a square-root tail.
class _Curve {
  _Curve(List<double> p)
      : g1 = p[0],
        g2 = p[1],
        g3 = p[2],
        g4 = p[3],
        t1 = p[4],
        t2 = p[5] {
    m0 = _slope(t1);
    b0 = _poly(t1) - m0 * t1;
    final y1 = m0 * t2 + b0;
    mRoot = 2 * y1 * m0; // sqrt(mRoot*x + bRoot) meets the line at t2 with the same slope
    bRoot = y1 * y1 - mRoot * t2;
  }

  final double g1, g2, g3, g4, t1, t2;
  late final double m0, b0, mRoot, bRoot;

  double _poly(double x) => g1 * x + g2 * x * x + g3 * x * x * x + g4 * x * x * x * x;
  double _slope(double x) => g1 + 2 * g2 * x + 3 * g3 * x * x + 4 * g4 * x * x * x;

  double speed(double v) {
    if (v <= t1) return _poly(v);
    if (v <= t2) return m0 * v + b0;
    return math.sqrt(mRoot * v + bRoot);
  }
}
