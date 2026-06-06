#!/usr/bin/env python3
"""Generate a print-ready HTML page from manifests/generated/access-cards.csv.

Each row becomes one workshop access card with:
  - Student number (e.g. "s01")
  - QR code that resolves to the workspace URL
  - URL printed below the QR (fallback for manual typing)
  - Password in a monospace box (paste into code-server login)

Layout: 8 cards per page, US Letter, 2 columns × 4 rows, with dashed cut
lines. Page breaks every 8 cards.

Usage:
    pip install qrcode[pil]
    python3 scripts/generate-cards.py
    # → infra/manifests/generated/cards.html
    # Open that file in a browser → Print → Save as PDF or print to paper.

Options:
    --csv PATH    Override input CSV  (default: manifests/generated/access-cards.csv)
    --out PATH    Override output HTML (default: manifests/generated/cards.html)
"""

import argparse
import base64
import csv
import io
import sys
from pathlib import Path

try:
    import qrcode
except ImportError:
    print("ERROR: qrcode not installed. Run: pip install qrcode[pil]", file=sys.stderr)
    sys.exit(1)


def qr_data_uri(text: str, box_size: int = 6) -> str:
    qr = qrcode.QRCode(box_size=box_size, border=2)
    qr.add_data(text)
    qr.make()
    img = qr.make_image()
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


HTML_HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Workshop Access Cards</title>
<style>
  @page { size: letter; margin: 0.4in; }
  html, body { margin: 0; padding: 0; background: white;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif; }
  .grid { display: grid; grid-template-columns: repeat(2, 1fr);
          grid-template-rows: repeat(4, 1fr); gap: 8px; padding: 8px; }
  @media screen { .grid { width: 8.5in; height: 10.2in; box-sizing: border-box; margin: 0 auto; } }
  @media print  { .grid { height: 10.2in; page-break-after: always; } }
  .card { border: 1.5px dashed #999; border-radius: 8px; padding: 10px 12px;
          display: flex; flex-direction: column; align-items: center;
          justify-content: space-between; box-sizing: border-box; }
  .card .seat { font-size: 24pt; font-weight: 700; color: #111; letter-spacing: 1px; }
  .card .qr  { margin: 2px 0; }
  .card .qr img { width: 130px; height: 130px; display: block; }
  .card .url { font-size: 9pt; color: #555; word-break: break-all;
               text-align: center; max-width: 100%; }
  .card .label { font-size: 8pt; color: #888; margin-top: 4px;
                 text-transform: uppercase; letter-spacing: 0.5px; }
  .card .pw  { font-family: ui-monospace, 'SF Mono', Menlo, Consolas, monospace;
               font-size: 10pt; background: #f6f6f6; padding: 5px 9px;
               border-radius: 4px; word-break: break-all; text-align: center;
               max-width: 100%; box-sizing: border-box; }
  .note { padding: 10px 16px; color: #666; font-size: 10pt; }
  @media print { .note { display: none; } }
</style>
</head>
<body>
<div class="note">Tip: print double-sided OFF, then cut along dashed lines.
Each page has 8 cards.</div>
"""


def main() -> int:
    here = Path(__file__).resolve().parent
    default_csv = here.parent / "manifests" / "generated" / "access-cards.csv"
    default_out = here.parent / "manifests" / "generated" / "cards.html"

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--csv", default=str(default_csv))
    parser.add_argument("--out", default=str(default_out))
    args = parser.parse_args()

    csv_path = Path(args.csv).resolve()
    out_path = Path(args.out).resolve()

    if not csv_path.exists():
        print(f"ERROR: {csv_path} not found. Run ./scripts/generate-pods.sh first.",
              file=sys.stderr)
        return 1

    with csv_path.open() as f:
        reader = csv.reader(f)
        next(reader, None)  # header
        rows = [(n, url, pw) for n, url, pw in reader]

    if not rows:
        print(f"ERROR: no rows in {csv_path}", file=sys.stderr)
        return 1

    html: list[str] = [HTML_HEAD]
    for i in range(0, len(rows), 8):
        html.append('<div class="grid">')
        for n, url, pw in rows[i:i + 8]:
            html.append(
                '<div class="card">'
                f'<div class="seat">{n}</div>'
                f'<div class="qr"><img src="{qr_data_uri(url)}" /></div>'
                f'<div class="url">{url}</div>'
                '<div class="label">password</div>'
                f'<div class="pw">{pw}</div>'
                '</div>'
            )
        html.append("</div>")
    html.append("</body></html>")

    out_path.write_text("".join(html))
    print(f"Wrote {out_path}")
    print(f"  {len(rows)} cards across {(len(rows) + 7) // 8} pages")
    print(f"  Open in a browser → Print → Save as PDF (or send to printer).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
