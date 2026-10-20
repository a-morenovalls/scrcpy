# Keyboard shortcuts of the macOS app

Generated from the real menus (`release/gen_shortcuts_doc.py`). ⌃ Control,
⌥ Option, ⇧ Shift, ⌘ Command. They avoid the ones of macOS and keep the ones that
scrcpy already had (⌘B back, ⌘S recents, ⌘N notifications, ⌘R rotate...).

Files dropped on the window are installed (`.apk`, `.apks`, `.xapk`) or sent to the
transfer folder (`/sdcard/Download` by default) and, if it is a single file, opened
on the device.

## App manager (Developer → App Manager…)

A window with the apps of the device (user apps, or system apps too) and, for the
selected one: open, restart, force stop, clear cache, clear data, disable/enable,
uninstall, app info, permissions, save the APK on the Mac and copy the package name.
Double click opens the app.

## Device info (Developer → Device Info…)

A live panel (refreshed every 3 seconds while it is visible) with the battery (level,
charging state, temperature, voltage, health), memory and swap, storage, temperatures
of the CPU, SoC, display and skin, Wi-Fi signal and speed, the app in the foreground,
load average and uptime, with small charts of the temperature and memory use.

## Window scale (Window → Scale)

As in the iOS Simulator: *Physical Size* (the real size of the device on this
display), *Point Accurate* (1 dp of the device = 1 point of the Mac), *Pixel
Accurate* (1 pixel = 1 pixel), *Fit Screen*, zoom in/out and fixed zooms.

## Phone frame (View → Device Frame)

Colors of the phone, and *Phone Shape*: the model of the device (default) or a
specific Pixel (3 to 9 Pro XL), a Samsung Galaxy or a generic phone.

## Mouse gestures

With the mouse over the device screen (two virtual fingers are drawn, one under
the cursor and the other mirrored through the center of the screen):

| Gesture | Action |
|---|---|
| Hold `⌘`, then click and drag | Pinch to zoom and rotate (`⌃` also works) |
| Hold `⇧`, then click and drag | Vertical tilt (two fingers sliding) |
| Hold `⇧⌘`, then click and drag | Horizontal tilt |
| Click a button on the right side of the phone frame | Volume up, volume down or power (with a *Phone* frame in View → Device Frame). Hold to keep it pressed, e.g. a long press on power. |

## Simulation (Developer menu)

Network (proxy, Wi-Fi, data, airplane), Display (screen size, density, font size)
and Battery and Power (level, charging, battery saver, Doze). Proxy, display and
battery changes are undone when the app closes (option *Undo These Changes When
Closing*), so the device is not left in a simulated state.

## Edit

| Option | Shortcut |
|---|---|
| Paste to Device | `⌥⌘V` |
| Type Clipboard as Keystrokes | `⌥⇧⌘V` |
| Copy from Device | `⌥⌘C` |

## Device

