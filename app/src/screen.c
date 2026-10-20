#include "screen.h"

#include <assert.h>
#include <math.h>
#include <string.h>
#include <SDL3/SDL.h>

#include "events.h"
#include "icon.h"
#include "adb/adb.h"
#include "macos_toolbar.h"
#include "options.h"
#include "util/log.h"
#include "util/sdl.h"

#define DISPLAY_MARGINS 96

#define DOWNCAST(SINK) container_of(SINK, struct sc_screen, frame_sink)

static void
frame_pads_for_width(const struct sc_screen *screen, uint16_t view_width,
                     uint16_t *pad_x, uint16_t *pad_top, uint16_t *pad_bottom,
                     float *fs);
static void
sc_screen_set_frame_for_width(struct sc_screen *screen, uint16_t view_width);
static uint16_t
sc_screen_view_width_for_window(const struct sc_screen *screen,
                                uint16_t window_width);

// get the size of the area where the video is rendered (the window without the
// native bottom bar and the frame of the phone)
static inline struct sc_size
get_view_size(struct sc_screen *screen) {
    struct sc_size size = sc_sdl_get_window_size(screen->window);
    // The frame scales with the window: its thickness depends on the width
    uint16_t view_width = sc_screen_view_width_for_window(screen, size.width);
    sc_screen_set_frame_for_width(screen, view_width);
    size.width = view_width;
    uint16_t extra_h = screen->frame_pad_top + screen->frame_pad_bottom
                     + screen->bottom_inset;
    size.height = size.height > extra_h ? size.height - extra_h : 1;
    return size;
}

static inline void
set_view_size(struct sc_screen *screen, struct sc_size size) {
    sc_screen_set_frame_for_width(screen, size.width);
    size.width += 2 * screen->frame_pad_x;
    size.height += screen->frame_pad_top + screen->frame_pad_bottom
                 + screen->bottom_inset;
    sc_sdl_set_window_size(screen->window, size);
}

// view_size is the size of the area where the video is rendered
static void
set_aspect_ratio(struct sc_screen *screen, struct sc_size view_size) {
    assert(view_size.width && view_size.height);

    if (screen->window_aspect_ratio_lock) {
        uint16_t pad_x, pad_top, pad_bottom;
        float fs;
        frame_pads_for_width(screen, view_size.width, &pad_x, &pad_top,
                             &pad_bottom, &fs);
        float ar = (float) (view_size.width + 2 * pad_x)
                 / (view_size.height + pad_top + pad_bottom
                                     + screen->bottom_inset);
        bool ok = SDL_SetWindowAspectRatio(screen->window, ar, ar);
        if (!ok) {
            LOGW("Could not set window aspect ratio: %s", SDL_GetError());
        }
    }
}

static inline struct sc_size
get_oriented_size(struct sc_size size, enum sc_orientation orientation) {
    struct sc_size oriented_size;
    if (sc_orientation_is_swap(orientation)) {
        oriented_size.width = size.height;
        oriented_size.height = size.width;
    } else {
        oriented_size.width = size.width;
        oriented_size.height = size.height;
    }
    return oriented_size;
}

static inline bool
is_windowed(struct sc_screen *screen) {
    return !(SDL_GetWindowFlags(screen->window) & (SDL_WINDOW_FULLSCREEN
                                                 | SDL_WINDOW_MINIMIZED
                                                 | SDL_WINDOW_MAXIMIZED));
}

// Space taken by the native bar and the device frame, which is not available
// for the video (single window per process)
static uint16_t display_chrome_width;
static uint16_t display_chrome_height;

// get the preferred display bounds (i.e. the screen bounds with some margins)
static bool
get_preferred_display_bounds(struct sc_size *bounds) {
    SDL_Rect rect;
    SDL_DisplayID display = SDL_GetPrimaryDisplay();
    if (!display) {
        LOGW("Could not get primary display: %s", SDL_GetError());
        return false;
    }

    bool ok = SDL_GetDisplayUsableBounds(display, &rect);
    if (!ok) {
        LOGW("Could not get display usable bounds: %s", SDL_GetError());
        return false;
    }

    bounds->width = MAX(0, rect.w - DISPLAY_MARGINS - display_chrome_width);
    bounds->height = MAX(0, rect.h - DISPLAY_MARGINS - display_chrome_height);
    return true;
}

static bool
is_optimal_size(struct sc_size current_size, struct sc_size content_size) {
    // The size is optimal if we can recompute one dimension of the current
    // size from the other
    return current_size.height == (uint32_t) current_size.width
                                * content_size.height / content_size.width
        || current_size.width == (uint32_t) current_size.height
                               * content_size.width / content_size.height;
}

// return the optimal size of the window, with the following constraints:
//  - it attempts to keep at least one dimension of the current_size (i.e. it
//    crops the black borders)
//  - it keeps the aspect ratio
//  - it scales down to make it fit in the display_size
static struct sc_size
get_optimal_size(struct sc_size current_size, struct sc_size content_size,
                 bool within_display_bounds) {
    if (content_size.width == 0 || content_size.height == 0) {
        // avoid division by 0
        return current_size;
    }

    struct sc_size window_size;

    struct sc_size display_size;
    if (!within_display_bounds ||
            !get_preferred_display_bounds(&display_size)) {
        // do not constraint the size
        window_size = current_size;
    } else {
        window_size.width = MIN(current_size.width, display_size.width);
        window_size.height = MIN(current_size.height, display_size.height);
    }

    if (is_optimal_size(window_size, content_size)) {
        return window_size;
    }

    bool keep_width = (uint32_t) content_size.width * window_size.height
                    > (uint32_t) content_size.height * window_size.width;
    if (keep_width) {
        // remove black borders on top and bottom
        window_size.height = (uint32_t) content_size.height * window_size.width
                           / content_size.width;
    } else {
        // remove black borders on left and right (or none at all if it already
        // fits)
        window_size.width = (uint32_t) content_size.width * window_size.height
                          / content_size.height;
    }

    return window_size;
}

// initially, there is no current size, so use the frame size as current size
// req_width and req_height, if not 0, are the sizes requested by the user
static inline struct sc_size
get_initial_optimal_size(struct sc_size content_size, uint16_t req_width,
                         uint16_t req_height) {
    struct sc_size window_size;
    if (!req_width && !req_height) {
        window_size = get_optimal_size(content_size, content_size, true);
    } else {
        if (req_width) {
            window_size.width = req_width;
        } else {
            // compute from the requested height
            window_size.width = (uint32_t) req_height * content_size.width
                              / content_size.height;
        }
        if (req_height) {
            window_size.height = req_height;
        } else {
            // compute from the requested width
            window_size.height = (uint32_t) req_width * content_size.height
                               / content_size.width;
        }
    }
    return window_size;
}

static inline void
sc_screen_track_resize(struct sc_screen *screen, struct sc_size size) {
    LOGV("Track resize: %" PRIu16 "x%" PRIu16, size.width, size.height);
    screen->resize_tracker.time = sc_tick_now();
    screen->resize_tracker.size = size;
}

static bool
sc_screen_set_texture_from_surface(struct sc_screen *screen,
                                   SDL_Surface *surface) {
    // The current "frame" texture can be discarded
    sc_texture_reset(&screen->tex);

    if (screen->icon_tex) {
        SDL_DestroyTexture(screen->icon_tex);
    }

    screen->icon_tex = SDL_CreateTextureFromSurface(screen->renderer, surface);
    if (!screen->icon_tex) {
        LOGE("Could not create texture from surface: %s", SDL_GetError());
        return false;
    }

    // Once is_icon_active is true, it may never become false again
    screen->is_icon_active = true;

    return true;
}

static inline bool
sc_screen_is_relative_mode(struct sc_screen *screen) {
    // screen->im.mp may be NULL if --no-control
    return screen->im.mp && screen->im.mp->relative_mode;
}

static void
compute_content_rect(struct sc_size window_size, struct sc_size content_size,
                     bool is_icon, enum sc_render_fit render_fit,
                     SDL_FRect *rect) {
    // Only upscale video frames, not icon
    if (is_icon) {
        if (content_size.width <= window_size.width
                && content_size.height <= window_size.height) {
            // Center without upscaling
            rect->x = (window_size.width - content_size.width) / 2.f;
            rect->y = (window_size.height - content_size.height) / 2.f;
            rect->w = content_size.width;
            rect->h = content_size.height;
            return;
        }
    } else if (render_fit == SC_RENDER_FIT_UNSCALED) {
        // Cast to float first because input sizes are unsigned
        float x = ((float) window_size.width - content_size.width) / 2.f;
        float y = ((float) window_size.height - content_size.height) / 2.f;
        rect->x = MAX(0, x);
        rect->y = MAX(0, y);
        rect->w = content_size.width;
        rect->h = content_size.height;
        return;
    } else if (render_fit == SC_RENDER_FIT_STRETCHED) {
        rect->x = 0;
        rect->y = 0;
        rect->w = window_size.width;
        rect->h = window_size.height;
        return;
    }

    assert(is_icon || render_fit == SC_RENDER_FIT_LETTERBOX);

    if (is_optimal_size(window_size, content_size)) {
        rect->x = 0;
        rect->y = 0;
        rect->w = window_size.width;
        rect->h = window_size.height;
        return;
    }

    bool keep_width = (uint32_t) content_size.width * window_size.height
                    > (uint32_t) content_size.height * window_size.width;
    if (keep_width) {
        rect->x = 0;
        rect->w = window_size.width;
        rect->h = (float) window_size.width * content_size.height
                                            / content_size.width;
        rect->y = (window_size.height - rect->h) / 2.f;
    } else {
        rect->y = 0;
        rect->h = window_size.height;
        rect->w = (float) window_size.height * content_size.width
                                             / content_size.height;
        rect->x = (window_size.width - rect->w) / 2.f;
    }
}

static void
sc_screen_update_content_rect(struct sc_screen *screen) {
    struct sc_size window_size = get_view_size(screen);
    compute_content_rect(window_size, screen->content_size,
                         screen->is_icon_active, screen->render_fit,
                         &screen->rect);
    // The video area is surrounded by the device frame
    screen->rect.x += screen->frame_pad_x;
    screen->rect.y += screen->frame_pad_top;
}

// Shape of the phone drawn around the video. The model of the device selects
// the profile (bezel thickness, corner radius, camera cutout...).
struct sc_device_profile {
    const char *name;       // shown in the menu
    const char *match;      // substring of ro.product.model, NULL: default
    uint8_t bezel_side;     // black bezel around the screen, in window units
    uint8_t bezel_top;
    uint8_t bezel_bottom;
    uint8_t margin;         // window background between the phone and the edge
    uint8_t rim;            // colored metal edge of the phone
    float screen_radius;    // corner radius of the screen, relative to its width
    float hole_x;           // camera cutout center, relative to the width; <0:
                            // no cutout
    float hole_y;           // relative to the width, from the top of the screen
    float hole_radius;      // relative to the width
    bool forehead;          // earpiece slot on a thick top bezel (old Pixels)
};

#define MARGIN 7
#define RIM 3

