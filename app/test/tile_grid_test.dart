/// One grid, three screens.
///
/// A menu of pages, a page of products and a room of tables are the same
/// gesture — a person reaching for a position — so they are the same grid.
/// These pin the two things that makes true: the cells are square, and the
/// coordinate space is whatever the data says rather than an assumed origin.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pos_app/ui/tile_grid.dart';

typedef Cell = ({int? x, int? y, String label});

void main() {
  Future<void> pump(WidgetTester tester, List<Cell> cells,
      {double width = 900}) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PositionedTileGrid<Cell>(
          items: cells,
          x: (c) => c.x,
          y: (c) => c.y,
          tile: (c) => ColoredBox(
            color: Colors.amber,
            child: Center(child: Text(c.label)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('draws every cell square', (tester) async {
    await pump(tester, [
      (x: 1, y: 1, label: 'a'),
      (x: 2, y: 1, label: 'b'),
      (x: 1, y: 2, label: 'c'),
    ]);

    for (final label in ['a', 'b', 'c']) {
      final box = tester.getSize(find.ancestor(
        of: find.text(label),
        matching: find.byType(SizedBox),
      ).first);
      expect(box.width, box.height, reason: '$label is not square');
    }
  });

  testWidgets('a coordinate space starting at zero is not dropped',
      (tester) async {
    // Menu buttons are numbered from 1 and tables from 0. A grid that
    // assumed 1 silently drew nothing for everything on row or column zero,
    // which is where a floor plan puts its first table.
    await pump(tester, [
      (x: 0, y: 0, label: 'first'),
      (x: 1, y: 0, label: 'second'),
    ]);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('a plan spread over a wide canvas still fits its columns',
      (tester) async {
    // The imported floor puts five tables at x = 0, 5, 10, 20, 25. Until the
    // back office closes the gaps that is twenty-six columns, and the grid
    // has to stay usable rather than shrink the tiles to nothing.
    await pump(tester, [
      for (final x in [0, 5, 10, 20, 25]) (x: x, y: 0, label: 't$x'),
    ]);
    final box = tester.getSize(find.ancestor(
      of: find.text('t0'),
      matching: find.byType(SizedBox),
    ).first);
    expect(box.width, kTileMin, reason: 'clamped, not squeezed away');
    expect(box.width, box.height);
    // And it scrolls rather than overflowing.
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('an item with no position still gets a tile', (tester) async {
    await pump(tester, [
      (x: 1, y: 1, label: 'placed'),
      (x: null, y: null, label: 'loose'),
    ]);
    expect(find.text('placed'), findsOneWidget);
    // Unreachable is worse than out of place.
    expect(find.text('loose'), findsOneWidget);
  });

  testWidgets('a hidden position leaves its hole', (tester) async {
    // Deliberate: a missing tile must not pull the rest along, or every item
    // after it moves under a different finger.
    await pump(tester, [
      (x: 1, y: 1, label: 'a'),
      (x: 3, y: 1, label: 'c'),
    ]);
    final a = tester.getTopLeft(find.text('a'));
    final c = tester.getTopLeft(find.text('c'));
    expect(c.dx - a.dx, greaterThan(kTileMin), reason: 'gap kept');
  });
}
