#ifndef SC_MACOS_TOOLBAR_H
#define SC_MACOS_TOOLBAR_H

#include "common.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <SDL3/SDL_video.h>

enum sc_toolbar_button {
    SC_TOOLBAR_BUTTON_BACK,
    SC_TOOLBAR_BUTTON_HOME,
    SC_TOOLBAR_BUTTON_APP_SWITCH,
    SC_TOOLBAR_BUTTON_NOTIFICATIONS,
    SC_TOOLBAR_BUTTON_SETTINGS,
    SC_TOOLBAR_BUTTON_ROTATE,
    SC_TOOLBAR_BUTTON_VOLUME_DOWN,
    SC_TOOLBAR_BUTTON_VOLUME_UP,
    SC_TOOLBAR_BUTTON_POWER,
    SC_TOOLBAR_BUTTON_DEV_MENU,   // React Native developer menu (MENU key)
    SC_TOOLBAR_BUTTON_DEV_RELOAD, // React Native reload (double 'R')
    SC_TOOLBAR_BUTTON_PASTE,      // paste the Mac clipboard on the device
    SC_TOOLBAR_BUTTON_COPY,       // copy the device clipboard to the Mac
    SC_TOOLBAR_BUTTON_TYPE_CLIPBOARD, // type the Mac clipboard as keystrokes
    SC_TOOLBAR_BUTTON_SCREEN_OFF, // turn the device display off, keep control
    SC_TOOLBAR_BUTTON_SCREEN_ON,  // turn the device display back on
};

// Device frame (bezel) drawn around the video. Keep in sync with the table in
// screen.c and the names in macos_toolbar.m.
enum sc_frame_style {
    SC_FRAME_NONE,
    SC_FRAME_PHONE_OBSIDIAN,
    SC_FRAME_PHONE_PORCELAIN,
    SC_FRAME_PHONE_HAZEL,
    SC_FRAME_PHONE_IRIS,
    SC_FRAME_PHONE_PEONY,
    SC_FRAME_THIN,
    // More colors of the phone (kept after SC_FRAME_THIN: saved preferences)
    SC_FRAME_PHONE_ROSE,
    SC_FRAME_PHONE_MINT,
    SC_FRAME_PHONE_BAY,
    SC_FRAME_PHONE_JADE,
    SC_FRAME_PHONE_LEMONGRASS,
    SC_FRAME_PHONE_SNOW,
    SC_FRAME_PHONE_CORAL,
    SC_FRAME_COUNT,
};

// Scale of the window, as the iOS Simulator offers
enum sc_scale_mode {
    SC_SCALE_PHYSICAL, // real size of the device on this display
    SC_SCALE_POINT,    // 1 dp of the device = 1 point of the Mac (100%)
    SC_SCALE_PIXEL,    // 1 pixel of the device = 1 pixel of the display
    SC_SCALE_FIT,      // as big as the display allows
    SC_SCALE_ZOOM,     // factor of the point accurate size
    SC_SCALE_STEP,     // factor of the current size (zoom in / out)
};

enum sc_rotate_direction {
    SC_ROTATE_TOGGLE, // portrait <-> landscape
    SC_ROTATE_LEFT,   // landscape (counterclockwise) <-> portrait
    SC_ROTATE_RIGHT,  // landscape (clockwise) <-> portrait
};

// Window geometry restored at startup (video area size, in window units)
struct sc_window_prefs {
    bool valid;
    bool has_position; // the position is only restored for known devices
    int x;
    int y;
    int width;
    int height;
};

// Called on the main thread when a toolbar button is clicked
typedef void (*sc_toolbar_callback)(enum sc_toolbar_button button,
                                    void *userdata);

// Called on the main thread when a frame style is selected from the menu
typedef void (*sc_frame_callback)(enum sc_frame_style style, void *userdata);

// Called when a phone shape is selected (index in the shapes of the frame, or
// -1 to follow the model of the device)
typedef void (*sc_shape_callback)(int shape, void *userdata);