// The specific models come first: the first match wins ("Pixel 9a" before
// "Pixel 9"...). The last entry is the default.
static const struct sc_device_profile DEVICE_PROFILES[] = {
    {"Pixel 9 Pro XL", "Pixel 9 Pro XL", 10, 10, 10, MARGIN, RIM, 0.115f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 9 Pro",    "Pixel 9 Pro",    10, 10, 10, MARGIN, RIM, 0.115f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 9a",       "Pixel 9a",       20, 20, 20, MARGIN, RIM, 0.095f, 0.5f, 0.040f, 0.014f, false},
    {"Pixel 9",        "Pixel 9",        11, 11, 11, MARGIN, RIM, 0.115f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 8a",       "Pixel 8a",       15, 15, 15, MARGIN, RIM, 0.105f, 0.5f, 0.036f, 0.013f, false},
    {"Pixel 8 Pro",    "Pixel 8 Pro",    10, 10, 10, MARGIN, RIM, 0.115f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 8",        "Pixel 8",        12, 12, 12, MARGIN, RIM, 0.115f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 7a",       "Pixel 7a",       15, 15, 16, MARGIN, RIM, 0.095f, 0.5f, 0.036f, 0.013f, false},
    {"Pixel 7 Pro",    "Pixel 7 Pro",    10, 10, 10, MARGIN, RIM, 0.110f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 7",        "Pixel 7",        13, 13, 13, MARGIN, RIM, 0.105f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 6a",       "Pixel 6a",       14, 15, 18, MARGIN, RIM, 0.085f, 0.5f, 0.036f, 0.013f, false},
    {"Pixel 6 Pro",    "Pixel 6 Pro",    10, 10, 10, MARGIN, RIM, 0.105f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 6",        "Pixel 6",        14, 14, 15, MARGIN, RIM, 0.095f, 0.5f, 0.034f, 0.013f, false},
    {"Pixel 5",        "Pixel 5",        12, 12, 16, MARGIN, RIM, 0.075f, 0.075f, 0.027f, 0.013f, false},
    {"Pixel 4a",       "Pixel 4a",       13, 14, 17, MARGIN, RIM, 0.070f, 0.075f, 0.027f, 0.013f, false},
    {"Pixel 4 XL",     "Pixel 4 XL",     14, 40, 19, MARGIN, RIM, 0.060f, -1.f, 0.f, 0.f, true},
    {"Pixel 4",        "Pixel 4",        14, 38, 18, MARGIN, RIM, 0.060f, -1.f, 0.f, 0.f, true},
    {"Pixel 3a",       "Pixel 3a",       14, 30, 32, MARGIN, RIM, 0.070f, -1.f, 0.f, 0.f, true},
    {"Pixel 3",        "Pixel 3",        14, 30, 32, MARGIN, RIM, 0.070f, -1.f, 0.f, 0.f, true},
    {"Pixel (other)",  "Pixel",          12, 12, 12, MARGIN, RIM, 0.115f, 0.5f, 0.034f, 0.013f, false},
    {"Samsung Galaxy", "SM-",            12, 12, 12, MARGIN, RIM, 0.095f, 0.5f, 0.030f, 0.012f, false},
    {"Generic phone",  NULL,             13, 13, 13, MARGIN, RIM, 0.095f, 0.5f, 0.034f, 0.013f, false},
};

#define DEVICE_PROFILE_COUNT \
    (sizeof(DEVICE_PROFILES) / sizeof(DEVICE_PROFILES[0]))

int
sc_frame_shape_count(void) {
    return (int) DEVICE_PROFILE_COUNT;
}

const char *
sc_frame_shape_name(int index) {
    return index >= 0 && index < (int) DEVICE_PROFILE_COUNT
         ? DEVICE_PROFILES[index].name : "";
}

static const struct sc_device_profile *
find_device_profile(const char *model) {
    const struct sc_device_profile *p = DEVICE_PROFILES;
    for (; p->match; ++p) {
        if (model && strstr(model, p->match)) {
            return p;
        }
    }
    return p; // default
}

// Profile drawn by the frame: the shape chosen by the user, else the one of
// the model of the device
static const struct sc_device_profile *
get_profile(const struct sc_screen *screen) {
    if (screen->frame_shape >= 0
            && screen->frame_shape < (int) DEVICE_PROFILE_COUNT) {
        return &DEVICE_PROFILES[screen->frame_shape];
    }
    return find_device_profile(screen->device_model);
}

// Space of the frame (margin + rim + bezel) on each side, in window units
static inline uint16_t
profile_pad_x(const struct sc_device_profile *p) {
    return p->margin + p->rim + p->bezel_side;
}

static inline uint16_t
profile_pad_top(const struct sc_device_profile *p) {
    return p->margin + p->rim + p->bezel_top;
}

static inline uint16_t
profile_pad_bottom(const struct sc_device_profile *p) {
    return p->margin + p->rim + p->bezel_bottom;
}

#define THIN_FRAME_PADDING 4

// Colors of the edge of the phone, indexed by enum sc_frame_style
static const uint8_t PHONE_RIM_COLORS[SC_FRAME_COUNT][3] = {
    [SC_FRAME_PHONE_OBSIDIAN]  = {0x34, 0x34, 0x38},
    [SC_FRAME_PHONE_PORCELAIN] = {0xd9, 0xd4, 0xc9},
    [SC_FRAME_PHONE_HAZEL]     = {0x70, 0x7e, 0x67},
    [SC_FRAME_PHONE_IRIS]      = {0x9a, 0xa0, 0xe6},
    [SC_FRAME_PHONE_PEONY]     = {0xe9, 0xa9, 0xbd},
    [SC_FRAME_PHONE_ROSE]      = {0xe4, 0xbf, 0xc2},
    [SC_FRAME_PHONE_MINT]      = {0xa9, 0xd3, 0xbd},
    [SC_FRAME_PHONE_BAY]       = {0x86, 0xb0, 0xd6},
    [SC_FRAME_PHONE_JADE]      = {0x6f, 0xa3, 0x8a},
    [SC_FRAME_PHONE_LEMONGRASS] = {0xd5, 0xdc, 0x74},
    [SC_FRAME_PHONE_SNOW]      = {0xee, 0xee, 0xf0},
    [SC_FRAME_PHONE_CORAL]     = {0xe8, 0x7a, 0x6a},
};

static inline bool
is_phone_frame(uint8_t style) {
    return style != SC_FRAME_NONE && style != SC_FRAME_THIN
        && style < SC_FRAME_COUNT;
}

// The frame of the phone is drawn for a video 411 units wide (the size of a
// phone screen in dp). In a smaller window, the whole frame (bezel, edge,
// buttons) shrinks with it, so that the phone looks the same at every scale;
// in a bigger one it keeps its reference size.
#define FRAME_REFERENCE_WIDTH 411

static void
frame_pads_for_width(const struct sc_screen *screen, uint16_t view_width,
                     uint16_t *pad_x, uint16_t *pad_top, uint16_t *pad_bottom,
                     float *fs) {
    *fs = 1.f;
    if (screen->frame_style == SC_FRAME_NONE) {
        *pad_x = *pad_top = *pad_bottom = 0;
    } else if (screen->frame_style == SC_FRAME_THIN) {
        *pad_x = *pad_top = *pad_bottom = THIN_FRAME_PADDING;
    } else {
        const struct sc_device_profile *p = get_profile(screen);
        if (view_width < FRAME_REFERENCE_WIDTH) {
            *fs = MAX(0.25f, (float) view_width / FRAME_REFERENCE_WIDTH);
        }
        *pad_x = (uint16_t) lroundf(profile_pad_x(p) * *fs);
        *pad_top = (uint16_t) lroundf(profile_pad_top(p) * *fs);
        *pad_bottom = (uint16_t) lroundf(profile_pad_bottom(p) * *fs);
    }
}

static void
sc_screen_set_frame_for_width(struct sc_screen *screen, uint16_t view_width) {
    frame_pads_for_width(screen, view_width, &screen->frame_pad_x,
                         &screen->frame_pad_top, &screen->frame_pad_bottom,
                         &screen->frame_fs);
}

// Width of the video for a window width: the inverse of "video + frame"
static uint16_t
sc_screen_view_width_for_window(const struct sc_screen *screen,
                                uint16_t window_width) {
    if (screen->frame_style == SC_FRAME_NONE
            || screen->frame_style == SC_FRAME_THIN) {
        uint16_t pad = screen->frame_style == SC_FRAME_THIN
                     ? THIN_FRAME_PADDING : 0;
        return window_width > 2 * pad ? window_width - 2 * pad : 1;
    }

    const struct sc_device_profile *p = get_profile(screen);
    uint16_t full_pad = profile_pad_x(p);
    if (window_width >= FRAME_REFERENCE_WIDTH + 2 * full_pad) {
        return window_width - 2 * full_pad; // frame at its reference size
    }

    // Smaller window: width = video + 2 * round(full_pad * video / 411)
    float k = (float) full_pad / FRAME_REFERENCE_WIDTH;
    int guess = (int) lroundf(window_width / (1.f + 2.f * k));
    int best = MAX(1, guess);
    int best_diff = 1 << 30;
    for (int c = MAX(1, guess - 2); c <= guess + 2; ++c) {
        float fs = MAX(0.25f, (float) c / FRAME_REFERENCE_WIDTH);
        int total = c + 2 * (int) lroundf(full_pad * fs);
        int diff = abs(total - (int) window_width);
        if (diff < best_diff) {
            best_diff = diff;
            best = c;
        }
    }
    return (uint16_t) best;
}

// Space of the frame at its reference size, which the window may use at most
static void
sc_screen_apply_frame_padding(struct sc_screen *screen, uint16_t view_width) {
    assert(screen->frame_style < SC_FRAME_COUNT);
    sc_screen_set_frame_for_width(screen, view_width);

    uint16_t ref_x = 0, ref_top = 0, ref_bottom = 0;
    if (screen->frame_style == SC_FRAME_THIN) {
        ref_x = ref_top = ref_bottom = THIN_FRAME_PADDING;
    } else if (screen->frame_style != SC_FRAME_NONE) {
        const struct sc_device_profile *p = get_profile(screen);
        ref_x = profile_pad_x(p);
        ref_top = profile_pad_top(p);
        ref_bottom = profile_pad_bottom(p);
    }
    display_chrome_width = 2 * ref_x;
    display_chrome_height = ref_top + ref_bottom + screen->bottom_inset;
}

#define FRAME_ARC_SEGMENTS 16

static inline SDL_FColor
fcolor(const uint8_t rgb[3]) {
    return (SDL_FColor) {rgb[0] / 255.f, rgb[1] / 255.f, rgb[2] / 255.f, 1.f};
}

// Fill the area of the square (corner, corner + radius) that lies outside of
// the circle of the given center: it is used to round the corners of the video
static void
render_corner_mask(SDL_Renderer *renderer, SDL_FColor color, float cx,
                   float cy, float corner_x, float corner_y, float radius,
                   float start_angle) {
    SDL_Vertex verts[FRAME_ARC_SEGMENTS * 3];
    const float quarter = 1.57079632679f;
    for (int i = 0; i < FRAME_ARC_SEGMENTS; ++i) {
        float a0 = start_angle + quarter * i / FRAME_ARC_SEGMENTS;
        float a1 = start_angle + quarter * (i + 1) / FRAME_ARC_SEGMENTS;
        SDL_Vertex *v = &verts[i * 3];
        v[0].position = (SDL_FPoint) {corner_x, corner_y};
        v[1].position = (SDL_FPoint) {cx + radius * cosf(a0),
                                      cy + radius * sinf(a0)};
        v[2].position = (SDL_FPoint) {cx + radius * cosf(a1),
                                      cy + radius * sinf(a1)};
        for (int k = 0; k < 3; ++k) {
            v[k].color = color;
            v[k].tex_coord = (SDL_FPoint) {0, 0};
        }
    }
    SDL_RenderGeometry(renderer, NULL, verts, FRAME_ARC_SEGMENTS * 3, NULL, 0);
}

static void
render_disc(SDL_Renderer *renderer, SDL_FColor color, float cx, float cy,
            float radius) {
    SDL_Vertex verts[FRAME_ARC_SEGMENTS * 4 * 3];
    const float two_pi = 6.28318530718f;
    int n = FRAME_ARC_SEGMENTS * 4;
    for (int i = 0; i < n; ++i) {
        float a0 = two_pi * i / n;
        float a1 = two_pi * (i + 1) / n;
        SDL_Vertex *v = &verts[i * 3];
        v[0].position = (SDL_FPoint) {cx, cy};
        v[1].position = (SDL_FPoint) {cx + radius * cosf(a0),
                                      cy + radius * sinf(a0)};
        v[2].position = (SDL_FPoint) {cx + radius * cosf(a1),
                                      cy + radius * sinf(a1)};
        for (int k = 0; k < 3; ++k) {
            v[k].color = color;
            v[k].tex_coord = (SDL_FPoint) {0, 0};
        }
    }
    SDL_RenderGeometry(renderer, NULL, verts, n * 3, NULL, 0);
}

// Fill a rounded rectangle (convex: drawn as a fan from its center)
static void
render_round_rect(SDL_Renderer *renderer, SDL_FColor color, float x, float y,
                  float w, float h, float radius) {
    enum { SEG = 12, POINTS = 4 * (SEG + 1) };
    SDL_FPoint pts[POINTS];
    const float quarter = 1.57079632679f;
    const float pi = 3.14159265359f;
    // corner centers and start angles: top-left, top-right, bottom-right,
    // bottom-left
    const float cx[4] = {x + radius, x + w - radius, x + w - radius, x + radius};
    const float cy[4] = {y + radius, y + radius, y + h - radius, y + h - radius};
    const float start[4] = {pi, 1.5f * pi, 0, 0.5f * pi};
    int n = 0;
    for (int c = 0; c < 4; ++c) {
        for (int i = 0; i <= SEG; ++i) {
            float a = start[c] + quarter * i / SEG;
            pts[n++] = (SDL_FPoint) {cx[c] + radius * cosf(a),
                                     cy[c] + radius * sinf(a)};
        }
    }

    SDL_Vertex verts[POINTS * 3];
    SDL_FPoint center = {x + w / 2, y + h / 2};
    for (int i = 0; i < POINTS; ++i) {
        SDL_Vertex *v = &verts[i * 3];
        v[0].position = center;
        v[1].position = pts[i];
        v[2].position = pts[(i + 1) % POINTS];
        for (int k = 0; k < 3; ++k) {
            v[k].color = color;
            v[k].tex_coord = (SDL_FPoint) {0, 0};
        }
    }
    SDL_RenderGeometry(renderer, NULL, verts, POINTS * 3, NULL, 0);
}

static const uint8_t BEZEL_COLOR[3] = {0x05, 0x05, 0x06};

// Rectangle of the body of the phone from the rectangle of the video (x, y, w,
// h), in the same units. scale converts window units into those units.
static void
phone_body_rect(const struct sc_device_profile *prof, float x, float y,
                float w, float h, float scale, float *bx, float *by,
                float *bw, float *bh) {
    float pad_x = profile_pad_x(prof) * scale;
    float pad_top = profile_pad_top(prof) * scale;
    float pad_bottom = profile_pad_bottom(prof) * scale;
    float margin = prof->margin * scale;
    *bx = x - pad_x + margin;
    *by = y - pad_top + margin;
    *bw = w + 2 * (pad_x - margin);
    *bh = h + (pad_top - margin) + (pad_bottom - margin);
}

// Geometry of the hardware buttons on the right edge of the phone, from the
// rectangle of the video. draw is the visible part, hit the area that reacts
// to the mouse (bigger, over the bezel).
static void
phone_side_rects(const struct sc_device_profile *prof, float x, float y,
                 float w, float h, float scale, SDL_FRect draw[SC_SIDE_COUNT],
                 SDL_FRect hit[SC_SIDE_COUNT]) {
    float bx, by, bw, bh;
    phone_body_rect(prof, x, y, w, h, scale, &bx, &by, &bw, &bh);
    float margin = prof->margin * scale;
    float right = bx + bw;

    // Pixel layout: volume rocker (up, down) above the power button
    const float top[SC_SIDE_COUNT] = {0.17f, 0.255f, 0.38f};
    const float height[SC_SIDE_COUNT] = {0.07f, 0.07f, 0.06f};
    float protrusion = (prof->margin - 1) * scale;
    for (int i = 0; i < SC_SIDE_COUNT; ++i) {
        float ty = by + top[i] * bh;
        float th = height[i] * bh;
        draw[i] = (SDL_FRect) {right - 1.5f * scale, ty,
                               1.5f * scale + protrusion, th};
        hit[i] = (SDL_FRect) {right - 12 * scale, ty - 1.5f * scale,
                              12 * scale + margin, th + 3 * scale};
    }
}

static inline SDL_FColor
mix_color(SDL_FColor c, float target, float amount) {
    return (SDL_FColor) {c.r + (target - c.r) * amount,
                         c.g + (target - c.g) * amount,
                         c.b + (target - c.b) * amount, 1.f};
}

// Draw the body of the phone behind the video. (x, y, w, h) is the video
// rectangle in pixels; scale converts window units to pixels.
static void
render_phone_back(SDL_Renderer *renderer, const struct sc_device_profile *prof,
                  const uint8_t rim_rgb[3], float x, float y, float w, float h,
                  float scale, int hover, int pressed) {
    float rim = prof->rim * scale;
    float bezel = prof->bezel_side * scale;
    float bx, by, bw, bh;
    phone_body_rect(prof, x, y, w, h, scale, &bx, &by, &bw, &bh);

    float screen_radius = prof->screen_radius * w;
    float body_radius = screen_radius + bezel + rim;

    SDL_FColor rim_color = fcolor(rim_rgb);

    // Side buttons (right edge): lighter under the mouse, pushed in when
    // pressed
    SDL_FRect draw[SC_SIDE_COUNT];
    SDL_FRect hit[SC_SIDE_COUNT];
    phone_side_rects(prof, x, y, w, h, scale, draw, hit);
    for (int i = 0; i < SC_SIDE_COUNT; ++i) {
        SDL_FColor c = rim_color;
        SDL_FRect r = draw[i];
        if (i == pressed) {
            c = mix_color(rim_color, 0.f, 0.35f);
            r.x -= 1.5f * scale;
        } else if (i == hover) {
            c = mix_color(rim_color, 1.f, 0.35f);
        }
        SDL_SetRenderDrawColorFloat(renderer, c.r, c.g, c.b, 1.f);
        SDL_RenderFillRect(renderer, &r);
    }

    render_round_rect(renderer, rim_color, bx, by, bw, bh, body_radius);
    render_round_rect(renderer, fcolor(BEZEL_COLOR), bx + rim, by + rim,
                      bw - 2 * rim, bh - 2 * rim, body_radius - rim);

    if (prof->forehead) {
        // Earpiece slot in the thick top bezel
        float slot_w = 0.2f * w;
        float slot_h = 0.014f * w;
        float top_bezel_center = by + rim + (prof->bezel_top * scale) / 2;
        SDL_FColor slot = {0.16f, 0.16f, 0.18f, 1.f};
        render_round_rect(renderer, slot, x + w / 2 - slot_w / 2,
                          top_bezel_center - slot_h / 2, slot_w, slot_h,
                          slot_h / 2);
    }
}

// Round the corners of the video and draw the camera cutout, over the video
static void
render_phone_front(SDL_Renderer *renderer,
                   const struct sc_device_profile *prof, float x, float y,
                   float w, float h) {
    SDL_FColor color = fcolor(BEZEL_COLOR);
    float radius = prof->screen_radius * w;
    const float pi = 3.14159265359f;
    // top-left, top-right, bottom-right, bottom-left
    render_corner_mask(renderer, color, x + radius, y + radius, x, y, radius,
                       pi);
    render_corner_mask(renderer, color, x + w - radius, y + radius, x + w, y,
                       radius, 1.5f * pi);
    render_corner_mask(renderer, color, x + w - radius, y + h - radius, x + w,
                       y + h, radius, 0);
    render_corner_mask(renderer, color, x + radius, y + h - radius, x, y + h,
                       radius, 0.5f * pi);

    // The camera cutout is physical: it is not part of the captured video
    if (prof->hole_x >= 0) {
        SDL_FColor dark = {0.02f, 0.02f, 0.025f, 1.f};
        render_disc(renderer, dark, x + prof->hole_x * w, y + prof->hole_y * w,
                    prof->hole_radius * w);
    }
}

// Color used to clear the window, behind the video and the frame
static struct sc_screen_bg_color
get_clear_color(const struct sc_screen *screen) {
    struct sc_screen_bg_color bg = screen->bg;
    if (screen->frame_style == SC_FRAME_THIN) {
        bg.r = bg.g = bg.b = 0;
    } else if (is_phone_frame(screen->frame_style)) {
        uint8_t rgb[3];
        sc_macos_window_background(rgb);
        bg.r = rgb[0];
        bg.g = rgb[1];
        bg.b = rgb[2];
    }
    return bg;
}

// Frame drawn behind the video
static void
sc_screen_render_frame_back(struct sc_screen *screen, float scale) {
    if (screen->is_icon_active || screen->frame_pad_x == 0) {
        return;
    }
    if (is_phone_frame(screen->frame_style)) {
        render_phone_back(screen->renderer, get_profile(screen),
                          PHONE_RIM_COLORS[screen->frame_style],
                          screen->rect.x * scale, screen->rect.y * scale,
                          screen->rect.w * scale, screen->rect.h * scale,
                          scale * screen->frame_fs, screen->side_hover,
                          screen->side_pressed);
    }
}

// Frame drawn over the video
static void
sc_screen_render_frame_front(struct sc_screen *screen, float scale) {
    if (screen->is_icon_active || !is_phone_frame(screen->frame_style)) {
        return;
    }
    render_phone_front(screen->renderer, get_profile(screen),
                       screen->rect.x * scale, screen->rect.y * scale,
                       screen->rect.w * scale, screen->rect.h * scale);
}

static void
sc_screen_render_pinch(struct sc_screen *screen, float scale);

// render the texture to the renderer
//
// Set the update_content_rect flag if the window or content size may have
// changed, so that the content rectangle is recomputed
static void
sc_screen_render(struct sc_screen *screen, bool update_content_rect) {
    assert(screen->window_shown);

    if (update_content_rect) {
        sc_screen_update_content_rect(screen);
    }

    SDL_Renderer *renderer = screen->renderer;
    struct sc_screen_bg_color bg = get_clear_color(screen);
    SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, 0);
    sc_sdl_render_clear(renderer);

    float scale = SDL_GetWindowPixelDensity(screen->window);
    if (scale == 0) {
        // Just in case, but in practice the function can only fail when window
        // is invalid
        LOGE("Cannot get scale value: %s", SDL_GetError());
        scale = 1;
    }

    sc_screen_render_frame_back(screen, scale);

    SDL_Texture *texture = screen->is_icon_active
                         ? screen->icon_tex
                         : sc_texture_get(&screen->tex);
    if (!texture) {
        goto end;
    }

    SDL_FRect geometry = {
        .x = screen->rect.x * scale,
        .y = screen->rect.y * scale,
        .w = screen->rect.w * scale,
        .h = screen->rect.h * scale,
    };
    enum sc_orientation orientation = screen->orientation;

    const SDL_FRect *srcrect = NULL;
    SDL_FRect frame_rect;
    if (!screen->is_icon_active) {
        struct sc_size frame_size = sc_texture_get_frame_size(&screen->tex);
        frame_rect.x = 0;
        frame_rect.y = 0;
        frame_rect.w = frame_size.width;
        frame_rect.h = frame_size.height;
        srcrect = &frame_rect;
    }

    bool ok = false;
    if (orientation == SC_ORIENTATION_0) {
        // always align to a physical pixel
        geometry.x = (int32_t) geometry.x;
        geometry.y = (int32_t) geometry.y;
        ok = SDL_RenderTexture(renderer, texture, srcrect, &geometry);
    } else {
        unsigned cw_rotation = sc_orientation_get_rotation(orientation);
        double angle = 90 * cw_rotation;

        SDL_FRect *dstrect = NULL;
        SDL_FRect rect;
        if (sc_orientation_is_swap(orientation)) {
            rect.x = geometry.x + (geometry.w - geometry.h) / 2.f;
            rect.y = geometry.y + (geometry.h - geometry.w) / 2.f;
            rect.w = geometry.h;
            rect.h = geometry.w;
            dstrect = &rect;
        } else {
            dstrect = &geometry;
        }

        SDL_FlipMode flip = sc_orientation_is_mirror(orientation)
                              ? SDL_FLIP_HORIZONTAL : 0;

        // always align to a physical pixel
        dstrect->x = (int32_t) dstrect->x;
        dstrect->y = (int32_t) dstrect->y;
        ok = SDL_RenderTextureRotated(renderer, texture, srcrect, dstrect,
                                      angle, NULL, flip);
    }

    if (!ok) {
        LOGE("Could not render texture: %s", SDL_GetError());
    }

    sc_screen_render_frame_front(screen, scale);
    sc_screen_render_pinch(screen, scale);

end:
    sc_sdl_render_present(renderer);
}

// Draw the two virtual fingers (the mouse, and its mirror through the center
// of the screen), as the Android emulator does while the gesture is available
static void
sc_screen_render_pinch(struct sc_screen *screen, float scale) {
    if (!screen->pinch.active || screen->is_icon_active) {
        return;
    }

    const SDL_FRect *r = &screen->rect;
    float mx = screen->pinch.x;
    float my = screen->pinch.y;
    if (mx < r->x || mx > r->x + r->w || my < r->y || my > r->y + r->h) {
        return; // the mouse is outside of the screen of the device
    }

    float cx = r->x + r->w / 2;
    float cy = r->y + r->h / 2;
    float x2 = screen->pinch.invert_x ? 2 * cx - mx : mx;
    float y2 = screen->pinch.invert_y ? 2 * cy - my : my;

    SDL_Renderer *renderer = screen->renderer;
    SDL_BlendMode old_mode;
    SDL_GetRenderDrawBlendMode(renderer, &old_mode);
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);

    // Slightly smaller and more opaque while the fingers are down
    float radius = (screen->pinch.down ? 15.f : 18.f) * scale;
    float fill_alpha = screen->pinch.down ? 0.55f : 0.32f;
    const struct {
        float x, y;
    } fingers[2] = {{mx, my}, {x2, y2}};
    for (int i = 0; i < 2; ++i) {
        float x = fingers[i].x * scale;
        float y = fingers[i].y * scale;
        SDL_FColor ring = {1.f, 1.f, 1.f, 0.95f};
        SDL_FColor fill = {0.35f, 0.62f, 1.f, fill_alpha};
        SDL_FColor shadow = {0.f, 0.f, 0.f, 0.35f};
        render_disc(renderer, shadow, x, y, radius + 3 * scale);
        render_disc(renderer, ring, x, y, radius + 1.5f * scale);
        render_disc(renderer, fill, x, y, radius - 1.5f * scale);
    }
    SDL_SetRenderDrawBlendMode(renderer, old_mode);
}

