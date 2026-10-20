#!/usr/bin/env python3
"""Generate doc/macos_shortcuts.md from the real menus of the app.

Usage:
    SCRCPY_DUMP_MENU=/tmp/menu.txt <scrcpy binary> ...   # writes the menus
    release/gen_shortcuts_doc.py /tmp/menu.txt
"""
import collections
import sys

lines = open(sys.argv[1]).read().split('\n')
shortcuts = [l.split('\t')[1] for l in lines if '\t' in l and l.split('\t')[1]]
dups = [k for k, v in collections.Counter(shortcuts).items() if v > 1]
print("shortcuts:", len(shortcuts), "duplicates:", dups)

out = ["# Keyboard shortcuts of the macOS app", "",
"Generated from the real menus (`release/gen_shortcuts_doc.py`). ⌃ Control,",
"⌥ Option, ⇧ Shift, ⌘ Command. They avoid the ones of macOS and keep the ones that",
"scrcpy already had (⌘B back, ⌘S recents, ⌘N notifications, ⌘R rotate...).", "",
"Files dropped on the window are installed (`.apk`, `.apks`, `.xapk`) or sent to the",
"transfer folder (`/sdcard/Download` by default) and, if it is a single file, opened",
"on the device.", "",
"## App manager (Developer → App Manager…)", "",
"A window with the apps of the device (user apps, or system apps too) and, for the",
"selected one: open, restart, force stop, clear cache, clear data, disable/enable,",
"uninstall, app info, permissions, save the APK on the Mac and copy the package name.",
"Double click opens the app.", "",
"## Device info (Developer → Device Info…)", "",
"A live panel (refreshed every 3 seconds while it is visible) with the battery (level,",
"charging state, temperature, voltage, health), memory and swap, storage, temperatures",
"of the CPU, SoC, display and skin, Wi-Fi signal and speed, the app in the foreground,",
"load average and uptime, with small charts of the temperature and memory use.", "",
"## Window scale (Window → Scale)", "",
"As in the iOS Simulator: *Physical Size* (the real size of the device on this",
"display), *Point Accurate* (1 dp of the device = 1 point of the Mac), *Pixel",
"Accurate* (1 pixel = 1 pixel), *Fit Screen*, zoom in/out and fixed zooms.", "",
"## Phone frame (View → Device Frame)", "",
"Colors of the phone, and *Phone Shape*: the model of the device (default) or a",
"specific Pixel (3 to 9 Pro XL), a Samsung Galaxy or a generic phone.", "",
"## Mouse gestures", "",
"With the mouse over the device screen (two virtual fingers are drawn, one under",
"the cursor and the other mirrored through the center of the screen):", "",
"| Gesture | Action |", "|---|---|",
"| Hold `⌘`, then click and drag | Pinch to zoom and rotate (`⌃` also works) |",
"| Hold `⇧`, then click and drag | Vertical tilt (two fingers sliding) |",
"| Hold `⇧⌘`, then click and drag | Horizontal tilt |",
"| Click a button on the right side of the phone frame | Volume up, volume down or power (with a *Phone* frame in View → Device Frame). Hold to keep it pressed, e.g. a long press on power. |", "",
"## Simulation (Developer menu)", "",
"Network (proxy, Wi-Fi, data, airplane), Display (screen size, density, font size)",
"and Battery and Power (level, charging, battery saver, Doze). Proxy, display and",
"battery changes are undone when the app closes (option *Undo These Changes When",
"Closing*), so the device is not left in a simulated state."]

scale_titles = ("Scale", "Physical Size", "Point Accurate (100%)", "Pixel Accurate",
                "Fit Screen", "Zoom In", "Zoom Out", "200%", "150%", "75%", "50%",
                "33%", "25%")
section = None
for l in lines:
    if not l.strip() and '\t' not in l:
        continue
    title, sc = (l.split('\t') + [''])[:2]
    depth = (len(title) - len(title.lstrip())) // 2
    t = title.strip()
    if depth == 0:
        section = t
        if section in ("Edit", "Device", "Developer", "View", "Window"):
            out += ["", "## " + section, "", "| Option | Shortcut |", "|---|---|"]
        continue
    if section not in ("Edit", "Device", "Developer", "View", "Window"):
        continue
    if section == "Edit" and not (t.endswith("Device") or "Keystrokes" in t):
        continue
    if section == "Window" and not (t == "Keep on Top" or t in scale_titles):
        continue
    if depth >= 2:
        t = "&nbsp;" * (depth * 2 - 2) + "↳ " + t
    out.append("| %s | %s |" % (t, "`%s`" % sc if sc else ""))

open('doc/macos_shortcuts.md', 'w').write('\n'.join(out) + '\n')
print(len(out), "doc lines")