| Option | Shortcut |
|---|---|
| Back | `⌘B` |
| Home | `⇧⌘H` |
| Recents | `⌘S` |
| Notifications | `⌘N` |
| Settings Panel | `⌃⌘N` |
| Rotate Device | `⌘R` |
| Rotate Device Left | `⌥⌘←` |
| Rotate Device Right | `⌥⌘→` |
| Toggle Auto-Rotate | `⌥⌘R` |
| Volume Up | `⌥⌘↑` |
| Volume Down | `⌥⌘↓` |
| Power | `⌥⌘P` |
| Screenshot | `⌥⌘S` |
| Start Recording | `⇧⌘R` |
| Keep Device Awake | `⌥⌘A` |
| Stream Quality |  |
| &nbsp;&nbsp;↳ Auto (tuned for Wi-Fi) | `⌃⌘1` |
| &nbsp;&nbsp;↳ Wi-Fi Balanced — 6 Mbps, up to 1600 px | `⌃⌘2` |
| &nbsp;&nbsp;↳ Data Saver — 3 Mbps, 30 fps | `⌃⌘3` |
| &nbsp;&nbsp;↳ High Quality — 16 Mbps | `⌃⌘4` |
| &nbsp;&nbsp;↳ scrcpy Default | `⌃⌘5` |
| Frame Rate |  |
| &nbsp;&nbsp;↳ Auto (from the quality) | `⌃⌥⌘1` |
| &nbsp;&nbsp;↳ 30 fps | `⌃⌥⌘2` |
| &nbsp;&nbsp;↳ 45 fps | `⌃⌥⌘3` |
| &nbsp;&nbsp;↳ 60 fps | `⌃⌥⌘4` |
| &nbsp;&nbsp;↳ 90 fps | `⌃⌥⌘5` |
| &nbsp;&nbsp;↳ 120 fps | `⌃⌥⌘6` |
| Audio Output |  |
| &nbsp;&nbsp;↳ Play on Mac (default) | `⌥⇧⌘1` |
| &nbsp;&nbsp;↳ Play on Device | `⌥⇧⌘2` |
| &nbsp;&nbsp;↳ Play on Mac and Device | `⌥⇧⌘3` |
| Turn Device Screen Off | `⌥⌘O` |
| Turn Device Screen On | `⌥⇧⌘O` |
| Start With Device Screen Off | `⌃⌘O` |
| Copy Device ID | `⌃⌘I` |
| Copy ADB ID | `⌃⇧⌘I` |
| Copy Device Info |  |
| &nbsp;&nbsp;↳ ADB ID (the serial of adb -s) |  |
| &nbsp;&nbsp;↳ ADB command (adb -s …) | `⌃⌥⌘J` |
| &nbsp;&nbsp;↳ Device ID (hardware serial) |  |
| &nbsp;&nbsp;↳ Name | `⌃⌥⌘N` |
| &nbsp;&nbsp;↳ Model | `⌃⌥⌘M` |
| &nbsp;&nbsp;↳ Manufacturer | `⌃⌥⌘U` |
| &nbsp;&nbsp;↳ Brand | `⌃⌥⌘B` |
| &nbsp;&nbsp;↳ Codename | `⌃⌥⌘C` |
| &nbsp;&nbsp;↳ Android version | `⌃⌥⌘V` |
| &nbsp;&nbsp;↳ API level | `⌃⌥⌘P` |
| &nbsp;&nbsp;↳ Security patch | `⌃⌥⌘S` |
| &nbsp;&nbsp;↳ Build ID | `⌃⌥⌘D` |
| &nbsp;&nbsp;↳ Build fingerprint | `⌃⌥⌘F` |
| &nbsp;&nbsp;↳ Kernel | `⌃⌥⌘K` |
| &nbsp;&nbsp;↳ CPU architecture | `⌃⌥⌘A` |
| &nbsp;&nbsp;↳ Screen resolution | `⌃⌥⌘R` |
| &nbsp;&nbsp;↳ Screen density | `⌃⌥⌘E` |
| &nbsp;&nbsp;↳ Memory (RAM) | `⌃⌥⌘Y` |
| &nbsp;&nbsp;↳ Storage | `⌃⌥⌘T` |
| &nbsp;&nbsp;↳ Battery level | `⌃⌥⌘L` |
| &nbsp;&nbsp;↳ Wi-Fi IP address | `⌃⌥⌘W` |
| &nbsp;&nbsp;↳ Android ID | `⌃⌥⌘X` |
| &nbsp;&nbsp;↳ Language | `⌃⌥⌘G` |
| &nbsp;&nbsp;↳ Time zone | `⌃⌥⌘Z` |
| &nbsp;&nbsp;↳ Copy All | `⌃⌥⌘I` |
| Install APK… | `⇧⌘I` |
| Send Files to Device… | `⇧⌘O` |
| Transfer Folder |  |
| &nbsp;&nbsp;↳ /sdcard/Download | `⌃⌥⇧⌘1` |
| &nbsp;&nbsp;↳ /sdcard/Documents | `⌃⌥⇧⌘2` |
| &nbsp;&nbsp;↳ /sdcard/Pictures | `⌃⌥⇧⌘3` |
| &nbsp;&nbsp;↳ /sdcard/Movies | `⌃⌥⇧⌘4` |
| &nbsp;&nbsp;↳ /sdcard/Music | `⌃⌥⇧⌘5` |
| &nbsp;&nbsp;↳ /sdcard/DCIM | `⌃⌥⇧⌘6` |
| Open Files After Sending | `⌃⇧⌘O` |
| Grant Permissions When Installing | `⌃⇧⌘G` |
| Open Another Device… | `⇧⌘N` |
| Connect via Wi-Fi… | `⌥⇧⌘W` |
| Pair Device… | `⌥⇧⌘P` |
| Switch This Device to Wi-Fi | `⌃⌘W` |
| Disconnect Wi-Fi Device | `⌃⇧⌘W` |