void
sc_screen_set_pinch(struct sc_screen *screen, bool active, float x, float y,
                    bool invert_x, bool invert_y, bool down) {
    bool changed = screen->pinch.active != active
                || (active && (screen->pinch.x != x || screen->pinch.y != y
                            || screen->pinch.invert_x != invert_x
                            || screen->pinch.invert_y != invert_y
                            || screen->pinch.down != down));
    if (screen->pinch.active != active) {
        LOGD("Pinch fingers %s", active ? "shown" : "hidden");
    }
    screen->pinch.active = active;
    screen->pinch.x = x;
    screen->pinch.y = y;
    screen->pinch.invert_x = invert_x;
    screen->pinch.invert_y = invert_y;
    screen->pinch.down = down;

    if (changed && screen->window_shown) {
        sc_screen_render(screen, false);
    }
}

int
sc_screen_side_button_at(struct sc_screen *screen, float x, float y) {
    if (!is_phone_frame(screen->frame_style) || screen->is_icon_active
            || !screen->window_shown) {
        return SC_SIDE_NONE;
    }

    SDL_FRect draw[SC_SIDE_COUNT];
    SDL_FRect hit[SC_SIDE_COUNT];
    const SDL_FRect *r = &screen->rect;
    phone_side_rects(get_profile(screen), r->x, r->y, r->w, r->h,
                     screen->frame_fs, draw, hit);
    SDL_FPoint p = {x, y};
    for (int i = 0; i < SC_SIDE_COUNT; ++i) {
        if (SDL_PointInRectFloat(&p, &hit[i])) {
            return i;
        }
    }
    return SC_SIDE_NONE;
}

