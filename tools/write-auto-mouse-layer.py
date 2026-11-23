#!/usr/bin/env python3
"""Writes an Auto-Mouse Layer onto a Dygma Defy, as an alternative to building it in Bazecor.

    tools/write-auto-mouse-layer.py --dry-run     # show what would change
    tools/write-auto-mouse-layer.py               # write it
    tools/write-auto-mouse-layer.py --layer 7     # another layer (counted from 0; default 8)

It writes one layer of the keymap and its colours, and nothing else: LAYOUT below lists the
keys, every other key on the layer is left transparent (it does what the layer below does).
First it saves the whole keymap and colour map to ~/.local/state/dygma-auto-mouse-helper/backup/,
and afterwards it reads them back to check. Quit Bazecor first; the tool quits the helper
while it holds the keyboard's port and opens it again afterwards. (The helper's Layer tab
can put mouse clicks on the layer too; this tool also sets the layer's colours.)

Defy only (80 keys, 178 LEDs per layer). Edit LAYOUT and the colours to suit you.
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from focus import Focus  # noqa: E402

BUNDLE_ID = "io.github.harnoldcodes.dygma-auto-mouse-helper"
BACKUP_DIR = os.path.expanduser("~/.local/state/dygma-auto-mouse-helper/backup")
KEYS, LEDS = 80, 178  # per layer, on the Defy

# --- Key codes (Dygma's keymap numbers) --------------------------------------------------
# A plain key is its USB HID usage; a key with modifiers adds (flags << 8), with
# Ctrl = 0x01, Alt = 0x02, Right Alt = 0x04, Shift = 0x08, Cmd (GUI) = 0x10.
TRANSPARENT = 65535
CTRL, ALT, SHIFT, CMD = 0x0100, 0x0200, 0x0800, 0x1000
F = {n: 57 + n for n in range(1, 13)}      # F1 = 58 ... F12 = 69
F.update({n: 91 + n for n in range(13, 25)})  # F13 = 104 ... F24 = 115
MOUSE_UP, MOUSE_DOWN, MOUSE_LEFT, MOUSE_RIGHT = 20481, 20482, 20484, 20488
WHEEL_UP, WHEEL_DOWN, WHEEL_LEFT, WHEEL_RIGHT = 20497, 20498, 20500, 20504
CLICK_LEFT, CLICK_RIGHT, CLICK_MIDDLE, CLICK_BACK, CLICK_FORWARD = 20545, 20546, 20548, 20552, 20560
DIGIT = {n: 29 + n for n in range(1, 10)}  # 1 = 30 ... 9 = 38
DIGIT[0] = 39
TAB, KEY_W, KEY_T, END, ESC = 0x2B, 0x1A, 0x17, 0x4D, 0x29
LEFT_SHIFT, LEFT_ALT, LEFT_CMD = 225, 226, 227  # modifier keys on their own

# --- The layer ---------------------------------------------------------------------------
# Key position = row * 16 + column. Rows: 0 number row, 1 Q row, 2 A row, 3 Z row,
# 4 thumb keys. Columns count from the left: the left half is 0-6, the right half 9-15
# (on row 3 the left half is 0-5 and the right half 10-15; row 4 holds the 16 thumb keys).
# This example: Alt+1..Alt+0 on the number row (workspaces 1-10 in a tiling window manager
# such as AeroSpace or OmniWM), the scroll key (F20) on E, mouse movement and wheel on the
# right half, clicks on the left thumb keys and tab shortcuts on the Z row.
LAYOUT = {
    # left number row: Alt+1..Alt+5
    1: ALT | DIGIT[1], 2: ALT | DIGIT[2], 3: ALT | DIGIT[3], 4: ALT | DIGIT[4], 5: ALT | DIGIT[5],
    # left Q row: Esc on Q, the helper's scroll key (F20) on E
    17: ESC, 19: F[20],
    # left A row: back, Alt, Cmd, Shift, forward
    33: CLICK_BACK, 34: LEFT_ALT, 35: LEFT_CMD, 36: LEFT_SHIFT, 37: CLICK_FORWARD,
    # left Z row: middle click on C and B
    51: CLICK_MIDDLE, 53: CLICK_MIDDLE,
    # left thumbs: left click, right click (the two inner upper thumb keys)
    66: CLICK_LEFT, 67: CLICK_RIGHT,
    # right number row: Alt+6..Alt+0, F11
    10: ALT | DIGIT[6], 11: ALT | DIGIT[7], 12: ALT | DIGIT[8], 13: ALT | DIGIT[9], 14: ALT | DIGIT[0], 15: F[11],
    # right Q row: wheel up, wheel left, mouse up, wheel right, End, F12
    26: WHEEL_UP, 27: WHEEL_LEFT, 28: MOUSE_UP, 29: WHEEL_RIGHT, 30: END, 31: F[12],
    # right A row: wheel down, mouse left, down, right, forward
    42: WHEEL_DOWN, 43: MOUSE_LEFT, 44: MOUSE_DOWN, 45: MOUSE_RIGHT, 46: CLICK_FORWARD,
    # right Z row: close tab, previous tab, next tab, new tab, reopen tab (Ctrl shortcuts)
    58: CTRL | KEY_W, 59: CTRL | SHIFT | TAB, 61: CTRL | TAB, 62: CTRL | KEY_T, 63: CTRL | SHIFT | KEY_T,
}

# Colours, as (red, green, blue). The keyboard stores colours as numbers into its
# 16-colour palette (set in Bazecor), so each is shown as the nearest palette colour.
KEY_COLOUR = (255, 0, 0)       # keys the layer uses
UNUSED_COLOUR = (0, 0, 0)      # the layer's transparent keys
UNDERGLOW_COLOUR = (255, 0, 0)

# LED number of each key position (row, column), from Bazecor's Defy layout. LEDs 70-177
# are the underglow.
_ = None
LED = [
    [0, 1, 2, 3, 4, 5, 6, _, _, 41, 40, 39, 38, 37, 36, 35],
    [7, 8, 9, 10, 11, 12, 13, _, _, 48, 47, 46, 45, 44, 43, 42],
    [14, 15, 16, 17, 18, 19, 20, _, _, 55, 54, 53, 52, 51, 50, 49],
    [21, 22, 23, 24, 25, 26, _, _, _, _, 61, 60, 59, 58, 57, 56],
    [27, 28, 29, 30, 31, 32, 33, 34, 69, 68, 67, 66, 65, 64, 63, 62],
]


def nearest(palette, rgb):
    """Index of the palette colour closest to rgb. Palette entries are RGBW; the white
    channel is counted as adding to all three."""
    def rgb_of(e):
        w = e[3] if len(e) > 3 else 0
        return [min(255, c + w) for c in e[:3]]
    dist = [sum((a - b) ** 2 for a, b in zip(rgb_of(e), rgb)) for e in palette]
    return dist.index(min(dist))


def colours(palette):
    key, unused, glow = (nearest(palette, c) for c in (KEY_COLOUR, UNUSED_COLOUR, UNDERGLOW_COLOUR))
    for name, want, i in (("keys", KEY_COLOUR, key), ("unused keys", UNUSED_COLOUR, unused),
                          ("underglow", UNDERGLOW_COLOUR, glow)):
        print("%-12s %s -> palette %d %s" % (name, want, i, tuple(palette[i])))
    cm = [glow] * LEDS
    for r, row in enumerate(LED):
        for c, led in enumerate(row):
            if led is not None:
                cm[led] = key if r * 16 + c in LAYOUT else unused
    return cm


def helper_running():
    return subprocess.run(["pgrep", "-xq", "dygma-auto-mouse-helper"]).returncode == 0


def quit_helper():
    subprocess.run(["osascript", "-e", 'tell application id "%s" to quit' % BUNDLE_ID], capture_output=True)
    for _ in range(50):
        if not helper_running():
            return
        time.sleep(0.1)
    sys.exit("the helper didn't quit; quit it from its menu and try again")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--layer", type=int, default=8, help="layer to write, counted from 0 (default 8)")
    ap.add_argument("--dry-run", action="store_true", help="show what would change, write nothing")
    a = ap.parse_args()
    if subprocess.run(["pgrep", "-xq", "Bazecor"]).returncode == 0:
        sys.exit("Bazecor is running: quit it first (it holds the keyboard's port)")

    restart = helper_running()
    if restart:
        quit_helper()
    try:
        f = Focus()
        km = f.ints("keymap.custom")
        cm = f.ints("colormap.map")
        pal = f.ints("palette")
        layers = len(km) // KEYS
        if len(km) != layers * KEYS or len(cm) != layers * LEDS or not 0 <= a.layer < layers:
            sys.exit("unexpected keymap (%d values) or colour map (%d): is this a Defy, and layer %d in 0..%d?"
                     % (len(km), len(cm), a.layer, layers - 1))
        palette = [pal[i:i + 4] for i in range(0, len(pal), 4)]

        L = a.layer
        layer = [TRANSPARENT] * KEYS
        for pos, code in LAYOUT.items():
            layer[pos] = code
        km2 = km[:L * KEYS] + layer + km[(L + 1) * KEYS:]
        cm2 = cm[:L * LEDS] + colours(palette) + cm[(L + 1) * LEDS:]
        print("layer %d: %d keys and %d colours change"
              % (L, sum(x != y for x, y in zip(km, km2)), sum(x != y for x, y in zip(cm, cm2))))
        if a.dry_run:
            return

        os.makedirs(BACKUP_DIR, exist_ok=True)
        backup = os.path.join(BACKUP_DIR, "before-%s.json" % time.strftime("%Y%m%d-%H%M%S"))
        with open(backup, "w") as fh:
            json.dump({"keymap.custom": km, "colormap.map": cm}, fh)
        print("backup:", backup)

        f.cmd("keymap.custom " + " ".join(map(str, km2)))
        f.cmd("colormap.map " + " ".join(map(str, cm2)))
        ok = f.ints("keymap.custom") == km2 and f.ints("colormap.map") == cm2
        print("read back:", "OK" if ok else "MISMATCH (restore the backup with tools/focus.py)")
        if not ok:
            sys.exit(1)
    finally:
        if restart:
            subprocess.run(["open", "-g", "-b", BUNDLE_ID])


if __name__ == "__main__":
    main()
