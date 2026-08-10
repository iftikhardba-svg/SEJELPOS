"""Extract catalog data from a PixelPoint (SQL Anywhere) database to JSON.

Runs on **32-bit Python** — the SQL Anywhere ODBC driver on this machine is
32-bit only, so a 64-bit process cannot load it. See migration/README.md.

    py-32 extract.py --out extracted.json

Output is raw source data, lightly typed. All interpretation and reshaping
happens in transform.py, so this file can stay a faithful dump of what
PixelPoint actually holds.
"""

from __future__ import annotations

import argparse
import datetime as dt
import decimal
import json
import os
import sys

try:
    import pyodbc
except ImportError:  # pragma: no cover
    sys.exit("pyodbc missing. Install it into the 32-bit interpreter.")


# --------------------------------------------------------------------------
# Connection
# --------------------------------------------------------------------------

def connect() -> "pyodbc.Connection":
    """Open a read-only connection using SQLA_* environment variables."""
    dsn = os.environ.get("SQLA_DSN", "").strip()
    if dsn:
        parts = [f"DSN={dsn}"]
    else:
        parts = [
            f"DRIVER={{{os.environ.get('SQLA_DRIVER', 'SQL Anywhere 16')}}}",
            f"ServerName={os.environ.get('SQLA_SERVER', 'PixelSQLbase')}",
            f"DatabaseName={os.environ.get('SQLA_DBN', 'PixelSQLbase')}",
        ]
    parts += [
        f"UID={os.environ['SQLA_UID']}",
        f"PWD={os.environ['SQLA_PWD']}",
    ]
    con = pyodbc.connect(";".join(parts), autocommit=True)
    # We only ever read here; make that explicit to the server.
    con.execute("SET TEMPORARY OPTION isolation_level = 0")
    return con


def rows(con, sql: str) -> list[dict]:
    cur = con.cursor()
    cur.execute(sql)
    cols = [d[0] for d in cur.description]
    out = []
    for r in cur.fetchall():
        out.append({c: _clean(v) for c, v in zip(cols, r)})
    cur.close()
    return out


def _clean(v):
    """Make a value JSON-serialisable without losing precision."""
    if isinstance(v, (dt.datetime, dt.date, dt.time)):
        return v.isoformat()
    if isinstance(v, decimal.Decimal):
        # str, not float — money must not round-trip through binary floating point
        return str(v)
    if isinstance(v, (bytes, bytearray)):
        return None  # BLOBs (icons, pictures) are not migrated
    return v


# --------------------------------------------------------------------------
# Queries
# --------------------------------------------------------------------------
# Only the columns the new product actually needs. PixelPoint's Product table
# has 130+ columns; carrying them forward would import two decades of accreted
# configuration into a schema that has no use for it.

Q_PRODUCTS = """
SELECT PRODNUM, DESCRIPT, PRINTDES, PrintDes2, REFCODE, UnitDes,
       PRICEA, PRICEB, PRICEC, PRICED, PRICEE,
       PRICEF, PRICEG, PRICEH, PRICEI, PRICEJ,
       REPORTNO, PRODTYPE, TAX1, TEXEMPT,
       ISWEIGHED, ManualPrice, ISACTIVE, PRINTLOC,
       -- The till button as staff know it. BUTTON1..3 are the label lines,
       -- which are deliberately not the product name: 308 of 560 differ and
       -- 250 carry a second line, because "(BSP) broasted strip pizza" has to
       -- fit on a tile. FORCOLOR/BACKCOLOR are a real colour-coded menu — 28
       -- distinct backgrounds — and that colour is how a cashier finds an item
       -- without reading it.
       BUTTON1, BUTTON2, BUTTON3, FORCOLOR, BACKCOLOR,
       -- Up to five meal-deal prompts, in the order they are asked.
       QUESTION1, QUESTION2, QUESTION3, QUESTION4, QUESTION5,
       -- Hot or cold. Set on 290 products; the kitchen cares.
       PrepTemp
FROM DBA.Product
"""