void
sc_screen_set_side_state(struct sc_screen *screen, int hover, int pressed) {
    if (screen->side_hover == hover && screen->side_pressed == pressed) {
        return;
    }
    bool was_active = screen->side_hover != SC_SIDE_NONE
                   || screen->side_pressed != SC_SIDE_NONE;
    screen->side_hover = hover;
    screen->side_pressed = pressed;

    // A pointer cursor over the buttons
    bool active = hover != SC_SIDE_NONE || pressed != SC_SIDE_NONE;
    if (active != was_active) {
        if (active && !screen->side_cursor) {
            screen->side_cursor =
                SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_POINTER);
        }
        SDL_SetCursor(active && screen->side_cursor
                      ? screen->side_cursor : SDL_GetDefaultCursor());
    }

    if (screen->window_shown) {
        sc_screen_render(screen, false);
    }
}

// Redraw the frame after a change of style or shape: the video keeps its
// size, the window grows or shrinks
static void
sc_screen_refresh_frame(struct sc_screen *screen) {
    if (!screen->window_shown || !is_windowed(screen)) {
        sc_screen_apply_frame_padding(screen, FRAME_REFERENCE_WIDTH);
        if (screen->window_shown) {
            sc_screen_render(screen, true);
        }
        return;
    }

    struct sc_size view_size = get_view_size(screen); // with the old frame
    sc_screen_apply_frame_padding(screen, view_size.width);
    set_aspect_ratio(screen, view_size);
    set_view_size(screen, view_size);
    sc_screen_render(screen, true);
}

void
sc_screen_set_frame_style(struct sc_screen *screen, uint8_t style) {
    if (style >= SC_FRAME_COUNT || style == screen->frame_style) {
        return;
    }
    screen->frame_style = style;
    sc_screen_refresh_frame(screen);
}

void
sc_screen_set_frame_shape(struct sc_screen *screen, int shape) {
    if (shape < -1 || shape >= (int) DEVICE_PROFILE_COUNT
            || shape == screen->frame_shape) {
        return;
    }
    screen->frame_shape = shape;
    sc_screen_refresh_frame(screen);
}

// Window scales, as the iOS Simulator has: a device point (dp) or pixel can be
// shown as a point or a pixel of the Mac, or at the real size of the device
void
sc_screen_scale(struct sc_screen *screen, enum sc_scale_mode mode,
                float factor) {
    if (!screen->video || !screen->window_shown || !is_windowed(screen)) {
        return;
    }
    struct sc_size content = screen->content_size;
    if (!content.width || !content.height) {
        return;
    }

    int dpi = sc_macos_device_density();
    if (dpi <= 0) {
        dpi = 420;
    }

    struct sc_size old_view = get_view_size(screen);
    float width;
    switch (mode) {
        case SC_SCALE_PHYSICAL:
            width = content.width / (float) dpi
                  * sc_macos_points_per_inch(screen->window);
            break;
        case SC_SCALE_PIXEL: {
            float density = SDL_GetWindowPixelDensity(screen->window);
            width = content.width / (density > 0 ? density : 1.f);
            break;
        }
        case SC_SCALE_ZOOM:
            width = content.width * 160.f / dpi * factor;
            break;
        case SC_SCALE_STEP:
            width = old_view.width * factor;
            break;
        case SC_SCALE_FIT:
            width = 20000.f;
            break;
        case SC_SCALE_POINT:
        default:
            width = content.width * 160.f / dpi;
            break;
    }
    width = MAX(100.f, MIN(width, 20000.f));
    float height = width * content.height / content.width;
    struct sc_size target = {
        .width = (uint16_t) lroundf(width),
        .height = (uint16_t) lroundf(MIN(height, 60000.f)),
    };
    // Fit in the display, keeping the aspect ratio
    struct sc_size size = get_optimal_size(target, content, true);
    if (size.width < 100) {
        size.width = 100;
        size.height = (uint32_t) 100 * content.height / content.width;
    }

    // Grow or shrink around the center of the window
    struct sc_point pos = sc_sdl_get_window_position(screen->window);
    pos.x += ((int) old_view.width - (int) size.width) / 2;
    pos.y += ((int) old_view.height - (int) size.height) / 2;

    set_aspect_ratio(screen, size);
    set_view_size(screen, size);
    sc_sdl_set_window_position(screen->window, pos);
    LOGD("Scale %d (x%.2f): view %ux%u -> %ux%u (dpi %d)", (int) mode, factor,
         old_view.width, old_view.height, size.width, size.height, dpi);
}


