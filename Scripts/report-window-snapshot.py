#!/usr/bin/env python3
"""Decode and report what `verify-window-snapshot.sh` measured.

Reads the driver's reply on stdin.

Split out of the shell script because `drive eval` returns JSON *inside* JSON
and the unwrapping is the part this project has got wrong three times by
pattern-matching the string instead.
"""

import base64
import json
import os
import sys


def decode(raw):
    # `drive` narrates its build on stdout; the result is the last line.
    value = raw.strip().splitlines()[-1].strip()
    for _ in range(4):
        if isinstance(value, dict):
            return value
        try:
            value = json.loads(value)
        except Exception:
            break
    return value if isinstance(value, dict) else None


def main():
    raw = sys.stdin.read()
    dump = sys.argv[sys.argv.index("--dump") + 1] if "--dump" in sys.argv else None
    value = decode(raw)
    if value is None:
        sys.exit("could not decode the probe's reply: " + repr(raw.strip()[-200:]))

    failed = 0

    if dump:
        for name, v in value.get("variants", {}).items():
            if not v.get("png"):
                continue
            path = os.path.join(dump, "%s.png" % name)
            with open(path, "wb") as fh:
                fh.write(base64.b64decode(v["png"]))
            print("wrote %s (%d bytes)" % (path, os.path.getsize(path)))

    def check(label, ok, detail):
        nonlocal failed
        print(("PASS  " if ok else "FAIL  ") + label.ljust(48) + detail)
        if not ok:
            failed = 1

    print()
    check("window.canSnapshot says yes", value.get("canSnapshot") is True,
          "canSnapshot=%s" % value.get("canSnapshot"))
    if value.get("canSnapshot") is not True:
        sys.exit(1)

    w, h = value["width"], value["height"]
    check("the header's size is the decoded image's size",
          (w, h) == (value["decodedWidth"], value["decodedHeight"]),
          "header=%dx%d decoded=%dx%d" % (w, h, value["decodedWidth"], value["decodedHeight"]))
    # Within a couple of pixels: a scrollbar or a rounded CSS size shifts it.
    check("the picture is the window at its backing scale",
          abs(w - value["expectedWidth"]) <= 2 and abs(h - value["expectedHeight"]) <= 2,
          "got=%dx%d expected~%dx%d" % (w, h, value["expectedWidth"], value["expectedHeight"]))
    # The control that gives the rest their meaning: a blank or black capture
    # decodes and measures perfectly well.
    check("a pixel inside the mark is the mark's colour", value["inside"] == "#ff0000",
          "inside=%s (wanted #ff0000)" % value["inside"])
    check("a pixel outside it is the page behind", value["outside"] == "#0000ff",
          "outside=%s (wanted #0000ff)" % value["outside"])

    # Each variant has to have actually reached the picture. GTK3 handed back a
    # `noise` frame smaller than its `text` one, which is only possible if the
    # canvas never made it in — and every other check passed regardless.
    variants = value["variants"]
    check("the text frame is the text, not the page under it",
          variants["text"]["sample"] not in ("#0000ff", variants["flat"]["sample"]),
          "sample=%s flat=%s" % (variants["text"]["sample"], variants["flat"]["sample"]))
    # A 32x32 patch of true noise holds close to 1024 distinct colours. The page
    # is asked for the same patch of its own canvas, so a thin `noise` frame
    # can be attributed: the backend resampled, or the page never painted.
    detail = variants["noise"]["detail"]
    canvas_detail = value.get("canvasDetail", 0)
    check("the noise frame carries the canvas's own detail",
          detail >= canvas_detail * 0.5 and variants["noise"]["kib"] > variants["text"]["kib"],
          "%d distinct colours in a 32x32 patch against %d in the page's own canvas, "
          "%d KiB against %d KiB for text"
          % (detail, canvas_detail, variants["noise"]["kib"], variants["text"]["kib"]))

    print()
    print("      round trip, page to page — snapshot, encode, bridge, decode, at %dx%d:" % (w, h))
    print("      " + "content".ljust(12) + "total".rjust(8) + "bridge".rjust(9) + "PNG".rjust(11))
    for name, label in (("flat", "flat"), ("text", "body text"), ("noise", "noise")):
        v = value["variants"].get(name)
        if not v:
            continue
        delivered = ""
        if abs(v.get("b64Bytes", 0) / 1024.0 - v["kib"]) > max(2, v["kib"] * 0.05):
            delivered = "   (%d KiB actually delivered)" % (v["b64Bytes"] / 1024)
        print("      " + label.ljust(12)
              + ("%d ms" % v["ms"]).rjust(8)
              + ("%d ms" % v["bridgeMs"]).rjust(9)
              + ("%d KiB" % v["kib"]).rjust(11) + delivered)
    print("      `flat` is a floor no real page reaches; `noise` is the ceiling.")
    print()
    sys.exit(failed)


if __name__ == "__main__":
    main()