# The menu's own organising idea: "Report Cat" on PixelPoint's product screen.
# REPORTNO on Product points here, and it is what every sales report groups by.
#
# This was missed on the first pass, which took PRODTYPE for the category — a
# different column that is 0 on 536 of 560 products. The names never arrived,
# so the back office had nothing to group or filter by. ReportCat carries its
# own PRINTLOC as a default for its members; the product's own PRINTLOC is
# what actually routes, so the category's is imported for reference only.
Q_REPORT_CATEGORIES = """
SELECT REPORTNO, DESCRIPT, PRINTLOC, ISACTIVE, PrintPriority
FROM DBA.ReportCat
"""

# Kitchen stations. PRINTLOC on a product is a bitmask over these port
# numbers (bit n = port n); the port names are the station names — at the
# first customer: 2=Expo, 3=Grill, 4=Shawarma, 5=DT. Port 1 is the local
# receipt printer, not a kitchen station.
Q_PRINT_PORTS = """
SELECT PortNum, Descr, IsActive
FROM DBA.PrintPorts
WHERE IsActive = 1 AND PortNum > 1 AND Descr IS NOT NULL AND Descr <> ''
"""

# ForcePrice is the price tier the order type charges: 0/1 -> A, 2 -> B,
# 10 -> J. Aggregator types use B, and the difference from A is their
# commission — getting this wrong gives that margin away on every delivery.
Q_SALES_TYPES = """
SELECT SALETYPEINDEX, DESCRIPT, Abbreviation, ISACTIVE, ForcePrice,
       Tax1Exempt, OnInternet, BgColor, FrColor
FROM DBA.SalesType
"""

Q_CATEGORIES = """
SELECT ORDERCAT, DESCRIPT, ORDERPOSITION, TOPCOLOUR, BACKCOLOUR,
       ButtonAcross, ButtonDown, ISACTIVE
FROM DBA.OrderCat
"""

# The level above order pages: a whole menu. This customer has three —
# Default Menu, Kantaka Menu, Give Me Five — and the first is the coloured
# grid of pages a cashier lands on. Missed on the first pass, so the till had
# a flat strip of 57 page chips instead of the 7-tile grid staff know.
Q_MENUS = """
SELECT MENUINDEX, DESCRIPT, ISACTIVE, RevCenter
FROM DBA.MultiMenuNames
"""

# Meal deals. A product can carry up to five questions ("1 DRINKS", "TABAKAT
# 6 GRILL"); each offers choices that are themselves products. 85 products use
# one. Without this a meal rings with no drink chosen and the kitchen has no
# idea what to make.
#
# FORCED 0 = optional, 1 = must answer. NUMCHOICE is how many to pick,
# AllowMulti whether the same choice can be picked twice.
Q_QUESTIONS = """
SELECT OPTIONINDEX, QUESTION, Descript, FORCED, NUMCHOICE, AllowMulti,
       FreeChoices, ISACTIVE
FROM DBA.Questions
WHERE OPTIONINDEX > 0
"""

Q_QUESTION_CHOICES = """
SELECT UNIQUEID, OPTIONINDEX, CHOICE, Sequence, PriceMode, FixedPrice,
       DefQuan, IsActive
FROM DBA.ForcedChoices
"""

# Items included in a combo without being asked about — "Bucket BROSTED"
# always comes with a litre, a garlic and a hummos. ProdLinkNum is the parent.
Q_COMBO_ITEMS = """
SELECT ProductComboID, ProdLinkNum, ProdNum, OptionIndex, Sequence,
       ReqItem, PriceMode, FixedPrice, PrintIt, IsActive
FROM DBA.ProductCombo
"""

Q_MENU_BUTTONS = """
SELECT UniqueID, ORDERCAT, PRODNUM, PRODPOS, PosX, PosY, ISACTIVE
FROM DBA.MenuProdPos
"""

Q_CATEGORY_POSITIONS = """
SELECT UNIQUEID, ORDERCAT, ORDERPOS, MENUINDEX, PosX, PosY, ISACTIVE
FROM DBA.MENUORDERPOS
"""