static void
sc_screen_request_resize_display(struct sc_screen *screen, uint16_t width,
                                 uint16_t height) {
    assert(screen->flex_display);
    assert(!screen->camera);
    if (sc_orientation_is_swap(screen->orientation)) {
        uint16_t tmp = width;
        width = height;
        height = tmp;
    }

    LOGV("resize_display(%" PRIu16 ", %" PRIu16 ")", width, height);
    sc_controller_resize_display(screen->controller, width, height);
}

static void
sc_screen_save_prefs(struct sc_screen *screen);

static void
sc_screen_on_resize(struct sc_screen *screen, const SDL_WindowEvent *event) {
    // This event can be triggered before the window is shown
    if (!screen->window_shown) {
        return;
    }

    if (event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
        sc_screen_render(screen, true);
    } else {
        assert(event->type == SDL_EVENT_WINDOW_RESIZED);
        sc_screen_save_prefs(screen);
        if (screen->flex_display) {
            assert(!(event->data1 & ~0xFFFF));
            assert(!(event->data2 & ~0xFFFF));
            struct sc_size view = get_view_size(screen);
            uint16_t width = view.width;
            uint16_t height = view.height;

            struct sc_resize_tracker *tracker = &screen->resize_tracker;
            if (tracker->time
                    && sc_tick_now() >= tracker->time + SC_TICK_FROM_MS(3000)) {
                // Remove obsolete request
                tracker->time = 0;
            }
            if (tracker->time && tracker->size.width == width
                              && tracker->size.height == height) {
                // This resize event is the result of a previous (recent) resize
                // request triggered by a change in the frame's dimensions.
                LOGV("Ignore local resize: %" PRIu16 "x%" PRIu16,
                     width, height);
                tracker->time = 0;
            } else {
                sc_screen_request_resize_display(screen, width, height);
            }
        }
    }
}

#if defined(__APPLE__) || defined(_WIN32)
# define CONTINUOUS_RESIZING_WORKAROUND
#endif

#ifdef CONTINUOUS_RESIZING_WORKAROUND
// On Windows and MacOS, resizing blocks the event loop, so resizing events are
// not triggered. As a workaround, handle them in an event handler.
//
// <https://bugzilla.libsdl.org/show_bug.cgi?id=2077>
// <https://stackoverflow.com/a/40693139/1987178>
static bool
event_watcher(void *data, SDL_Event *event) {
    struct sc_screen *screen = data;
    assert(screen->video);

    if (event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
            || event->type == SDL_EVENT_WINDOW_RESIZED) {
        // In practice, it seems to always be called from the same thread in
        // that specific case. Anyway, it's just a workaround.
        sc_screen_on_resize(screen, &event->window);
    }

    return true;
}
#endif

static bool
sc_screen_frame_sink_open(struct sc_frame_sink *sink,
                          const AVCodecContext *ctx,
                          const struct sc_stream_session *session) {
    assert(ctx->pix_fmt == AV_PIX_FMT_YUV420P);

    struct sc_screen *screen = DOWNCAST(sink);

    if (ctx->width <= 0 || ctx->width > 0xFFFF
            || ctx->height <= 0 || ctx->height > 0xFFFF) {
        LOGE("Invalid video size: %dx%d", ctx->width, ctx->height);
        return false;
    }

    screen->current_session = *session;

    assert(session->video.width && session->video.height);
    if (session->video.width > 0xFFFF || session->video.height > 0xFFFF) {
        LOGE("Size too large: %" PRIu32 "x%" PRIu32, session->video.width,
                                                     session->video.height);
        return false;
    }

    struct sc_size *size = malloc(sizeof(*size));
    if (!size) {
        LOG_OOM();
        return false;
    }
    size->width = session->video.width;
    size->height = session->video.height;

    bool ok = sc_push_event_with_data(SC_EVENT_OPEN_WINDOW, size);
    if (!ok) {
        free(size);
        return false;
    }

#ifndef NDEBUG
    screen->open = true;
#endif

    // nothing to do, the screen is already open on the main thread
    return true;
}

static void
sc_screen_frame_sink_close(struct sc_frame_sink *sink) {
    struct sc_screen *screen = DOWNCAST(sink);
    (void) screen;
#ifndef NDEBUG
    screen->open = false;
#endif

    // nothing to do, the screen lifecycle is not managed by the frame producer
}

static enum sc_sink_result
sc_screen_frame_sink_push(struct sc_frame_sink *sink, const AVFrame *frame) {
    struct sc_screen *screen = DOWNCAST(sink);
    assert(screen->video);

    sc_mutex_lock(&screen->mutex);
    bool previous_skipped = sc_frame_buffer_has_frame(&screen->fb);
    bool ok = sc_frame_buffer_push(&screen->fb, frame);
    screen->prevent_auto_resize = screen->current_session.video.client_resized;
    sc_mutex_unlock(&screen->mutex);
    if (!ok) {
        return SC_SINK_KO;
    }

    if (previous_skipped) {
        sc_fps_counter_add_skipped_frame(&screen->fps_counter);
        // The SC_EVENT_NEW_FRAME triggered for the previous frame will consume
        // this new frame instead
    } else {
        // Post the event on the UI thread
        bool ok = sc_push_event(SC_EVENT_NEW_FRAME);
        if (!ok) {
            return SC_SINK_KO;
        }
    }

    return SC_SINK_OK;
}

static enum sc_sink_result
sc_screen_frame_sink_push_session(struct sc_frame_sink *sink,
                                  const struct sc_stream_session *session) {
    struct sc_screen *screen = DOWNCAST(sink);
    screen->current_session = *session;
    return SC_SINK_OK;
}

#ifdef __APPLE__
static void
toolbar_callback(enum sc_toolbar_button button, void *userdata) {
    struct sc_screen *screen = userdata;
    sc_input_manager_press_toolbar_button(&screen->im, button);
}

static void
frame_callback(enum sc_frame_style style, void *userdata) {
    struct sc_screen *screen = userdata;
    sc_screen_set_frame_style(screen, style);
}

static void
shape_callback(int shape, void *userdata) {
    struct sc_screen *screen = userdata;
    sc_screen_set_frame_shape(screen, shape);
}

static void
scale_callback(enum sc_scale_mode mode, float factor, void *userdata) {
    struct sc_screen *screen = userdata;
    sc_screen_scale(screen, mode, factor);
}
#endif

bool
sc_screen_init(struct sc_screen *screen,
               const struct sc_screen_params *params) {
    screen->controller = params->controller;

    screen->resize_pending = false;
    screen->window_shown = false;
    screen->paused = false;
    screen->resume_frame = NULL;
    screen->orientation = SC_ORIENTATION_0;
    screen->disconnected = false;
    screen->disconnect_started = false;

    screen->video = params->video;
    screen->camera = params->camera;
    screen->window_aspect_ratio_lock = params->window_aspect_ratio_lock;
    screen->render_fit = params->render_fit;
    screen->flex_display = params->flex_display;

    screen->bg.r = (params->background_color >> 16) & 0xFF;
    screen->bg.g = (params->background_color >> 8) & 0xFF;
    screen->bg.b = params->background_color & 0xFF;

    screen->req.x = params->window_x;
    screen->req.y = params->window_y;
    screen->req.width = params->window_width;
    screen->req.height = params->window_height;
    screen->req.fullscreen = params->fullscreen;
    screen->req.start_fps_counter = params->start_fps_counter;

    screen->prevent_auto_resize = false;

    screen->resize_tracker.time = 0;
    screen->resize_tracker.size.width = 0;
    screen->resize_tracker.size.height = 0;

    bool ok = sc_mutex_init(&screen->mutex);
    if (!ok) {
        return false;
    }

    ok = sc_frame_buffer_init(&screen->fb);
    if (!ok) {
        goto error_destroy_mutex;
    }

    if (!sc_fps_counter_init(&screen->fps_counter)) {
        goto error_destroy_frame_buffer;
    }

    if (screen->video) {
        screen->orientation = params->orientation;
        if (screen->orientation != SC_ORIENTATION_0) {
            LOGI("Initial display orientation set to %s",
                 sc_orientation_get_name(screen->orientation));
        }
    }

    // Always create the window hidden to prevent blinking during initialization
    uint32_t window_flags = SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN;
    if (params->always_on_top) {
        window_flags |= SDL_WINDOW_ALWAYS_ON_TOP;
    }
    if (params->window_borderless) {
        window_flags |= SDL_WINDOW_BORDERLESS;
    }
    if (params->video) {
        // The window will be shown on first frame
        window_flags |= SDL_WINDOW_RESIZABLE;
    }

    const char *title = params->window_title;
    assert(title);

    int x = SDL_WINDOWPOS_UNDEFINED;
    int y = SDL_WINDOWPOS_UNDEFINED;
    int width = 256;
    int height = 256;
    if (params->window_x != SC_WINDOW_POSITION_UNDEFINED) {
        x = params->window_x;
    }
    if (params->window_y != SC_WINDOW_POSITION_UNDEFINED) {
        y = params->window_y;
    }
    if (params->window_width) {
        width = params->window_width;
    }
    if (params->window_height) {
        height = params->window_height;
    }

    // The window will be positioned and sized on first video frame
    screen->window =
        sc_sdl_create_window(title, x, y, width, height, window_flags);
    if (!screen->window) {
        LOGE("Could not create window: %s", SDL_GetError());
        goto error_destroy_fps_counter;
    }

    screen->renderer = SDL_CreateRenderer(screen->window, NULL);
    if (!screen->renderer) {
        LOGE("Could not create renderer: %s", SDL_GetError());
        goto error_destroy_window;
    }

#ifdef SC_DISPLAY_FORCE_OPENGL_CORE_PROFILE
    screen->gl_context = NULL;

    // starts with "opengl"
    const char *renderer_name = SDL_GetRendererName(screen->renderer);
    bool use_opengl = renderer_name && !strncmp(renderer_name, "opengl", 6);
    if (use_opengl) {
        // Persuade macOS to give us something better than OpenGL 2.1.
        // If we create a Core Profile context, we get the best OpenGL version.
        bool ok = SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                                      SDL_GL_CONTEXT_PROFILE_CORE);
        if (!ok) {
            LOGW("Could not set a GL Core Profile Context");
        }

        LOGD("Creating OpenGL Core Profile context");
        screen->gl_context = SDL_GL_CreateContext(screen->window);
        if (!screen->gl_context) {
            LOGE("Could not create OpenGL context: %s", SDL_GetError());
            goto error_destroy_renderer;
        }
    }
