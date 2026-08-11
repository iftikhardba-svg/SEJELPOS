/// The grid every screen on this till is laid out on.
///
/// A menu of pages, a page of products and a room of tables are the same
/// gesture: a person reaches for a position. So they are the same grid —
/// square cells at the coordinates the back office arranged them at, the same
/// size, the same gap, in every one of the three places. That is not a
/// styling preference: a cashier who learns that the third square on the
/// second row is the drinks page should find tables laid out the same way,
/// and a manager arranging either one in the back office should be arranging
/// the thing they will actually see.
///
/// **Square**, because a till is reached for by position and shape. The old
/// stretched-to-fit rectangles changed size with the number of columns, so
/// the same item was a different shape on the shawarma page and the grill
/// page. The maximum stops a two-tile page from producing enormous buttons;
/// the minimum keeps an eleven-column page pressable, and the grid scrolls
/// sideways rather than shrinking past it.
library;

import 'package:flutter/material.dart';

/// The size of a cell, and the space between them. Shared so the three grids
/// cannot drift apart by someone editing one of them.
const double kTileMax = 150.0;
const double kTileMin = 84.0;
const double kTileGap = 8.0;

class PositionedTileGrid<T> extends StatelessWidget {
  const PositionedTileGrid({
    super.key,
    required this.items,
    required this.x,
    required this.y,
    required this.tile,
  });

  final List<T> items;

  /// Where the item sits. Null on either axis puts it after the grid rather
  /// than dropping it — something unreachable is worse than something out of
  /// place.
  final int? Function(T) x;
  final int? Function(T) y;

  /// Draws one item. Named `tile` rather than `build` so it does not
  /// collide with the widget's own build method.
  final Widget Function(T) tile;

  @override
  Widget build(BuildContext context) {
    final placed = <int, Map<int, T>>{};
    int? minX, maxX, minY, maxY;
    for (final item in items) {
      final ix = x(item), iy = y(item);
      if (ix == null || iy == null) continue;
      placed.putIfAbsent(iy, () => {})[ix] = item;
      // The bounds come from the items, never from an assumed origin: menu
      // buttons are numbered from 1 and tables from 0, and a grid that
      // started counting at 1 silently dropped everything on row zero.
      minX = minX == null || ix < minX ? ix : minX;
      maxX = maxX == null || ix > maxX ? ix : maxX;
      minY = minY == null || iy < minY ? iy : minY;
      maxY = maxY == null || iy > maxY ? iy : maxY;
    }

    // Anything without coordinates still has to be reachable, so it goes on
    // the end rather than being dropped.
    final loose = [for (final i in items) if (x(i) == null || y(i) == null) i];
    final originX = minX ?? 0;
    final originY = minY ?? 0;
    final columns = minX == null ? 0 : (maxX ?? originX) - originX + 1;
    final rows = minY == null ? 0 : (maxY ?? originY) - originY + 1;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - kTileGap * 2;
        final across = columns > 0 ? columns : 1;
        final side = (((available - kTileGap * (across - 1)) / across)
            .clamp(kTileMin, kTileMax));

        final grid = ListView(
          padding: const EdgeInsets.all(kTileGap),
          children: [
            for (var row = 0; row < rows; row++)
              Padding(
                padding: const EdgeInsets.only(bottom: kTileGap),
                // NOT CrossAxisAlignment.stretch: a Row inside a vertical
                // ListView has unbounded height, and stretching into that is
                // an invalid constraint. The SizedBox below sets the size.
                child: Row(
                  children: [
                    for (var col = 0; col < columns; col++)
                      Padding(
                        padding: const EdgeInsets.only(right: kTileGap),
                        child: SizedBox(
                          width: side,
                          height: side,
                          child: placed[originY + row]?[originX + col] == null
                              ? const SizedBox.shrink()
                              : tile(placed[originY + row]![originX + col] as T),
                        ),
                      ),
                  ],
                ),
              ),
            if (loose.isNotEmpty)
              Wrap(
                spacing: kTileGap,
                runSpacing: kTileGap,
                children: [
                  for (final item in loose)
                    SizedBox(width: side, height: side, child: tile(item)),
                ],
              ),
          ],
        );

        // At the floor the row can be wider than the panel. Scrolling it is
        // the honest answer: squeezing the tiles further makes them unreadable
        // and, on a page laid out at eleven columns, unhittable.
        //
        // The width is the list's own padding plus every cell and the gap that
        // follows it: one gap short and the row overflows by exactly that gap,
        // which the app draws as warning stripes across the menu.
        final needed = across * (side + kTileGap) + kTileGap * 2;
        if (needed <= constraints.maxWidth) return grid;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: needed, child: grid),
        );
      },
    );
  }
}