## Developer

| Option | Shortcut |
|---|---|
| App Manager… | `⌃⌘X` |
| Device Info… | `⌃⌘G` |
| React Native Developer Menu | `⌥⌘M` |
| Reload React Native | `⌥⌘L` |
| Reverse Metro port (tcp:8081) | `⌃⌘M` |
| Open URL / deep link… | `⌃⌘U` |
| Clear app cache… | `⌃⌘K` |
| Open logcat in Terminal | `⌃⌘L` |
| Toggle animations | `⌃⌘A` |
| Toggle pointer location | `⌃⌘T` |
| Toggle dark mode | `⌃⇧⌘D` |
| Toggle show touches | `⌃⇧⌘T` |
| Toggle layout bounds | `⌃⌘B` |
| Open Developer options | `⌃⌘S` |
| Copy foreground activity | `⌃⌘J` |
| Network |  |
| &nbsp;&nbsp;↳ Set Proxy… | `⌃⌥⇧⌘P` |
| &nbsp;&nbsp;↳ Clear Proxy | `⌃⌥⇧⌘X` |
| &nbsp;&nbsp;↳ Show Current Proxy | `⌃⌥⇧⌘U` |
| &nbsp;&nbsp;↳ Toggle Wi-Fi | `⌃⌥⇧⌘W` |
| &nbsp;&nbsp;↳ Toggle Mobile Data | `⌃⌥⇧⌘D` |
| &nbsp;&nbsp;↳ Toggle Airplane Mode | `⌃⌥⇧⌘A` |
| Display |  |
| &nbsp;&nbsp;↳ Screen Size |  |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 720 × 1280 (HD) | `⌃⌥⇧⌘Q` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 1080 × 1920 (Full HD 16:9) | `⌃⌥⇧⌘E` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 1080 × 2400 (20:9) | `⌃⌥⇧⌘T` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 1440 × 3120 (QHD+) | `⌃⌥⇧⌘Y` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Custom… | `⌃⌥⇧⌘H` |
| &nbsp;&nbsp;↳ Density |  |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 280 dpi | `⌃⌥⇧⌘7` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 320 dpi | `⌃⌥⇧⌘8` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 420 dpi | `⌃⌥⇧⌘9` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 480 dpi | `⌃⌥⇧⌘0` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ 560 dpi | `⌃⌥⇧⌘Z` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Custom… | `⌃⌥⇧⌘J` |
| &nbsp;&nbsp;↳ Font Size |  |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Small (0.85×) | `⌃⌥⇧⌘B` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Default (1.0×) | `⌃⌥⇧⌘C` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Large (1.15×) | `⌃⌥⇧⌘F` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Larger (1.3×) | `⌃⌥⇧⌘G` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Largest (1.5×) | `⌃⌥⇧⌘I` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Huge (2.0×) | `⌃⌥⇧⌘K` |
| &nbsp;&nbsp;↳ Reset Size, Density and Font | `⌃⌥⇧⌘R` |
| Battery and Power |  |
| &nbsp;&nbsp;↳ Level 100% | `⌃⌥⇧⌘L` |
| &nbsp;&nbsp;↳ Level 50% | `⌃⌥⇧⌘M` |
| &nbsp;&nbsp;↳ Level 20% (low) | `⌃⌥⇧⌘N` |
| &nbsp;&nbsp;↳ Level 5% (critical) | `⌃⌥⇧⌘S` |
| &nbsp;&nbsp;↳ Charging | `⌃⌥⇧⌘V` |
| &nbsp;&nbsp;↳ Unplugged | `⌃⌥⇧⌘O` |
| &nbsp;&nbsp;↳ Battery Saver On | `⌃⌥⇧⌘,` |
| &nbsp;&nbsp;↳ Battery Saver Off | `⌃⌥⇧⌘.` |
| &nbsp;&nbsp;↳ Enter Doze | `⌃⌥⇧⌘/` |
| &nbsp;&nbsp;↳ Exit Doze | `⌃⌥⇧⌘;` |
| &nbsp;&nbsp;↳ Reset Battery Simulation | `⌃⌥⇧⌘'` |
| Undo These Changes When Closing | `⌃⌥⇧⌘]` |

