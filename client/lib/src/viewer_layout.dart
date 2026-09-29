import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// Where the toolbar and trackpad stick go around a letterboxed Mac screen: into the black
/// bars when there are any (so they never cover the Mac), otherwise over the video.
class ViewerLayout {
  ViewerLayout._({
    required this.landscape,
    required this.toolbarOnLeft,
    required this.toolbarExtent,
    required this.toolbarInBar,
    required this.stick,
  });

  /// Portrait puts the toolbar across the top; landscape puts it down one side.
  final bool landscape;

  /// Landscape only: the toolbar takes the side opposite the stick.
  final bool toolbarOnLeft;

  /// Landscape: the toolbar column's width (the whole bar when it fits one).
  final double toolbarExtent;

  /// False when the toolbar has to overlap the video (draw it on a translucent panel).
  final bool toolbarInBar;

  /// The stick's square (the circle fills it).
  final Rect stick;

  static const _stickMax = 128.0;
  static const _toolbarMin = 64.0;

  /// [video] is the fitted, unzoomed Mac screen; [zoomed] means the video may cover the bars.
  /// [custom] is a user-dragged stick centre as a fraction of [size].
  factory ViewerLayout.compute({
    required Size size,
    required Rect video,
    required bool zoomed,
    required bool stickOnRight,
    Offset? custom,
    double bottomInset = 0,
    double keyboardLift = 0,
  }) {
    final landscape = size.width > size.height;
    final barsFree = !video.isEmpty && !zoomed;
    final sideBar = barsFree ? math.min(video.left, size.width - video.right) : 0.0;
    final topBar = barsFree ? video.top : 0.0;
    final bottomBar = barsFree ? size.height - video.bottom : 0.0;

    var diameter = _stickMax;
    Offset center;
    if (custom != null) {
      center = Offset(custom.dx * size.width, custom.dy * size.height);
    } else if (landscape && sideBar >= 80) {
      diameter = math.min(_stickMax, sideBar - 14);
      final x = stickOnRight ? size.width - sideBar / 2 : sideBar / 2;
      center = Offset(x, size.height - bottomInset - 24 - keyboardLift - diameter / 2);
    } else if (!landscape && bottomBar >= 100) {
      diameter = math.min(_stickMax, bottomBar - 20);
      center = Offset(stickOnRight ? size.width - 24 - diameter / 2 : 24 + diameter / 2, size.height - bottomBar / 2);
    } else {
      center = Offset(stickOnRight ? size.width - 28 - diameter / 2 : 28 + diameter / 2,
          size.height - bottomInset - 28 - keyboardLift - diameter / 2);
    }
    center = Offset(center.dx.clamp(diameter / 2, size.width - diameter / 2),
        center.dy.clamp(diameter / 2, size.height - diameter / 2));

    return ViewerLayout._(
      landscape: landscape,
      toolbarOnLeft: stickOnRight,
      toolbarExtent: landscape && sideBar >= _toolbarMin ? sideBar : _toolbarMin,
      toolbarInBar: landscape ? sideBar >= _toolbarMin : topBar >= 60,
      stick: Rect.fromCenter(center: center, width: diameter, height: diameter),
    );
  }
}

enum ToolbarEdge { left, right, top, bottom }

/// Where the toolbar sits: one clean line along the edge it is docked to (a column on the left
/// or right, a row along the top or bottom), on a translucent panel. When one line doesn't fit,
/// the buttons shrink, then become icon-only; only when even that is too small (the keyboard is
/// up in landscape) does it wrap into more lines, so every button stays on screen. It steps
/// around the stick.
class ToolbarPlacement {
  const ToolbarPlacement({
    required this.edge,
    required this.lines,
    required this.perLine,
    required this.rect,
    this.scale = 1,
    this.compact = false,
  });

  final ToolbarEdge edge;

  /// Columns (left/right) or rows (top/bottom): 1 unless space is really tight.
  final int lines;

  /// Buttons in each column or row.
  final int perLine;
  final Rect rect;

  /// Button size relative to [tile] (or [compactTile]).
  final double scale;

  /// Icon-only buttons.
  final bool compact;

  bool get vertical => edge == ToolbarEdge.left || edge == ToolbarEdge.right;
  Size get buttonSize => (compact ? compactTile : tile) * scale;

  /// One button, including the gap around it: with a label, and icon only.
  static const tile = Size(58, 58);
  static const compactTile = Size(44, 44);
  static const padding = 5.0;
  static const margin = 6.0;

  /// Labels stay while buttons are at least this big; below it icon-only buttons fit better.
  static const minLabelScale = 0.8;

  /// Icon-only buttons smaller than this wrap into a second line instead.
  static const minCompactScale = 0.7;

  /// The edge a toolbar dropped at [center] belongs to.
  static ToolbarEdge nearestEdge(Offset center, Size size) {
    final distances = {
      ToolbarEdge.left: center.dx,
      ToolbarEdge.right: size.width - center.dx,
      ToolbarEdge.top: center.dy,
      ToolbarEdge.bottom: size.height - center.dy,
    };
    return distances.entries.reduce((a, b) => b.value < a.value ? b : a).key;
  }