#endif

    bool mipmaps = params->video && params->mipmaps;
    ok = sc_texture_init(&screen->tex, screen->renderer, mipmaps,
                         params->hwdec_mode);
    if (!ok) {
        goto error_destroy_renderer;
    }

    ok = SDL_StartTextInput(screen->window);
    if (!ok) {
        LOGE("Could not enable text input: %s", SDL_GetError());
        goto error_destroy_texture;
    }

    screen->icon_tex = NULL;
    screen->is_icon_active = false;
    SDL_Surface *icon = sc_icon_load(SC_ICON_FILENAME_SCRCPY);
    if (icon) {
        if (!SDL_SetWindowIcon(screen->window, icon)) {
            LOGW("Could not set window icon: %s", SDL_GetError());
        }

        if (!params->video) {
            screen->content_size.width = icon->w;
            screen->content_size.height = icon->h;
            ok = sc_screen_set_texture_from_surface(screen, icon);
            if (!ok) {
                LOGE("Could not set icon: %s", SDL_GetError());
            }
        }

        sc_icon_destroy(icon);
    } else {
        // not fatal
        LOGE("Could not load icon");

        if (!params->video) {
            // Make sure the content size is initialized
            screen->content_size.width = 256;
            screen->content_size.height = 256;
        }
    }

    screen->frame = av_frame_alloc();
    if (!screen->frame) {
        LOG_OOM();
        goto error_destroy_texture;
    }

    struct sc_input_manager_params im_params = {
        .controller = params->controller,
        .fp = params->fp,
        .screen = screen,
        .kp = params->kp,
        .mp = params->mp,
        .gp = params->gp,
        .camera = params->camera,
        .mouse_bindings = params->mouse_bindings,
        .legacy_paste = params->legacy_paste,
        .clipboard_autosync = params->clipboard_autosync,
        .shortcut_mods = params->shortcut_mods,
    };

    sc_input_manager_init(&screen->im, &im_params);

#ifdef __APPLE__
    screen->bottom_inset = 0;
    screen->frame_style = SC_FRAME_NONE;
    screen->frame_pad_x = 0;
    screen->frame_pad_top = 0;
    screen->frame_pad_bottom = 0;
    screen->frame_shape = -1;
    screen->frame_fs = 1.f;
    screen->device_model[0] = '\0';
    screen->pinch.active = false;
    screen->side_hover = SC_SIDE_NONE;
    screen->side_pressed = SC_SIDE_NONE;
    screen->side_cursor = NULL;
    if (params->video && params->controller && params->kp && !params->camera) {
        // Not fatal
        bool ok = sc_macos_toolbar_init(screen->window, toolbar_callback,
                                        frame_callback, shape_callback,
                                        scale_callback, screen,
                                        sc_adb_get_executable(),
                                        params->serial);
        if (ok) {
            screen->bottom_inset = SC_NAV_BAR_HEIGHT;
            screen->frame_style = sc_prefs_load_frame();
            sc_macos_device_model(screen->device_model,
                                  sizeof(screen->device_model));
            // Shape of phone chosen by the user (else the one of the model)
            char shape[64];
            sc_prefs_load_shape(shape, sizeof(shape));
            for (int i = 0; shape[0] && i < (int) DEVICE_PROFILE_COUNT; ++i) {
                if (!strcmp(shape, DEVICE_PROFILES[i].name)) {
                    screen->frame_shape = i;
                }
            }
            sc_screen_apply_frame_padding(screen, FRAME_REFERENCE_WIDTH);
        }
    }
#endif

    // Initialize even if not used for simplicity
    sc_mouse_capture_init(&screen->mc, screen->window, params->shortcut_mods);

#ifdef CONTINUOUS_RESIZING_WORKAROUND
    if (screen->video) {
        ok = SDL_AddEventWatch(event_watcher, screen);
        if (!ok) {
            LOGW("Could not add event watcher for continuous resizing: %s",
                 SDL_GetError());
        }
    }
#endif

    memset(&screen->current_session, 0, sizeof(screen->current_session));

    static const struct sc_frame_sink_ops ops = {
        .open = sc_screen_frame_sink_open,
        .close = sc_screen_frame_sink_close,
        .push = sc_screen_frame_sink_push,
        .push_session = sc_screen_frame_sink_push_session,
    };

    screen->frame_sink.ops = &ops;

#ifndef NDEBUG
    screen->open = false;
#endif

    if (!screen->video) {
        // Show the window immediately
        screen->window_shown = true;
        sc_sdl_show_window(screen->window);

        if (sc_screen_is_relative_mode(screen)) {
            // Capture mouse immediately if video mirroring is disabled
            sc_mouse_capture_set_active(&screen->mc, true);
        }
    }

    return true;

error_destroy_texture:
    sc_texture_destroy(&screen->tex);
error_destroy_renderer:
#ifdef SC_DISPLAY_FORCE_OPENGL_CORE_PROFILE
    if (screen->gl_context) {
        SDL_GL_DestroyContext(screen->gl_context);
    }
#endif
    SDL_DestroyRenderer(screen->renderer);
error_destroy_window:
    SDL_DestroyWindow(screen->window);
error_destroy_fps_counter:
    sc_fps_counter_destroy(&screen->fps_counter);
error_destroy_frame_buffer:
    sc_frame_buffer_destroy(&screen->fb);
error_destroy_mutex:
    sc_mutex_destroy(&screen->mutex);

    return false;
}

// Remember the window geometry for the next session
static void
sc_screen_save_prefs(struct sc_screen *screen) {
    if (!screen->video || !screen->window_shown || !is_windowed(screen)) {
        return;
    }

    // The window may be moved and resized by the system while it opens
    if (sc_tick_now() < screen->shown_tick + SC_TICK_FROM_MS(1500)) {
        return;
    }

    struct sc_size view_size = get_view_size(screen);
    struct sc_point position = sc_sdl_get_window_position(screen->window);
    struct sc_window_prefs prefs = {
        .valid = true,
        .x = position.x,
        .y = position.y,
        .width = view_size.width,
        .height = view_size.height,
    };
    sc_prefs_save_window(&prefs);
}

static bool
is_position_on_a_display(int x, int y) {
    SDL_Point point = {x, y};
    return SDL_GetDisplayForPoint(&point) != 0;
}

// Debug: SCRCPY_TEST_SCALE="point,pixel,physical,z50,fit,in,out" applies the
// scales of the Window menu, two seconds apart
struct scale_test_step {
    struct sc_screen *screen;
    enum sc_scale_mode mode;
    float factor;
};

static void SDLCALL
scale_test_run(void *data) {
    struct scale_test_step *step = data;
    sc_screen_scale(step->screen, step->mode, step->factor);
}

static int
test_scale_thread(void *data) {
    struct sc_screen *screen = data;
    SDL_Delay(3500);
    char *list = strdup(getenv("SCRCPY_TEST_SCALE"));
    for (char *tok = strtok(list, ","); tok; tok = strtok(NULL, ",")) {
        struct scale_test_step step = {screen, SC_SCALE_POINT, 1.f};
        if (!strcmp(tok, "physical")) step.mode = SC_SCALE_PHYSICAL;
        else if (!strcmp(tok, "pixel")) step.mode = SC_SCALE_PIXEL;
        else if (!strcmp(tok, "fit")) step.mode = SC_SCALE_FIT;
        else if (!strcmp(tok, "in")) { step.mode = SC_SCALE_STEP; step.factor = 1.15f; }
        else if (!strcmp(tok, "out")) { step.mode = SC_SCALE_STEP; step.factor = 1 / 1.15f; }
        else if (tok[0] == 'z') { step.mode = SC_SCALE_ZOOM; step.factor = atoi(tok + 1) / 100.f; }
        SDL_RunOnMainThread(scale_test_run, &step, true);
        SDL_Delay(1500);
        {
            int ww, wh;
            SDL_GetWindowSize(screen->window, &ww, &wh);
            const SDL_FRect *rr = &screen->rect;
            LOGD("After %s: window %dx%d | video rect (%.0f,%.0f %.0fx%.0f) | "
                 "pads x=%u top=%u bottom=%u inset=%u | leftover w=%.1f h=%.1f",
                 tok, ww, wh, rr->x, rr->y, rr->w, rr->h, screen->frame_pad_x,
                 screen->frame_pad_top, screen->frame_pad_bottom,
                 screen->bottom_inset,
                 ww - 2.0f * screen->frame_pad_x - rr->w,
                 wh - screen->frame_pad_top - screen->frame_pad_bottom
                    - screen->bottom_inset - rr->h);
        }
    }
    free(list);
    return 0;
}

// Debug: SCRCPY_TEST_SIDE=1 hovers the three side buttons of the phone frame
// and clicks the two volume ones (up, then down: no net change on the device)
static int
test_side_thread(void *data) {
    struct sc_screen *screen = data;
    SDL_Delay(3000);
    SDL_WindowID id = SDL_GetWindowID(screen->window);

    SDL_FRect draw[SC_SIDE_COUNT];
    SDL_FRect hit[SC_SIDE_COUNT];
    const SDL_FRect *r = &screen->rect;
    phone_side_rects(get_profile(screen), r->x, r->y, r->w, r->h,
                     screen->frame_fs, draw, hit);

    for (int i = 0; i < SC_SIDE_COUNT; ++i) {
        float x = hit[i].x + hit[i].w / 2;
        float y = hit[i].y + hit[i].h / 2;
        SDL_Event e;
        SDL_zero(e);
        e.type = SDL_EVENT_MOUSE_MOTION;
        e.motion.windowID = id;
        e.motion.x = x;
        e.motion.y = y;
        SDL_PushEvent(&e);
        SDL_Delay(400);
        LOGD("Test: hover over side button %d -> hit %d", i,
             sc_screen_side_button_at(screen, x, y));

        if (i == SC_SIDE_POWER) {
            continue; // do not turn the device off
        }
        SDL_zero(e);
        e.type = SDL_EVENT_MOUSE_BUTTON_DOWN;
        e.button.windowID = id;
        e.button.button = SDL_BUTTON_LEFT;
        e.button.down = true;
        e.button.clicks = 1;
        e.button.x = x;
        e.button.y = y;
        SDL_PushEvent(&e);
        SDL_Delay(250);
        e.type = SDL_EVENT_MOUSE_BUTTON_UP;
        e.button.down = false;
        SDL_PushEvent(&e);
        SDL_Delay(500);
    }

    // Outside of any button: the click must not be taken
    LOGD("Test: point on the video -> hit %d",
         sc_screen_side_button_at(screen, r->x + r->w / 2, r->y + r->h / 2));
    return 0;
}