Q_PAY_METHODS = """
SELECT METHODNUM, DESCRIPT, ISACTIVE, CURRENCY, EXCHANGE,
       AUTHREQR, NoDrawer, IsEFT, DispOrder, NumDecimals
FROM DBA.MethodPay
"""

Q_EMPLOYEES = """
SELECT EMPNUM, EMPNAME, EmpLastName, POSNAME, REFCODE,
       SECLEVEL, LOGINCODE, PASSKEY, ISACTIVE, StoreNum
FROM DBA.employee
"""

# PixelPoint's TableDrawSetup — where a visual floor plan would live — is empty
# here, so tables arrive with seat counts and no positions. The transform lays
# them out on a grid for the customer to rearrange.
Q_TABLES = """
SELECT TABLENUM, SECNUM, Descr, NUMCUSTOMER, MINNUMCUST, MAXNUMCUST,
       CANRESERVE, Status
FROM DBA.TABLESETUP
"""

# Which tables the restaurant actually seats people at, as opposed to the 150
# that were configured. Used to flag dead ones rather than import them as live.
Q_TABLE_USAGE = """
SELECT TABLENUM, COUNT(*) AS bills
FROM DBA.POSHEADER
WHERE TABLENUM > 0
GROUP BY TABLENUM
"""

# Context only — used to sanity-check the VAT rate we derive, not migrated.
Q_TAX_SAMPLE = """
SELECT TOP 200 TAX1, TAX1ABLE, NETTOTAL, FINALTOTAL
FROM DBA.POSHEADER
WHERE TAX1 > 0 AND TAX1ABLE > 0
ORDER BY OPENDATE DESC
"""

Q_COUNTS = """
SELECT
  (SELECT COUNT(*) FROM DBA.Product)      AS products,
  (SELECT COUNT(*) FROM DBA.OrderCat)     AS categories,
  (SELECT COUNT(*) FROM DBA.MenuProdPos)  AS menu_buttons,
  (SELECT COUNT(*) FROM DBA.MethodPay)    AS pay_methods,
  (SELECT COUNT(*) FROM DBA.employee)     AS employees,
  (SELECT COUNT(*) FROM DBA.TABLESETUP)   AS tables,
  (SELECT COUNT(*) FROM DBA.POSHEADER)    AS historical_sales
"""


def extract(con) -> dict:
    counts = rows(con, Q_COUNTS)[0]
    data = {
        "source": "pixelpoint",
        "extracted_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "counts": counts,
        "products": rows(con, Q_PRODUCTS),
        "report_categories": rows(con, Q_REPORT_CATEGORIES),
        "menus": rows(con, Q_MENUS),
        "questions": rows(con, Q_QUESTIONS),
        "question_choices": rows(con, Q_QUESTION_CHOICES),
        "combo_items": rows(con, Q_COMBO_ITEMS),
        "categories": rows(con, Q_CATEGORIES),
        "menu_buttons": rows(con, Q_MENU_BUTTONS),
        "category_positions": rows(con, Q_CATEGORY_POSITIONS),
        "pay_methods": rows(con, Q_PAY_METHODS),
        "employees": rows(con, Q_EMPLOYEES),
        "sales_types": rows(con, Q_SALES_TYPES),
        "print_ports": rows(con, Q_PRINT_PORTS),
        "tables": rows(con, Q_TABLES),
        "table_usage": rows(con, Q_TABLE_USAGE),
        "tax_sample": rows(con, Q_TAX_SAMPLE),
    }
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True, help="path to write JSON")
    args = ap.parse_args()

    if sys.maxsize > 2**32:
        print("WARNING: running on 64-bit Python — the SQL Anywhere ODBC driver "
              "here is 32-bit and will not load.", file=sys.stderr)

    con = connect()
    try:
        data = extract(con)
    finally:
        con.close()

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)

    c = data["counts"]
    print(f"extracted -> {args.out}")
    for k, v in c.items():
        print(f"  {k:20} {v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