  /// Everything along [edge] of [region] that is clear of [avoid]: above or below it for a
  /// column, beside it for a row (whichever is bigger), or beside it when a column has no room.
  static Rect _clearOf(Rect region, ToolbarEdge edge, Rect? avoid, int count) {
    if (avoid == null) return region;
    final vertical = edge == ToolbarEdge.left || edge == ToolbarEdge.right;
    final thick = (vertical ? tile.width : tile.height) + 2 * padding;
    final strip = switch (edge) {
      ToolbarEdge.left => Rect.fromLTRB(region.left, region.top, region.left + thick, region.bottom),
      ToolbarEdge.right => Rect.fromLTRB(region.right - thick, region.top, region.right, region.bottom),
      ToolbarEdge.top => Rect.fromLTRB(region.left, region.top, region.right, region.top + thick),
      ToolbarEdge.bottom => Rect.fromLTRB(region.left, region.bottom - thick, region.right, region.bottom),
    };
    if (!strip.overlaps(avoid)) return region;
    if (vertical) {
      final above = Rect.fromLTRB(region.left, region.top, region.right, avoid.top - margin);
      final below = Rect.fromLTRB(region.left, avoid.bottom + margin, region.right, region.bottom);
      final pick = above.height >= below.height ? above : below;
      if (pick.height >= compactTile.height * 3 + 2 * padding) return pick;
      // No room above or below it (keyboard up): stand beside it instead.
      return edge == ToolbarEdge.left
          ? Rect.fromLTRB(avoid.right + margin, region.top, region.right, region.bottom)
          : Rect.fromLTRB(region.left, region.top, avoid.left - margin, region.bottom);
    }
    final leftSide = Rect.fromLTRB(region.left, region.top, avoid.left - margin, region.bottom);
    final rightSide = Rect.fromLTRB(avoid.right + margin, region.top, region.right, region.bottom);
    final beside = leftSide.width >= rightSide.width ? leftSide : rightSide;
    if (beside.width - 2 * padding >= count * compactTile.width * minCompactScale) return beside;
    // Too short beside it for one line: run the row just past the stick instead.
    return edge == ToolbarEdge.bottom
        ? Rect.fromLTRB(region.left, region.top, region.right, avoid.top - margin)
        : Rect.fromLTRB(region.left, avoid.bottom + margin, region.right, region.bottom);
  }

  /// One line if at all possible; else the fewest lines at the largest size.
  static ({int lines, int perLine, double scale, bool compact}) _grid(int count, double across, double along) {
    final full = math.min(1.0, math.min(across / tile.width, along / (count * tile.width)));
    if (full >= minLabelScale) return (lines: 1, perLine: count, scale: full, compact: false);
    final small = math.min(1.0, math.min(across / compactTile.width, along / (count * compactTile.width)));
    if (small >= minCompactScale) return (lines: 1, perLine: count, scale: small, compact: true);

    ({int lines, int perLine, double scale})? pick;
    for (var lines = 2; lines <= 5; lines++) {
      final perLine = math.max(1, (count / lines).ceil());
      final scale = math.min(1.0, math.min(across / (lines * compactTile.width), along / (perLine * compactTile.width)));
      if (pick == null || scale > pick.scale + 0.001) pick = (lines: lines, perLine: perLine, scale: scale);
    }
    return (lines: pick!.lines, perLine: pick.perLine, scale: pick.scale, compact: true);
  }

  /// Docked to [edge] of [bounds] (the screen minus safe insets and the keyboard bar), centred at
  /// [along] as far as it fits, clear of [avoid] (the stick). [floating] follows [along] freely
  /// instead, for while it is being dragged.
  factory ToolbarPlacement.compute({
    required ToolbarEdge edge,
    required int count,
    required Rect bounds,
    required Offset along,
    Rect? avoid,
    bool floating = false,
  }) {
    final vertical = edge == ToolbarEdge.left || edge == ToolbarEdge.right;
    final region = floating ? bounds.deflate(margin) : _clearOf(bounds.deflate(margin), edge, avoid, count);
    // Wrapping (keyboard up) may take up to about a third of the screen across.
    final across = (vertical
            ? math.min(region.width, math.max(3 * compactTile.width, bounds.width / 3))
            : math.min(region.height, math.max(2 * compactTile.height, bounds.height / 3))) -
        2 * padding;
    final length = (vertical ? region.height : region.width) - 2 * padding;
    final grid = _grid(count, across, length);
    final pitch = (grid.compact ? compactTile.width : tile.width) * grid.scale;
    final width = (vertical ? grid.lines : grid.perLine) * pitch + 2 * padding;
    final height = (vertical ? grid.perLine : grid.lines) * pitch + 2 * padding;

    double within(double value, double low, double high) => math.max(low, math.min(value, high));
    final Offset topLeft;
    if (floating) {
      topLeft = Offset(within(along.dx - width / 2, bounds.left, bounds.right - width),
          within(along.dy - height / 2, bounds.top, bounds.bottom - height));
    } else {
      final x = within(along.dx - width / 2, region.left, region.right - width);
      final y = within(along.dy - height / 2, region.top, region.bottom - height);
      topLeft = switch (edge) {
        ToolbarEdge.left => Offset(region.left, y),
        ToolbarEdge.right => Offset(region.right - width, y),
        ToolbarEdge.top => Offset(x, region.top),
        ToolbarEdge.bottom => Offset(x, region.bottom - height),
      };
    }
    return ToolbarPlacement(
      edge: edge,
      lines: grid.lines,
      perLine: grid.perLine,
      scale: grid.scale,
      compact: grid.compact,
      rect: topLeft & Size(width, height),
    );
  }
}