// Called when a scale is selected from the menu
typedef void (*sc_scale_callback)(enum sc_scale_mode mode, float factor,
                                  void *userdata);

// Shapes of phone that the frame can draw (see the table in screen.c)
int
sc_frame_shape_count(void);

const char *
sc_frame_shape_name(int index);

// Height (in points) of the navigation bar embedded at the bottom of the
// window. The video is rendered above it.
#define SC_NAV_BAR_HEIGHT 60

// Attach a native toolbar to the titlebar of the given window and a navigation
// bar (back/home/recents and developer tools) at the bottom of its content.
//
// adb_executable and serial are used by the developer tools (screenshot,
// screen recording...), which run adb commands.
bool
sc_macos_toolbar_init(SDL_Window *window, sc_toolbar_callback callback,
                      sc_frame_callback frame_callback,
                      sc_shape_callback shape_callback,
                      sc_scale_callback scale_callback, void *userdata,
                      const char *adb_executable, const char *serial);

// Rotate the device itself: the rotation is locked to the chosen orientation
// (the automatic rotation only follows the sensor, so it can't be forced)
#ifdef __APPLE__
void
sc_macos_rotate_device(enum sc_rotate_direction direction);

// Give back the settings changed by the toolbar (screen timeout...). Must be
// called before the process exits.
void
sc_macos_toolbar_shutdown(void);
#else
static inline void
sc_macos_rotate_device(enum sc_rotate_direction direction) {
    (void) direction;
}

static inline void
sc_macos_toolbar_shutdown(void) {
}
#endif

// Files dropped on the window: APKs are installed, the rest is sent to the
// device. The hover callback shows (or hides) the drop target.
#ifdef __APPLE__
void
sc_macos_drop_file(const char *path);

void
sc_macos_drop_hover(bool on);
#else
static inline void
sc_macos_drop_file(const char *path) {
    (void) path;
}

static inline void
sc_macos_drop_hover(bool on) {
    (void) on;
}
#endif

// Persistent preferences (NSUserDefaults)
#ifdef __APPLE__
void
sc_prefs_load_window(struct sc_window_prefs *prefs);

void
sc_prefs_save_window(const struct sc_window_prefs *prefs);

enum sc_frame_style
sc_prefs_load_frame(void);

// Name of the phone shape chosen by the user (empty: follow the device)
void
sc_prefs_load_shape(char *buf, size_t size);

// Density of the device in dpi (wm density), 0 if unknown
int
sc_macos_device_density(void);

// Points per inch of the display where the window is
float
sc_macos_points_per_inch(SDL_Window *window);

// Background color of the window in the current appearance (light or dark)
void
sc_macos_window_background(uint8_t rgb[3]);

// Model of the device (ro.product.model). Runs adb synchronously: call it
// once, after sc_macos_toolbar_init().
bool
sc_macos_device_model(char *buf, size_t size);
#else
static inline void
sc_prefs_load_window(struct sc_window_prefs *prefs) {
    prefs->valid = false;
    prefs->has_position = false;
}

static inline void
sc_prefs_save_window(const struct sc_window_prefs *prefs) {
    (void) prefs;
}

static inline enum sc_frame_style
sc_prefs_load_frame(void) {
    return SC_FRAME_NONE;
}

static inline void
sc_prefs_load_shape(char *buf, size_t size) {
    if (size) {
        buf[0] = '\0';
    }
}

static inline int
sc_macos_device_density(void) {
    return 0;
}

static inline float
sc_macos_points_per_inch(SDL_Window *window) {
    (void) window;
    return 110.f;
}

static inline void
sc_macos_window_background(uint8_t rgb[3]) {
    rgb[0] = rgb[1] = rgb[2] = 0;
}

static inline bool
sc_macos_device_model(char *buf, size_t size) {
    (void) buf;
    (void) size;
    return false;
}
#endif

#endif