## View

| Option | Shortcut |
|---|---|
| Device Frame |  |
| &nbsp;&nbsp;↳ None | `⌃⇧⌘0` |
| &nbsp;&nbsp;↳ Phone — Obsidian | `⌃⇧⌘1` |
| &nbsp;&nbsp;↳ Phone — Porcelain | `⌃⇧⌘2` |
| &nbsp;&nbsp;↳ Phone — Hazel | `⌃⇧⌘3` |
| &nbsp;&nbsp;↳ Phone — Iris | `⌃⇧⌘4` |
| &nbsp;&nbsp;↳ Phone — Peony | `⌃⇧⌘5` |
| &nbsp;&nbsp;↳ Phone — Rose | `⌃⇧⌘-` |
| &nbsp;&nbsp;↳ Phone — Mint | `⌃⇧⌘=` |
| &nbsp;&nbsp;↳ Phone — Bay | `⌃⇧⌘[` |
| &nbsp;&nbsp;↳ Phone — Jade | `⌃⇧⌘]` |
| &nbsp;&nbsp;↳ Phone — Lemongrass | `⌃⇧⌘;` |
| &nbsp;&nbsp;↳ Phone — Snow | `⌃⇧⌘'` |
| &nbsp;&nbsp;↳ Phone — Coral | `⌃⇧⌘,` |
| &nbsp;&nbsp;↳ Thin border | `⌃⇧⌘6` |
| &nbsp;&nbsp;↳ Phone Shape |  |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Auto (the model of the device) | `⌃⌥⇧⌘F1` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 9 Pro XL | `⌃⌥⇧⌘F2` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 9 Pro | `⌃⌥⇧⌘F3` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 9a | `⌃⌥⇧⌘F4` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 9 | `⌃⌥⇧⌘F5` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 8a | `⌃⌥⇧⌘F6` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 8 Pro | `⌃⌥⇧⌘F7` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 8 | `⌃⌥⇧⌘F8` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 7a | `⌃⌥⇧⌘F9` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 7 Pro | `⌃⌥⇧⌘F10` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 7 | `⌃⌥⇧⌘F11` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 6a | `⌃⌥⇧⌘F12` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 6 Pro | `⌃⌥⌘F1` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 6 | `⌃⌥⌘F2` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 5 | `⌃⌥⌘F3` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 4a | `⌃⌥⌘F4` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 4 XL | `⌃⌥⌘F5` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 4 | `⌃⌥⌘F6` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 3a | `⌃⌥⌘F7` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel 3 | `⌃⌥⌘F8` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Pixel (other) | `⌃⌥⌘F9` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Samsung Galaxy | `⌃⌥⌘F10` |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ Generic phone | `⌃⌥⌘F11` |

## Window

| Option | Shortcut |
|---|---|
| Keep on Top | `⌃⌘P` |
| Scale |  |
| &nbsp;&nbsp;↳ Physical Size | `⌘1` |
| &nbsp;&nbsp;↳ Point Accurate (100%) | `⌘2` |
| &nbsp;&nbsp;↳ Pixel Accurate | `⌘3` |
| &nbsp;&nbsp;↳ Fit Screen | `⌘4` |
| &nbsp;&nbsp;↳ Zoom In | `⌘=` |
| &nbsp;&nbsp;↳ Zoom Out | `⌘-` |
| &nbsp;&nbsp;↳ 200% | `⌥⌘1` |
| &nbsp;&nbsp;↳ 150% | `⌥⌘2` |
| &nbsp;&nbsp;↳ 75% | `⌥⌘3` |
| &nbsp;&nbsp;↳ 50% | `⌥⌘4` |
| &nbsp;&nbsp;↳ 33% | `⌥⌘5` |
| &nbsp;&nbsp;↳ 25% | `⌥⌘6` |
