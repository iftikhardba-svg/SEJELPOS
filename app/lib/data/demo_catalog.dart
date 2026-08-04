/// Demo catalog — stands in until the sync client pulls the real one.
///
/// The numbers are not invented: HUMMOS really is 8.00 on tier A and 9.00 on
/// tier B at the first customer, and the print_loc values use the real
/// station bits (2=Expo, 3=Grill, 4=Shawarma, 5=DT). Keeping the demo data
/// truthful means every screen and test exercises the same arithmetic the
/// real catalog will.
library;

import 'pos_database.dart';

void seedDemoCatalog(PosDatabase db) {
  final raw = db.raw;

  raw.execute(
    "INSERT INTO menu_screen (menu_id, name, sort_order) VALUES "
    "(2010, 'Appetizers', 0), (2023, 'Sandwiches', 1)",
  );

  void product(int num, String name, int a, int? b, int printLoc,
      {int menuId = 2010}) {
    // price_j is explicitly 0: the comp tier (staff meals) is a real zero
    // price, and a NULL there is refused — same rule as the backend.
    raw.execute(
      'INSERT INTO product (prodnum, descript, price_a, price_b, price_j, '
      '  print_loc, tax_applies) VALUES (?, ?, ?, ?, 0, ?, 1)',
      [num, name, a, b, printLoc],
    );
    raw.execute(
      'INSERT INTO menu_button (id, menu_id, prodnum, position) '
      'VALUES (?, ?, ?, ?)',
      ['btn-$num', menuId, num, num],
    );
  }

  product(2013, 'HUMMOS', 800, 900, 0);
  product(2008, 'MOUSHAKAL SABAH', 3800, 3900, 0);
  product(2152, 'Hummos Lahm', 2400, 2900, 40); // Grill + DT
  product(2451, 'KABSA MASHAWI 1/2 KG', 9900, 9900, 40, menuId: 2023);
  product(2058, 'Shawa Sandw Ckn', 500, 700, 16, menuId: 2023); // Shawarma
  product(2499, 'Water Small', 100, 200, 38, menuId: 2023);

  raw.execute(
    "INSERT INTO kitchen_station (station_no, name) VALUES "
    "(2, 'Expo'), (3, 'Grill'), (4, 'Shawarma'), (5, 'DT')",
  );

  raw.execute(
    "INSERT INTO sales_type (sale_type_no, descript, price_tier, "
    "  is_aggregator, requires_external_ref, sort_order) VALUES "
    "(2025, 'Drive Thru', 'a', 0, 0, 0), "
    "(1006, 'TakeAway', 'a', 0, 0, 1), "
    "(2004, 'Keeta', 'b', 1, 1, 2), "
    "(2026, 'Staff Meal', 'j', 0, 0, 3)",
  );

  raw.execute(
    "INSERT INTO pay_method (methodnum, descript, is_cash) VALUES "
    "(1001, 'CASH', 1), (1010, 'MADA', 0), (1002, 'Visa', 0)",
  );

  // sale.emp_open is NOT NULL and references employee — a sale always has a
  // cashier.
  raw.execute(
    "INSERT INTO employee (empnum, name, must_set_pin) "
    "VALUES (0, 'Demo Cashier', 1)",
  );

  db.provisionDevice(deviceUuid: 'demo-tablet', receiptPrefix: 'T01');
}