// Debug: SCRCPY_TEST_PINCH=1 simulates, with SDL events, the mouse moving with
// Cmd held, then a click and a drag (pinch-to-zoom) at the center of the screen
static int
test_pinch_thread(void *data) {
    struct sc_screen *screen = data;
    SDL_Delay(2500);
    SDL_WindowID id = SDL_GetWindowID(screen->window);
    float cx = screen->rect.x + screen->rect.w / 2;
    float cy = screen->rect.y + screen->rect.h / 2;
    float x = cx - 60;
    float y = cy - 80;

    SDL_SetModState(SDL_KMOD_LGUI);
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_EVENT_MOUSE_MOTION;
    e.motion.windowID = id;
    e.motion.x = x;
    e.motion.y = y;
    SDL_PushEvent(&e);
    SDL_Delay(500);

    SDL_zero(e);
    e.type = SDL_EVENT_MOUSE_BUTTON_DOWN;
    e.button.windowID = id;
    e.button.button = SDL_BUTTON_LEFT;
    e.button.down = true;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
    SDL_Delay(300);

    for (int i = 1; i <= 6; ++i) {
        SDL_zero(e);
        e.type = SDL_EVENT_MOUSE_MOTION;
        e.motion.windowID = id;
        e.motion.state = SDL_BUTTON_LMASK;
        e.motion.x = x - 12 * i;
        e.motion.y = y - 12 * i;
        SDL_PushEvent(&e);
        SDL_Delay(120);
    }

    SDL_zero(e);
    e.type = SDL_EVENT_MOUSE_BUTTON_UP;
    e.button.windowID = id;
    e.button.button = SDL_BUTTON_LEFT;
    e.button.down = false;
    e.button.x = x - 72;
    e.button.y = y - 72;
    SDL_PushEvent(&e);
    SDL_Delay(300);

    SDL_SetModState(SDL_KMOD_NONE);
    SDL_zero(e);
    e.type = SDL_EVENT_MOUSE_MOTION;
    e.motion.windowID = id;
    e.motion.x = x - 72;
    e.motion.y = y - 72;
    SDL_PushEvent(&e);
    return 0;
}

static void
sc_screen_show_initial_window(struct sc_screen *screen) {
    int x = screen->req.x != SC_WINDOW_POSITION_UNDEFINED
          ? screen->req.x : (int) SDL_WINDOWPOS_CENTERED;
    int y = screen->req.y != SC_WINDOW_POSITION_UNDEFINED
          ? screen->req.y : (int) SDL_WINDOWPOS_CENTERED;

    // Restore the geometry of the last session, unless the user requested one
    struct sc_window_prefs prefs;
    sc_prefs_load_window(&prefs);
    bool restore_size = prefs.valid && !screen->req.width
                                    && !screen->req.height;
    if (prefs.valid && prefs.has_position
                    && screen->req.x == SC_WINDOW_POSITION_UNDEFINED
                    && screen->req.y == SC_WINDOW_POSITION_UNDEFINED
                    && is_position_on_a_display(prefs.x, prefs.y)) {
        x = prefs.x;
        y = prefs.y;
    }

    struct sc_point position = {
        .x = x,
        .y = y,
    };
    LOGD("Initial window: prefs valid=%d has_position=%d (%d,%d %dx%d) -> "
         "position (%d,%d)", prefs.valid, prefs.has_position, prefs.x, prefs.y,
         prefs.width, prefs.height, x, y);

    struct sc_size window_size;
    if (restore_size) {
        // The saved long edge applies to whatever the orientation is
        int long_edge = MAX(prefs.width, prefs.height);
        bool portrait = screen->content_size.width
                     <= screen->content_size.height;
        window_size = get_initial_optimal_size(screen->content_size,
                                               portrait ? 0 : long_edge,
                                               portrait ? long_edge : 0);
        // Fit in the display
        window_size = get_optimal_size(window_size, screen->content_size,
                                       true);
    } else {
        window_size =
            get_initial_optimal_size(screen->content_size, screen->req.width,
                                                           screen->req.height);
    }

    if (screen->flex_display
            && window_size.width == screen->content_size.width
            && window_size.height == screen->content_size.height) {
        // Avoid sending an unnecessary initial "resize display" request to the
        // server if the size has not changed.
        sc_screen_track_resize(screen, window_size);
    }

    assert(is_windowed(screen));
    set_aspect_ratio(screen, window_size);
    set_view_size(screen, window_size);
    sc_sdl_set_window_position(screen->window, position);

    if (screen->req.fullscreen) {
        sc_screen_toggle_fullscreen(screen);
    }

    if (screen->req.start_fps_counter) {
        sc_fps_counter_start(&screen->fps_counter);
    }

    screen->window_shown = true;
    screen->shown_tick = sc_tick_now();
    sc_sdl_show_window(screen->window);
    sc_screen_update_content_rect(screen);

    if (getenv("SCRCPY_TEST_SCALE")) {
        SDL_Thread *t = SDL_CreateThread(test_scale_thread, "scale-test",
                                         screen);
        if (t) {
            SDL_DetachThread(t);
        }
    }
    if (getenv("SCRCPY_TEST_SIDE")) {
        SDL_Thread *t = SDL_CreateThread(test_side_thread, "side-test", screen);
        if (t) {
            SDL_DetachThread(t);
        }
    }
    if (getenv("SCRCPY_TEST_PINCH")) {
        SDL_Thread *t = SDL_CreateThread(test_pinch_thread, "pinch-test",
                                         screen);
        if (t) {
            SDL_DetachThread(t);
        }
    }
}

void
sc_screen_hide_window(struct sc_screen *screen) {
    sc_screen_save_prefs(screen);
    // Give back the device settings changed by the toolbar (idempotent)
    sc_macos_toolbar_shutdown();
    sc_sdl_hide_window(screen->window);
    screen->window_shown = false;
}

void
sc_screen_interrupt(struct sc_screen *screen) {
    sc_fps_counter_interrupt(&screen->fps_counter);
}

static void
sc_screen_interrupt_disconnect(struct sc_screen *screen) {
    if (screen->disconnect_started) {
        sc_disconnect_interrupt(&screen->disconnect);
    }
}

void
sc_screen_join(struct sc_screen *screen) {
    sc_fps_counter_join(&screen->fps_counter);
    if (screen->disconnect_started) {
        sc_disconnect_join(&screen->disconnect);
    }
}

void
sc_screen_destroy(struct sc_screen *screen) {
    if (screen->side_cursor) {
        SDL_DestroyCursor(screen->side_cursor);
    }
#ifndef NDEBUG
    assert(!screen->open);
#endif
    if (screen->disconnect_started) {
        sc_disconnect_destroy(&screen->disconnect);
    }
    sc_texture_destroy(&screen->tex);
    av_frame_free(&screen->frame);
#ifdef SC_DISPLAY_FORCE_OPENGL_CORE_PROFILE
    SDL_GL_DestroyContext(screen->gl_context);
#endif
    SDL_DestroyRenderer(screen->renderer);
    SDL_DestroyWindow(screen->window);
    sc_fps_counter_destroy(&screen->fps_counter);
    sc_frame_buffer_destroy(&screen->fb);
    sc_mutex_destroy(&screen->mutex);

    SDL_Event event;
    bool has_event =
        sc_dequeue_event(SC_EVENT_DISCONNECTED_ICON_LOADED, &event);
    if (has_event) {
        assert(event.type == SC_EVENT_DISCONNECTED_ICON_LOADED);
        // The event was posted, but not handled, the icon must be freed
        SDL_Surface *dangling_icon = event.user.data1;
        sc_icon_destroy(dangling_icon);
    }

    has_event = sc_dequeue_event(SC_EVENT_OPEN_WINDOW, &event);
    if (has_event) {
        assert(event.type == SC_EVENT_OPEN_WINDOW);
        // The event was posted, but not handled, the size must be freed
        struct sc_size * size = event.user.data1;
        free(size);
    }
}

static void
resize_for_content(struct sc_screen *screen, struct sc_size old_content_size,
                   struct sc_size new_content_size) {
    assert(screen->video);

    struct sc_size target_size = new_content_size;
    if (!screen->flex_display) {
        struct sc_size window_size = get_view_size(screen);
        // Scale proportionally
        target_size.width = (uint32_t) window_size.width * target_size.width
                          / old_content_size.width;
        target_size.height = (uint32_t) window_size.height * target_size.height
                           / old_content_size.height;
    }
    target_size = get_optimal_size(target_size, new_content_size, true);
    assert(is_windowed(screen));
    set_aspect_ratio(screen, target_size);
    set_view_size(screen, target_size);
}

static void
set_content_size(struct sc_screen *screen, struct sc_size new_content_size,
                 bool resize) {
    assert(screen->video);

    if (resize) {
        if (is_windowed(screen)) {
            resize_for_content(screen, screen->content_size, new_content_size);
        } else if (screen->flex_display) {
            // Force a display resize, the client cannot resize in fullscreen
            struct sc_size size = get_view_size(screen);
            sc_screen_request_resize_display(screen, size.width, size.height);
        } else if (!screen->resize_pending) {
            // Store the windowed size to be able to compute the optimal size
            // once fullscreen/maximized/minimized are disabled
            screen->windowed_content_size = screen->content_size;
            screen->resize_pending = true;
        }
    }

    screen->content_size = new_content_size;
}

static void
apply_pending_resize(struct sc_screen *screen) {
    assert(screen->video);

    assert(is_windowed(screen));
    if (screen->resize_pending) {
        resize_for_content(screen, screen->windowed_content_size,
                                   screen->content_size);
        screen->resize_pending = false;
    }
}

void
sc_screen_set_orientation(struct sc_screen *screen,
                          enum sc_orientation orientation) {
    assert(screen->video);

    if (orientation == screen->orientation) {
        return;
    }

    struct sc_size new_content_size =
        get_oriented_size(screen->frame_size, orientation);

    set_content_size(screen, new_content_size, true);

    screen->orientation = orientation;
    LOGI("Display orientation set to %s", sc_orientation_get_name(orientation));

    sc_screen_render(screen, true);
}

static bool
sc_screen_apply_frame(struct sc_screen *screen, bool can_resize) {
    assert(screen->video);
    assert(screen->window_shown);

    sc_fps_counter_add_rendered_frame(&screen->fps_counter);

    AVFrame *frame = screen->frame;
    struct sc_size new_frame_size = {frame->width, frame->height};

    if (!new_frame_size.width || !new_frame_size.height) {
        LOGE("Invalid frame size: %" PRIu32 "x%" PRIu32,
             new_frame_size.width, new_frame_size.height);
        return false;
    }

    if (screen->frame_size.width != new_frame_size.width
            || screen->frame_size.height != new_frame_size.height) {

        // frame dimension changed
        screen->frame_size = new_frame_size;

        struct sc_size new_content_size =
            get_oriented_size(new_frame_size, screen->orientation);

        if (screen->flex_display) {
            sc_screen_track_resize(screen, new_content_size);
        }

        set_content_size(screen, new_content_size, can_resize);
        sc_screen_update_content_rect(screen);
    }

    bool ok = sc_texture_update(&screen->tex, frame);
    if (!ok) {
        return false;
    }

    sc_screen_render(screen, false);
    return true;
}

static bool
sc_screen_update_frame(struct sc_screen *screen) {
    assert(screen->video);

    if (screen->paused) {
        if (!screen->resume_frame) {
            screen->resume_frame = av_frame_alloc();
            if (!screen->resume_frame) {
                LOG_OOM();
                return false;
            }
        } else {
            av_frame_unref(screen->resume_frame);
        }
        sc_mutex_lock(&screen->mutex);
        sc_frame_buffer_consume(&screen->fb, screen->resume_frame);
        sc_mutex_unlock(&screen->mutex);
        return true;
    }

    av_frame_unref(screen->frame);
    sc_mutex_lock(&screen->mutex);
    sc_frame_buffer_consume(&screen->fb, screen->frame);
    // read with lock held
    bool can_resize = !screen->prevent_auto_resize;
    sc_mutex_unlock(&screen->mutex);
    return sc_screen_apply_frame(screen, can_resize);
}

