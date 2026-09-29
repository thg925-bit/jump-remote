import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:jump_viewer/src/viewer_layout.dart';

/// The Mac screen (2560x1664) fitted into [size], as the viewer does.
Rect fitVideo(Size size) {
  final k = math.min(size.width / 2560, size.height / 1664);
  final w = 2560 * k, h = 1664 * k;
  return Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);
}

void main() {
  // The user's phone in landscape (2000x923 px screenshot ≈ 762x352 logical).
  const phoneLandscape = Size(762, 352);
  const phonePortrait = Size(352, 762);

  test('landscape: stick sits inside the right black bar, toolbar fills the left one', () {
    final video = fitVideo(phoneLandscape);
    final layout = ViewerLayout.compute(size: phoneLandscape, video: video, zoomed: false, stickOnRight: true);
    expect(layout.landscape, isTrue);
    expect(layout.toolbarOnLeft, isTrue);
    expect(layout.toolbarInBar, isTrue);
    expect(layout.toolbarExtent, closeTo(video.left, 0.01)); // ~110
    expect(layout.stick.left, greaterThanOrEqualTo(video.right)); // never over the Mac screen
    expect(layout.stick.right, lessThanOrEqualTo(phoneLandscape.width));
    expect(layout.stick.width, closeTo(video.left - 14, 0.01)); // shrunk to fit the bar (~96)
  });

  test('landscape with the stick on the left mirrors it', () {
    final video = fitVideo(phoneLandscape);
    final layout = ViewerLayout.compute(size: phoneLandscape, video: video, zoomed: false, stickOnRight: false);
    expect(layout.toolbarOnLeft, isFalse);
    expect(layout.stick.right, lessThanOrEqualTo(video.left));
  });

  test('zoomed in, the bars are gone: overlay toolbar and a full-size corner stick', () {
    final layout = ViewerLayout.compute(
        size: phoneLandscape, video: fitVideo(phoneLandscape), zoomed: true, stickOnRight: true);
    expect(layout.toolbarInBar, isFalse);
    expect(layout.toolbarExtent, 64);
    expect(layout.stick.width, 128);
  });

  test('portrait: toolbar in the top bar, stick in the bottom bar', () {
    final video = fitVideo(phonePortrait);
    final layout = ViewerLayout.compute(size: phonePortrait, video: video, zoomed: false, stickOnRight: true);
    expect(layout.landscape, isFalse);
    expect(layout.toolbarInBar, isTrue);
    expect(layout.stick.top, greaterThanOrEqualTo(video.bottom));
    expect(layout.stick.width, 128);
  });

  test('a dragged position wins and stays on screen', () {
    final layout = ViewerLayout.compute(
        size: phoneLandscape, video: fitVideo(phoneLandscape), zoomed: false, stickOnRight: true,
        custom: const Offset(0.99, 0.01));
    expect(layout.stick.right, lessThanOrEqualTo(phoneLandscape.width));
    expect(layout.stick.top, greaterThanOrEqualTo(0));
  });

  group('toolbar docking', () {
    const landscape = Rect.fromLTWH(0, 0, 762, 352);
    const portrait = Rect.fromLTWH(0, 0, 352, 762);

    bool inside(Rect inner, Rect outer) => inner.left >= outer.left - 0.01 && inner.top >= outer.top - 0.01 &&
        inner.right <= outer.right + 0.01 && inner.bottom <= outer.bottom + 0.01;

    test('the nearest of the four edges wins', () {
      expect(ToolbarPlacement.nearestEdge(const Offset(40, 200), phoneLandscape), ToolbarEdge.left);
      expect(ToolbarPlacement.nearestEdge(const Offset(730, 200), phoneLandscape), ToolbarEdge.right);
      expect(ToolbarPlacement.nearestEdge(const Offset(380, 30), phoneLandscape), ToolbarEdge.top);
      expect(ToolbarPlacement.nearestEdge(const Offset(380, 330), phoneLandscape), ToolbarEdge.bottom);
    });

    test('landscape side: one column at the edge', () {
      final place = ToolbarPlacement.compute(edge: ToolbarEdge.left, count: 8, bounds: landscape, along: const Offset(40, 176));
      expect(place.lines, 1);
      expect(place.buttonSize.height, greaterThanOrEqualTo(38)); // still an easy tap
      expect(place.rect.left, ToolbarPlacement.margin);
      expect(inside(place.rect, landscape), isTrue);
    });

    test('portrait top: one row across the top, icon-only to fit', () {
      final place = ToolbarPlacement.compute(edge: ToolbarEdge.top, count: 9, bounds: portrait, along: const Offset(176, 20));
      expect(place.lines, 1);
      expect(place.compact, isTrue);
      expect(place.rect.top, ToolbarPlacement.margin);
      expect(inside(place.rect, portrait), isTrue);
    });

    test('bottom row steps beside the stick when there is room', () {
      const stick = Rect.fromLTWH(600, 200, 128, 128);
      final place = ToolbarPlacement.compute(edge: ToolbarEdge.bottom, count: 8, bounds: landscape, along: const Offset(380, 330), avoid: const Rect.fromLTWH(620, 214, 128, 128));
      expect(place.lines, 1);
      expect(place.rect.overlaps(const Rect.fromLTWH(620, 214, 128, 128)), isFalse);
      expect(place.rect.bottom, closeTo(landscape.bottom - ToolbarPlacement.margin, 0.01));
      expect(stick.width, 128);
    });

    test('bottom row runs just above the stick when beside it is too short', () {
      const stick = Rect.fromLTWH(200, 610, 128, 128);
      final place = ToolbarPlacement.compute(edge: ToolbarEdge.bottom, count: 8, bounds: portrait, along: const Offset(176, 740), avoid: stick);
      expect(place.lines, 1);
      expect(place.rect.overlaps(stick), isFalse);
      expect(place.rect.bottom, lessThanOrEqualTo(stick.top));
    });

    test('column on the stick side sits above the stick', () {
      const stick = Rect.fromLTWH(634, 200, 128, 128);
      final place = ToolbarPlacement.compute(edge: ToolbarEdge.right, count: 8, bounds: landscape, along: const Offset(730, 300), avoid: stick);
      expect(place.rect.overlaps(stick), isFalse);
      expect(place.rect.right, closeTo(landscape.right - ToolbarPlacement.margin, 0.01));
      expect(inside(place.rect, landscape), isTrue);
    });

    test('keyboard up in landscape: wraps (icon-only) rather than hide any button', () {
      const tight = Rect.fromLTWH(0, 0, 844, 140);
      final place = ToolbarPlacement.compute(edge: ToolbarEdge.left, count: 9, bounds: tight, along: const Offset(40, 70));
      expect(place.lines, greaterThan(1));
      expect(place.compact, isTrue);
      expect(place.lines * place.perLine, greaterThanOrEqualTo(9));
      expect(inside(place.rect, tight), isTrue);
    });

    test('keyboard up, stick side with no room above it: stands beside the stick', () {
      const tight = Rect.fromLTWH(0, 0, 844, 140);
      const stick = Rect.fromLTWH(726, 12, 118, 118);
      final place = ToolbarPlacement.compute(edge: ToolbarEdge.right, count: 8, bounds: tight, along: const Offset(800, 40), avoid: stick);
      expect(place.rect.overlaps(stick), isFalse);
      expect(inside(place.rect, tight), isTrue);
    });

    test('while dragged it follows the finger but never leaves the screen', () {
      final place = ToolbarPlacement.compute(
          edge: ToolbarEdge.right, count: 8, bounds: landscape, along: const Offset(900, 500), floating: true);
      expect(inside(place.rect, landscape), isTrue);
    });
  });
}
