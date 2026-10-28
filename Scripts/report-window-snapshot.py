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
    # A reply saved by Windows PowerShell 5.1 starts with a UTF-8 BOM.
    value = raw.lstrip("\ufeff").strip().splitlines()[-1].strip()
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
        print(("PASS  " if ok else "FAIL  ") + label.ljust(48) + "  " + detail)
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
    #
    # Dominance rather than an exact match, because a snapshot is allowed to be
    # colour-managed. WebView2's CapturePreview hands back pixels in the
    # *display's* space with that display's ICC profile embedded, so on a
    # wide-gamut monitor the page's #0000ff is stored as #2200ff — the same
    # colour, different numbers. This still fails a blank, black, white or
    # wrong-quadrant capture, which is what the check is for.
    def dominant(hexstr, channel):
        r, g, b = (int(hexstr[i:i + 2], 16) for i in (1, 3, 5))
        want = {"r": (r, g, b), "b": (b, r, g)}[channel]
        return want[0] > 200 and want[1] < 60 and want[2] < 60

    check("a pixel inside the mark is the mark's colour", dominant(value["inside"], "r"),
          "inside=%s (wanted a dominant red)" % value["inside"])
    check("a pixel outside it is the page behind", dominant(value["outside"], "b"),
          "outside=%s (wanted a dominant blue)" % value["outside"])
    if value["inside"] != "#ff0000" or value["outside"] != "#0000ff":
        print("      note: colour-managed capture - the page drew #ff0000/#0000ff and read back")
        print("            %s/%s, which is the same colour in a different space."
              % (value["inside"], value["outside"]))

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

    # `rect` (#255): the region's own size, and the region the page asked for
    # rather than one beside it.
    def region(label, q):
        check(label + ": its own size at the backing scale",
              abs(q["width"] - q["expectedWidth"]) <= 2 and abs(q["height"] - q["expectedHeight"]) <= 2,
              "got=%dx%d expected~%dx%d" % (q["width"], q["height"], q["expectedWidth"], q["expectedHeight"]))
        check(label + ": the mark only in its top-left quadrant",
              dominant(q["tl"], "r") and all(dominant(q[k], "b") for k in ("tr", "bl", "br")),
              "tl=%s tr=%s bl=%s br=%s" % (q["tl"], q["tr"], q["bl"], q["br"]))

    if "rect" in value:
        region("rect", value["rect"])
        edge = value["rectEdge"]
        check("rect off the edge is clipped to the viewport",
              abs(edge["width"] - edge["expectedWidth"]) <= 2,
              "width=%d expected~%d" % (edge["width"], edge["expectedWidth"]))
        scrolled = value["rectScrolled"]
        # The control for the row under it: a page that never scrolled can't
        # tell a viewport crop from a document one.
        check("rect on a scrolled page: the page scrolled", scrolled["scrollY"] > 0,
              "scrollY=%d" % scrolled["scrollY"])
        region("rect on a scrolled page", scrolled)
        region("rect without viewport-fit=cover", value["rectNoCover"])

    print()
    print("      round trip, page to page: snapshot, encode, bridge, decode, at %dx%d:" % (w, h))
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
    if "rectTiming" in value:
        print()
        print("      a rect of the top-left quarter against the whole window:")
        print("      " + "content".ljust(12) + "whole".rjust(18) + "quarter".rjust(18))
        for name, label in (("text", "body text"), ("noise", "noise")):
            t = value["rectTiming"][name]
            print("      " + label.ljust(12)
                  + ("%d ms / %d KiB" % (t["wholeMs"], t["wholeKib"])).rjust(18)
                  + ("%d ms / %d KiB" % (t["quarterMs"], t["quarterKib"])).rjust(18))
    print()
    sys.exit(failed)


if __name__ == "__main__":
    main()