void
sc_screen_set_paused(struct sc_screen *screen, bool paused) {
    assert(screen->video);

    if (!paused && !screen->paused) {
        // nothing to do
        return;
    }

    if (screen->paused && screen->resume_frame) {
        // If display screen was paused, refresh the frame immediately, even if
        // the new state is also paused.
        av_frame_free(&screen->frame);
        screen->frame = screen->resume_frame;
        screen->resume_frame = NULL;
        bool ok = sc_screen_apply_frame(screen, true);
        if (!ok) {
            LOGE("Resume frame update failed");
        }
    }

    if (!paused) {
        LOGI("Display screen unpaused");
    } else if (!screen->paused) {
        LOGI("Display screen paused");
    } else {
        LOGI("Display screen re-paused");
    }

    screen->paused = paused;
}

void
sc_screen_toggle_fullscreen(struct sc_screen *screen) {
    assert(screen->video);

    bool req_fullscreen =
        !(SDL_GetWindowFlags(screen->window) & SDL_WINDOW_FULLSCREEN);

    bool ok = SDL_SetWindowFullscreen(screen->window, req_fullscreen);
    if (!ok) {
        LOGW("Could not switch fullscreen mode: %s", SDL_GetError());
        return;
    }

    LOGD("Requested %s mode", req_fullscreen ? "fullscreen" : "windowed");
}

void
sc_screen_resize_to_fit(struct sc_screen *screen) {
    assert(screen->video);

    if (!is_windowed(screen)) {
        return;
    }

    if (screen->render_fit == SC_RENDER_FIT_STRETCHED) {
        // nothing to do
        return;
    }

    struct sc_size window_size = get_view_size(screen);

    if (screen->render_fit == SC_RENDER_FIT_UNSCALED) {
        struct sc_size content_size = screen->content_size;
        set_aspect_ratio(screen, content_size);
        set_view_size(screen, content_size);

        int32_t x_offset = 0;
        if (content_size.width < window_size.width) {
            x_offset = (window_size.width - content_size.width) / 2;
        }
        int32_t y_offset = 0;
        if (content_size.height < window_size.height) {
            y_offset = (window_size.height - content_size.height) / 2;
        }
        assert(x_offset >= 0 && y_offset >= 0);
        if (x_offset || y_offset) {
            struct sc_point pos = sc_sdl_get_window_position(screen->window);
            pos.x += x_offset;
            pos.y += y_offset;
            sc_sdl_set_window_position(screen->window, pos);
        }

        LOGD("Resized to content size: %ux%u", content_size.width,
                                               content_size.height);
        return;
    }

    assert(screen->render_fit == SC_RENDER_FIT_LETTERBOX);

    struct sc_point point = sc_sdl_get_window_position(screen->window);

    struct sc_size optimal_size =
        get_optimal_size(window_size, screen->content_size, false);

    // Center the window related to the device screen
    assert(optimal_size.width <= window_size.width);
    assert(optimal_size.height <= window_size.height);

    struct sc_point new_position = {
        .x = point.x + (window_size.width - optimal_size.width) / 2,
        .y = point.y + (window_size.height - optimal_size.height) / 2,
    };

    set_aspect_ratio(screen, optimal_size);
    set_view_size(screen, optimal_size);
    sc_sdl_set_window_position(screen->window, new_position);
    LOGD("Resized to optimal size: %ux%u", optimal_size.width,
                                           optimal_size.height);
}

void
sc_screen_resize_to_pixel_perfect(struct sc_screen *screen) {
    assert(screen->video);

    if (!is_windowed(screen)) {
        return;
    }

    struct sc_size content_size = screen->content_size;
    set_aspect_ratio(screen, content_size);
    set_view_size(screen, content_size);
    LOGD("Resized to pixel-perfect: %ux%u", content_size.width,
                                            content_size.height);
}

static void
sc_disconnect_on_icon_loaded(struct sc_disconnect *d, SDL_Surface *icon,
                             void *userdata) {
    (void) d;
    (void) userdata;

    bool ok = sc_push_event_with_data(SC_EVENT_DISCONNECTED_ICON_LOADED, icon);
    if (!ok) {
        sc_icon_destroy(icon);
    }
}

static void
sc_disconnect_on_timeout(struct sc_disconnect *d, void *userdata) {
    (void) d;
    (void) userdata;

    bool ok = sc_push_event(SC_EVENT_DISCONNECTED_TIMEOUT);
    (void) ok; // ignore failure
}

void
sc_screen_handle_event(struct sc_screen *screen, const SDL_Event *event) {
    switch (event->type) {
        case SC_EVENT_OPEN_WINDOW: {
            struct sc_size *size = event->user.data1;
            assert(size);

            screen->frame_size = *size;
            free(size);
            screen->content_size = get_oriented_size(screen->frame_size,
                                                     screen->orientation);
            sc_screen_show_initial_window(screen);

            if (sc_screen_is_relative_mode(screen)) {
                // Capture mouse on start
                sc_mouse_capture_set_active(&screen->mc, true);
            }

            sc_screen_render(screen, false);
            return;
        }
        case SC_EVENT_NEW_FRAME: {
            bool ok = sc_screen_update_frame(screen);
            if (!ok) {
                LOGE("Frame update failed\n");
            }
            return;
        }
        case SDL_EVENT_WINDOW_EXPOSED:
            sc_screen_render(screen, true);
            return;
        case SDL_EVENT_WINDOW_MOVED:
            sc_screen_save_prefs(screen);
            return;
        case SDL_EVENT_WINDOW_MOUSE_LEAVE:
        case SDL_EVENT_WINDOW_FOCUS_LOST:
            sc_screen_set_pinch(screen, false, 0, 0, false, false, false);
            sc_screen_set_side_state(screen, SC_SIDE_NONE,
                                     screen->side_pressed);
            break;
        case SDL_EVENT_DROP_BEGIN:
        case SDL_EVENT_DROP_POSITION:
            // A file is being dragged over the window
            sc_macos_drop_hover(true);
            return;
        case SDL_EVENT_DROP_COMPLETE:
            sc_macos_drop_hover(false);
            return;
// If defined, then the actions are already performed by the event watcher
#ifndef CONTINUOUS_RESIZING_WORKAROUND
        case SDL_EVENT_WINDOW_RESIZED:
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            sc_screen_on_resize(screen, &event->window);
            return;
#endif
        case SDL_EVENT_WINDOW_RESTORED:
            if (screen->video && is_windowed(screen)) {
                apply_pending_resize(screen);
                sc_screen_render(screen, true);
            }
            return;
        case SDL_EVENT_WINDOW_ENTER_FULLSCREEN:
            LOGD("Switched to fullscreen mode");
            assert(screen->video);
            return;
        case SDL_EVENT_WINDOW_LEAVE_FULLSCREEN:
            LOGD("Switched to windowed mode");
            assert(screen->video);
            if (is_windowed(screen)) {
                apply_pending_resize(screen);
                sc_screen_render(screen, true);
            }
            return;
        case SC_EVENT_DEVICE_DISCONNECTED:
            assert(!screen->disconnected);
            screen->disconnected = true;
            if (!screen->window_shown) {
                // No window open
                return;
            }

            sc_input_manager_handle_event(&screen->im, event);

            sc_texture_reset(&screen->tex);
            sc_screen_render(screen, true);

            sc_tick deadline = sc_tick_now() + SC_TICK_FROM_SEC(2);
            static const struct sc_disconnect_callbacks cbs = {
                .on_icon_loaded = sc_disconnect_on_icon_loaded,
                .on_timeout = sc_disconnect_on_timeout,
            };
            bool ok =
                sc_disconnect_start(&screen->disconnect, deadline, &cbs, NULL);
            if (ok) {
                screen->disconnect_started = true;
            }

            return;
    }

    if (sc_screen_is_relative_mode(screen)
            && sc_mouse_capture_handle_event(&screen->mc, event)) {
        // The mouse capture handler consumed the event
        return;
    }

    sc_input_manager_handle_event(&screen->im, event);
}

void
sc_screen_handle_disconnection(struct sc_screen *screen) {
    if (!screen->window_shown) {
        // No window open, quit immediately
        return;
    }

    if (!screen->disconnect_started) {
        // If sc_disconnect_start() failed, quit immediately
        return;
    }

    SDL_Event event;
    while (SDL_WaitEvent(&event)) {
        switch (event.type) {
            case SDL_EVENT_WINDOW_EXPOSED:
                sc_screen_render(screen, true);
                break;
            case SC_EVENT_DISCONNECTED_ICON_LOADED: {
                SDL_Surface *icon_disconnected = event.user.data1;
                assert(icon_disconnected);

                bool ok = sc_screen_set_texture_from_surface(screen,
                                                             icon_disconnected);
                if (ok) {
                    screen->content_size.width = icon_disconnected->w;
                    screen->content_size.height = icon_disconnected->h;
                    sc_screen_render(screen, true);
                } else {
                    // not fatal
                    LOGE("Could not set disconnected icon");
                }

                sc_icon_destroy(icon_disconnected);
                break;
            }
            case SC_EVENT_DISCONNECTED_TIMEOUT:
                LOGD("Closing after device disconnection");
                return;
            case SDL_EVENT_QUIT:
                LOGD("User requested to quit");
                sc_screen_interrupt_disconnect(screen);
                return;
            default:
                sc_input_manager_handle_event(&screen->im, &event);
        }
    }
}

struct sc_point
sc_screen_convert_window_to_frame_coords(struct sc_screen *screen,
                                         int32_t x, int32_t y) {
    assert(screen->video);

    enum sc_orientation orientation = screen->orientation;

    int32_t w = screen->content_size.width;
    int32_t h = screen->content_size.height;

    // screen->rect must be initialized to avoid a division by zero
    assert(screen->rect.w && screen->rect.h);

    x = (int64_t) (x - screen->rect.x) * w / screen->rect.w;
    y = (int64_t) (y - screen->rect.y) * h / screen->rect.h;

    struct sc_point result;
    switch (orientation) {
        case SC_ORIENTATION_0:
            result.x = x;
            result.y = y;
            break;
        case SC_ORIENTATION_90:
            result.x = y;
            result.y = w - x;
            break;
        case SC_ORIENTATION_180:
            result.x = w - x;
            result.y = h - y;
            break;
        case SC_ORIENTATION_270:
            result.x = h - y;
            result.y = x;
            break;
        case SC_ORIENTATION_FLIP_0:
            result.x = w - x;
            result.y = y;
            break;
        case SC_ORIENTATION_FLIP_90:
            result.x = h - y;
            result.y = w - x;
            break;
        case SC_ORIENTATION_FLIP_180:
            result.x = x;
            result.y = h - y;
            break;
        default:
            assert(orientation == SC_ORIENTATION_FLIP_270);
            result.x = y;
            result.y = x;
            break;
    }

    return result;
}
