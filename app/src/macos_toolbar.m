#include "macos_toolbar.h"

#import <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <unistd.h>
#include <SDL3/SDL_properties.h>
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_video.h>

#include "util/log.h"

// Titlebar toolbar items
static NSString *const kNotifications = @"scrcpy.notifications";
static NSString *const kSettings = @"scrcpy.settings";
static NSString *const kRotate = @"scrcpy.rotate";
static NSString *const kVolumeDown = @"scrcpy.volume_down";
static NSString *const kVolumeUp = @"scrcpy.volume_up";
static NSString *const kPower = @"scrcpy.power";
static NSString *const kAwake = @"scrcpy.awake";
static NSString *const kScreenshot = @"scrcpy.screenshot";
static NSString *const kRecord = @"scrcpy.record";
static NSString *const kPaste = @"scrcpy.paste";
static NSString *const kApps = @"scrcpy.apps";
static NSString *const kInfo = @"scrcpy.info";
static NSString *const kCopy = @"scrcpy.copy";

// Tags of the buttons handled locally (below 100, the tag is a
// sc_toolbar_button forwarded to the C callback)
enum {
    SC_TAG_SCREENSHOT = 100,
    SC_TAG_RECORD,
    SC_TAG_DEV_TOOLS,
    SC_TAG_OVERFLOW,
    SC_TAG_KEEP_AWAKE,
    SC_TAG_APPS,
    SC_TAG_INFO,
};

static const NSTimeInterval kSubtitleDuration = 4.0;

typedef void (^SCAdbDone)(int status, NSString *out, NSString *err);

@interface SCController : NSObject <NSToolbarDelegate, NSTableViewDataSource,
                                    NSTableViewDelegate, NSSearchFieldDelegate,
                                    NSWindowDelegate>
@property(nonatomic, assign) sc_toolbar_callback callback;
@property(nonatomic, assign) sc_frame_callback frameCallback;
@property(nonatomic, assign) sc_shape_callback shapeCallback;
@property(nonatomic, assign) sc_scale_callback scaleCallback;
@property(nonatomic, assign) void *userdata;
@property(nonatomic, copy) NSString *adb;
@property(nonatomic, copy) NSString *serial;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, assign) SDL_Window *sdlWindow;
@property(nonatomic, strong) NSMenu *toolsMenu;
@property(nonatomic, weak) NSToolbarItem *recordItem;
@property(nonatomic, weak) NSToolbarItem *awakeItem;
@property(nonatomic, strong) NSTask *recordTask;
@property(nonatomic, copy) NSString *recordRemotePath;
@property(nonatomic, copy) NSString *recordLocalPath;
@property(nonatomic, assign) NSUInteger subtitleToken;
@property(nonatomic, assign) BOOL screenOffUsed;
// Live device info
@property(nonatomic, strong) NSWindow *infoWindow;
@property(nonatomic, strong) NSTimer *infoTimer;
@property(nonatomic, strong) NSDictionary<NSString *, id> *infoLabels;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *tempHistory;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *memHistory;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *batteryHistory;
@property(nonatomic, assign) BOOL infoBusy;
@property(nonatomic, strong) NSDictionary *lastInfo;
@property(nonatomic, strong) NSButton *infoLive;
// App manager
@property(nonatomic, strong) NSWindow *appWindow;
@property(nonatomic, strong) NSTableView *appTable;
@property(nonatomic, strong) NSSearchField *appSearch;
@property(nonatomic, strong) NSButton *appSystemCheck;
@property(nonatomic, strong) NSTextField *appStatus;
@property(nonatomic, strong) NSArray<NSButton *> *appButtons;
@property(nonatomic, strong) NSArray<NSDictionary *> *apps;
@property(nonatomic, strong) NSArray<NSDictionary *> *shownApps;
@property(nonatomic, assign) BOOL appsLoading;
// Device settings changed from the menus, given back when the app closes
@property(nonatomic, assign) BOOL displayOverridden;
@property(nonatomic, assign) BOOL batteryOverridden;
@property(nonatomic, assign) BOOL saverOn;
@property(nonatomic, assign) BOOL proxyOverridden;
@property(nonatomic, copy) NSString *fontOriginal;
// Drag and drop
@property(nonatomic, strong) NSMutableArray<NSString *> *dropQueue;
@property(nonatomic, assign) BOOL dropBusy;
@property(nonatomic, assign) NSUInteger dropTotal;
@property(nonatomic, assign) NSUInteger dropIndex;
@property(nonatomic, assign) NSUInteger dropInstalled;
@property(nonatomic, assign) NSUInteger dropSent;
@property(nonatomic, strong) NSMutableArray<NSString *> *dropFailures;
@property(nonatomic, strong) NSMutableArray<NSString *> *dropDowngrades;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *dropSentFiles;
@property(nonatomic, assign) NSUInteger dropToken;
@property(nonatomic, assign) BOOL dropDowngradeMode;
@property(nonatomic, strong) NSView *dropOverlay;
@property(nonatomic, strong) NSTextField *dropLabel;
@end

// Kept alive for the whole session
static SCController *g_controller;

static NSString *const kKeepOnTopDefaultsKey = @"scrcpy.keepOnTop";

static NSImage *
menu_image(NSString *symbol, NSString *description) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol
                               accessibilityDescription:description];
    image.template = YES;
    return image;
}

@implementation SCController

#pragma mark - Titlebar toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:
        (NSToolbar *)toolbar {
    return @[kNotifications, kSettings, kApps, kInfo, kScreenshot, kRecord,
             kPaste,
             kCopy,
             NSToolbarFlexibleSpaceItemIdentifier,
             kAwake, kRotate, kVolumeDown, kVolumeUp, kPower];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:
        (NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    struct {
        __unsafe_unretained NSString *id;
        __unsafe_unretained NSString *label;
        __unsafe_unretained NSString *symbol;
        NSInteger button;
    } defs[] = {
        {kNotifications, @"Notifications", @"bell",
            SC_TOOLBAR_BUTTON_NOTIFICATIONS},
        {kAwake, @"Keep device awake", @"sun.max", SC_TAG_KEEP_AWAKE},
        {kApps, @"App Manager (⌃⌘X)", @"square.grid.2x2", SC_TAG_APPS},
        {kInfo, @"Device Info (⌃⌘G)", @"gauge", SC_TAG_INFO},
        {kScreenshot, @"Screenshot (saved on Desktop)", @"camera",
            SC_TAG_SCREENSHOT},
        {kRecord, @"Record screen", @"record.circle", SC_TAG_RECORD},
        {kPaste, @"Paste the Mac clipboard on the device (⌥⌘V)",
            @"doc.on.clipboard", SC_TOOLBAR_BUTTON_PASTE},
        {kCopy, @"Copy the selection of the device to the Mac (⌥⌘C)",
            @"doc.on.doc", SC_TOOLBAR_BUTTON_COPY},
        {kSettings, @"Settings panel", @"gearshape",
            SC_TOOLBAR_BUTTON_SETTINGS},
        {kRotate, @"Rotate device", @"rotate.right",
            SC_TOOLBAR_BUTTON_ROTATE},
        {kVolumeDown, @"Volume down", @"speaker.minus",
            SC_TOOLBAR_BUTTON_VOLUME_DOWN},
        {kVolumeUp, @"Volume up", @"speaker.plus",
            SC_TOOLBAR_BUTTON_VOLUME_UP},
        {kPower, @"Power", @"power",
            SC_TOOLBAR_BUTTON_POWER},
    };

    for (size_t i = 0; i < sizeof(defs) / sizeof(defs[0]); ++i) {
        if (![defs[i].id isEqualToString:identifier]) {
            continue;
        }

        NSToolbarItem *item =
            [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
        item.label = defs[i].label;
        item.paletteLabel = defs[i].label;
        item.toolTip = defs[i].label;
        item.tag = defs[i].button;
        item.target = self;
        item.action = @selector(buttonClicked:);
        item.bordered = YES;
        NSImage *image =
            [NSImage imageWithSystemSymbolName:defs[i].symbol
                      accessibilityDescription:defs[i].label];
        if (image) {
            item.image = image;
        } else {
            item.title = defs[i].label;
        }
        if ([identifier isEqualToString:kAwake]) {
            self.awakeItem = item;
            [self updateAwakeUI];
        }
        if ([identifier isEqualToString:kRecord]) {
            self.recordItem = item;
        }
        return item;
    }
    return nil;
}

#pragma mark - Window menu

- (void)toggleKeepOnTop:(NSMenuItem *)item {
    bool on = SDL_GetWindowFlags(self.sdlWindow) & SDL_WINDOW_ALWAYS_ON_TOP;
    if (!SDL_SetWindowAlwaysOnTop(self.sdlWindow, !on)) {
        LOGW("Could not change always-on-top: %s", SDL_GetError());
        return;
    }
    [[NSUserDefaults standardUserDefaults] setBool:!on
                                            forKey:kKeepOnTopDefaultsKey];
    [self updateToolPanelLevels];
}

// Restore the setting saved by the last session (--always-on-top forces it)
- (void)applySavedKeepOnTop {
    bool saved = [[NSUserDefaults standardUserDefaults]
                      boolForKey:kKeepOnTopDefaultsKey];
    bool on = SDL_GetWindowFlags(self.sdlWindow) & SDL_WINDOW_ALWAYS_ON_TOP;
    if (saved && !on && !SDL_SetWindowAlwaysOnTop(self.sdlWindow, true)) {
        LOGW("Could not restore always-on-top: %s", SDL_GetError());
    }
}

// Reflect the actual state (it may also be set by --always-on-top)
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleKeepOnTop:)) {
        bool on = SDL_GetWindowFlags(self.sdlWindow)
                & SDL_WINDOW_ALWAYS_ON_TOP;
        item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (item.action == @selector(selectShape:)) {
        NSString *current = [self currentShapeName];
        BOOL on = item.tag == 0 ? !current.length
            : [current isEqualToString:@(sc_frame_shape_name((int) item.tag - 1))];
        item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(toggleRestoreOnQuit:)) {
        item.state = [self restoreOnQuit] ? NSControlStateValueOn
                                          : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(toggleOpenAfterSend:)) {
        item.state = [self openAfterSend] ? NSControlStateValueOn
                                          : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(toggleGrantPermissions:)) {
        item.state = [self grantPermissions] ? NSControlStateValueOn
                                             : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(selectTransferFolder:)) {
        item.state = [kTransferFolders[item.tag]
                         isEqualToString:[self transferFolder]]
                   ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(selectAudio:)) {
        item.state = [kAudioIds[item.tag] isEqualToString:[self currentAudio]]
                   ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(toggleScreenOffOnStart:)) {
        item.state = [self screenOffOnStart] ? NSControlStateValueOn
                                             : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(selectFps:)) {
        item.state = [kFpsIds[item.tag] isEqualToString:[self currentFps]]
                   ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(selectQuality:)) {
        item.state = [kQualityIds[item.tag] isEqualToString:
                         [self currentQuality]]
                   ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(toggleKeepAwake:)) {
        item.state = [self keepAwakeEnabled] ? NSControlStateValueOn
                                             : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(buttonClicked:)
            && item.tag == SC_TAG_RECORD) {
        item.title = self.recordTask ? @"Stop Recording" : @"Start Recording";
        return YES;
    }
    if (item.action == @selector(selectFrame:)) {
        item.state = item.tag == (NSInteger) sc_prefs_load_frame()
                   ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(switchToWifi:)) {
        return ![self isWifiSerial];
    }
    if (item.action == @selector(disconnectWifi:)) {
        return [self isWifiSerial];
    }
    return YES;
}

- (void)installWindowMenuItem {
    NSMenu *menu = NSApp.windowsMenu;
    if (!menu) {
        NSMenuItem *window_item = [NSApp.mainMenu itemWithTitle:@"Window"];
        menu = window_item.submenu;
    }
    if (!menu) {
        LOGW("Could not find the Window menu");
        return;
    }

    NSMenuItem *item =
        [[NSMenuItem alloc] initWithTitle:@"Keep on Top"
                                   action:@selector(toggleKeepOnTop:)
                            keyEquivalent:@"t"];
    item.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    item.target = self;
    item.image = menu_image(@"pin", @"Keep on Top");
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:item];
    [menu addItem:[self scaleMenuItem]];
}

#pragma mark - Actions

- (void)buttonClicked:(id)sender {
    NSInteger tag = [sender tag];
    switch (tag) {
        case SC_TAG_SCREENSHOT:
            [self takeScreenshot];
            return;
        case SC_TAG_RECORD:
            [self toggleRecording];
            return;
        case SC_TAG_OVERFLOW:
            [[self buildOverflowMenu] popUpMenuPositioningItem:nil
                                                    atLocation:NSMakePoint(0, 0)
                                                        inView:sender];
            return;
        case SC_TAG_DEV_TOOLS:
            [[self buildPopupMenu] popUpMenuPositioningItem:nil
                                                 atLocation:NSMakePoint(0, 0)
                                                     inView:sender];
            return;
        case SC_TAG_KEEP_AWAKE:
            [self toggleKeepAwake:sender];
            return;
        case SC_TAG_APPS:
            [self showAppManager:sender];
            return;
        case SC_TAG_INFO:
            [self showDeviceInfo:sender];
            return;
        case SC_TOOLBAR_BUTTON_ROTATE:
            [self rotateDevice:SC_ROTATE_TOGGLE];
            return;
        case SC_TOOLBAR_BUTTON_PASTE:
            [self pasteToDevice:sender];
            return;
        case SC_TOOLBAR_BUTTON_COPY:
            [self copyFromDevice:sender];
            return;
    }
    if (tag == SC_TOOLBAR_BUTTON_SCREEN_OFF) {
        self.screenOffUsed = YES;
        [self flash:@"Device screen off: it is still on and controllable"];
    } else if (tag == SC_TOOLBAR_BUTTON_SCREEN_ON) {
        self.screenOffUsed = NO;
    }
    if (self.callback) {
        self.callback((enum sc_toolbar_button) tag, self.userdata);
    }
}

// Show a message as the window subtitle for a few seconds
- (void)flash:(NSString *)message {
    // Debug: SCRCPY_TEST_FLASH_LOG=<file> gets every message
    const char *flash_log = getenv("SCRCPY_TEST_FLASH_LOG");
    if (flash_log) {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:@(flash_log)];
        if (!h) {
            [[NSFileManager defaultManager] createFileAtPath:@(flash_log)
                                                    contents:nil attributes:nil];
            h = [NSFileHandle fileHandleForWritingAtPath:@(flash_log)];
        }
        [h seekToEndOfFile];
        [h writeData:[[message stringByAppendingString:@"\n"]
                         dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
    if (@available(macOS 11.0, *)) {
        NSUInteger token = ++self.subtitleToken;
        self.window.subtitle = message;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t) (kSubtitleDuration * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            if (token == self.subtitleToken) {
                self.window.subtitle = self.recordTask
                                     ? @"● Recording… (click record to stop)"
                                     : @"";
            }
        });
    }
}

- (NSString *)timestamp {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    return [f stringFromDate:[NSDate date]];
}

- (NSString *)desktopPathForFile:(NSString *)name {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(
        NSDesktopDirectory, NSUserDomainMask, YES);
    NSString *dir = dirs.firstObject ?: NSHomeDirectory();
    return [dir stringByAppendingPathComponent:name];
}

// Run adb asynchronously. If stdoutFile is not nil, the standard output is
// written to it instead of being captured. The completion block is called on
// the main queue.
- (NSTask *)runAdb:(NSArray<NSString *> *)args
        stdoutFile:(NSFileHandle *)stdoutFile
              done:(SCAdbDone)done {
    return [self runAdb:args useSerial:YES stdoutFile:stdoutFile done:done];
}

// Same as above, but useSerial:NO runs a command that is not tied to the
// current device (connect, pair, mdns...)
- (NSTask *)runAdb:(NSArray<NSString *> *)args
         useSerial:(BOOL)useSerial
        stdoutFile:(NSFileHandle *)stdoutFile
              done:(SCAdbDone)done {
    NSMutableArray *argv = [NSMutableArray arrayWithObject:self.adb];
    if (useSerial && self.serial) {
        [argv addObjectsFromArray:@[@"-s", self.serial]];
    }
    [argv addObjectsFromArray:args];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = argv;
    NSPipe *outPipe = stdoutFile ? nil : [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = stdoutFile ?: outPipe;
    task.standardError = errPipe;

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        LOGW("Could not run adb: %s", error.localizedDescription.UTF8String);
        if (done) {
            done(-1, @"", error.localizedDescription);
        }
        return nil;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *out = outPipe ? [outPipe.fileHandleForReading
                                    readDataToEndOfFile] : [NSData data];
        NSData *err = [errPipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        int status = task.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) {
                done(status,
                     [[NSString alloc] initWithData:out
                                           encoding:NSUTF8StringEncoding]
                         ?: @"",
                     [[NSString alloc] initWithData:err
                                           encoding:NSUTF8StringEncoding]
                         ?: @"");
            }
        });
    });
    return task;
}

- (void)runShell:(NSString *)command
         success:(NSString *)message
      completion:(SCAdbDone)completion {
    [self runAdb:@[@"shell", command]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        if (status == 0) {
            [self flash:message];
        } else {
            [self flash:[NSString stringWithFormat:@"Failed: %@",
                [err stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet]]];
        }
        if (completion) {
            completion(status, out, err);
        }
    }];
}

- (void)takeScreenshot {
    NSString *path = [self desktopPathForFile:
        [NSString stringWithFormat:@"scrcpy-%@.png", [self timestamp]]];
    [[NSFileManager defaultManager] createFileAtPath:path
                                            contents:nil
                                          attributes:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) {
        [self flash:@"Could not create the screenshot file"];
        return;
    }

    [self runAdb:@[@"exec-out", @"screencap", @"-p"]
        stdoutFile:file
              done:^(int status, NSString *out, NSString *err) {
        [file closeFile];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (status != 0 || !image) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            [self flash:@"Screenshot failed"];
            return;
        }
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb writeObjects:@[image]];
        [self flash:[NSString stringWithFormat:
            @"Screenshot saved on Desktop and copied: %@",
            path.lastPathComponent]];
    }];
}

@end

#pragma mark - Round buttons

// Button whose hover and pressed feedback is a circle (not a square)
@interface SCRoundButton : NSButton
@property(nonatomic, assign) BOOL hovering;
@property(nonatomic, assign) BOOL pressing;
@end

@implementation SCRoundButton

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.bordered = NO;
        self.imagePosition = NSImageOnly;
        self.imageScaling = NSImageScaleNone;
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        self.contentTintColor = NSColor.labelColor;
    }
    return self;
}

- (void)updateFeedback {
    CGFloat alpha = self.pressing ? 0.24 : self.hovering ? 0.12 : 0;
    __block CGColorRef color = NULL;
    void (^resolve)(void) = ^{
        color = CGColorRetain([NSColor.labelColor
            colorWithAlphaComponent:alpha].CGColor);
    };
    if (@available(macOS 11.0, *)) {
        [self.effectiveAppearance performAsCurrentDrawingAppearance:resolve];
    } else {
        resolve();
    }
    self.layer.backgroundColor = alpha ? color : NULL;
    CGColorRelease(color);
}

- (void)layout {
    [super layout];
    self.layer.cornerRadius = MIN(self.bounds.size.width,
                                  self.bounds.size.height) / 2;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateFeedback];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    [self addTrackingArea:[[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited
                   | NSTrackingActiveInKeyWindow
                   | NSTrackingInVisibleRect
               owner:self
            userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovering = YES;
    [self updateFeedback];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovering = NO;
    [self updateFeedback];
}

- (void)mouseDown:(NSEvent *)event {
    self.pressing = YES;
    [self updateFeedback];
    // Tracks the mouse until it is released, and sends the action
    [super mouseDown:event];
    self.pressing = NO;
    [self updateFeedback];
}

@end

#pragma mark - Bottom navigation bar

// Bar embedded at the bottom of the window content. The video is rendered
// above it, so it is always visible and never covers the device screen.
@interface SCNavBar : NSView
@property(nonatomic, strong) NSStackView *center;
@property(nonatomic, strong) NSStackView *right;
@property(nonatomic, strong) NSButton *overflow;
- (instancetype)initWithController:(SCController *)controller;
@end

@implementation SCNavBar

// Click targets: the navigation buttons are the biggest ones
static const CGFloat kNavButtonWidth = 48;
static const CGFloat kNavButtonHeight = 48;
static const CGFloat kToolButtonWidth = 42;
static const CGFloat kToolButtonHeight = 42;

static NSButton *
make_sized_button(SCController *controller, NSString *symbol, NSString *tooltip,
                  NSInteger tag, CGFloat width, CGFloat height) {
    NSButton *b = [[SCRoundButton alloc]
        initWithFrame:NSMakeRect(0, 0, width, height)];
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol
                               accessibilityDescription:tooltip];
    if (image) {
        // Bigger icons for the biggest (navigation) buttons
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
            configurationWithPointSize:width >= kNavButtonWidth ? 21 : 17
                                weight:NSFontWeightRegular];
        b.image = [image imageWithSymbolConfiguration:cfg];
    } else {
        b.title = tooltip;
        b.imagePosition = NSNoImage;
    }
    b.toolTip = tooltip;
    b.tag = tag;
    b.target = controller;
    b.action = @selector(buttonClicked:);
    [b.widthAnchor constraintEqualToConstant:width].active = YES;
    [b.heightAnchor constraintEqualToConstant:height].active = YES;
    return b;
}

static NSButton *
make_button(SCController *controller, NSString *symbol, NSString *tooltip,
            NSInteger tag) {
    return make_sized_button(controller, symbol, tooltip, tag,
                             kToolButtonWidth, kToolButtonHeight);
}

static NSButton *
make_nav_button(SCController *controller, NSString *symbol, NSString *tooltip,
                NSInteger tag) {
    return make_sized_button(controller, symbol, tooltip, tag,
                             kNavButtonWidth, kNavButtonHeight);
}

static NSStackView *
make_stack(NSArray<NSView *> *views) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 8;
    return stack;
}

- (instancetype)initWithController:(SCController *)controller {
    self = [super initWithFrame:NSMakeRect(0, 0, 400, SC_NAV_BAR_HEIGHT)];
    if (!self) {
        return nil;
    }
    self.autoresizingMask = NSViewWidthSizable;

    NSBox *background = [[NSBox alloc] initWithFrame:self.bounds];
    background.boxType = NSBoxCustom;
    background.borderWidth = 0;
    background.fillColor = [NSColor windowBackgroundColor];
    background.contentViewMargins = NSZeroSize;
    background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:background];

    NSBox *separator = [[NSBox alloc]
        initWithFrame:NSMakeRect(0, SC_NAV_BAR_HEIGHT - 1, 400, 1)];
    separator.boxType = NSBoxSeparator;
    separator.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:separator];

    self.center = make_stack(@[
        make_nav_button(controller, @"arrowtriangle.backward", @"Back (⌘B)",
                    SC_TOOLBAR_BUTTON_BACK),
        make_nav_button(controller, @"circle", @"Home (⇧⌘H)",
                    SC_TOOLBAR_BUTTON_HOME),
        make_nav_button(controller, @"square", @"Recents (⌘S)",
                    SC_TOOLBAR_BUTTON_APP_SWITCH),
    ]);
    self.center.spacing = 14;
    self.right = make_stack(@[
        make_button(controller, @"ladybug",
                    @"React Native developer menu (⌥⌘M)",
                    SC_TOOLBAR_BUTTON_DEV_MENU),
        make_button(controller, @"arrow.clockwise",
                    @"Reload React Native (⌥⌘L)",
                    SC_TOOLBAR_BUTTON_DEV_RELOAD),
        make_button(controller, @"hammer", @"Developer tools",
                    SC_TAG_DEV_TOOLS),
    ]);

    // Replaces the right group when it does not fit
    self.overflow = make_button(controller, @"ellipsis.circle",
                                @"Debug tools", SC_TAG_OVERFLOW);
    self.overflow.translatesAutoresizingMaskIntoConstraints = YES;
    self.overflow.hidden = YES;
    [self addSubview:self.overflow];

    // Groups are positioned manually (see layoutGroups)
    for (NSStackView *stack in @[self.center, self.right]) {
        stack.translatesAutoresizingMaskIntoConstraints = YES;
        [self addSubview:stack];
    }
    [self layoutGroups];
    return self;
}

- (void)layoutGroups {
    const CGFloat margin = 14;
    const CGFloat gap = 14;
    const CGFloat w = self.bounds.size.width;
    const CGFloat h = SC_NAV_BAR_HEIGHT - 1; // below the separator

    NSSize cs = self.center.fittingSize;
    NSSize rs = self.right.fittingSize;

    // The navigation buttons are exactly at the center of the window, as the
    // buttons of a real device are at the center of its screen
    CGFloat center_x = floor((w - cs.width) / 2);
    self.center.frame = NSMakeRect(center_x, floor((h - cs.height) / 2),
                                   cs.width, cs.height);

    // The right group (React Native, tools) collapses into a menu button
    bool fits = center_x + cs.width + gap <= w - margin - rs.width;
    self.right.hidden = !fits;
    self.overflow.hidden = fits;

    if (fits) {
        self.right.frame = NSMakeRect(w - margin - rs.width,
                                      floor((h - rs.height) / 2),
                                      rs.width, rs.height);
    } else {
        NSSize os = self.overflow.frame.size;
        self.overflow.frame = NSMakeRect(w - margin - os.width,
                                         floor((h - os.height) / 2),
                                         os.width, os.height);
    }
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self layoutGroups];
}

// The bar belongs to the window: its events must not reach the SDL view
// (they would be sent to the device as touches)
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {}
- (void)mouseDragged:(NSEvent *)event {}
- (void)mouseMoved:(NSEvent *)event {}
- (void)rightMouseDown:(NSEvent *)event {}
- (void)rightMouseUp:(NSEvent *)event {}
- (void)otherMouseDown:(NSEvent *)event {}
- (void)otherMouseUp:(NSEvent *)event {}
- (void)scrollWheel:(NSEvent *)event {}

@end

// The window does not retain its toolbar delegate (see g_controller above)

void
sc_macos_drop_file(const char *path) {
    [g_controller dropFile:@(path)];
}

void
sc_macos_drop_hover(bool on) {
    [g_controller setDropHover:on];
}

void
sc_macos_rotate_device(enum sc_rotate_direction direction) {
    [g_controller rotateDevice:direction];
}

void
sc_macos_toolbar_shutdown(void) {
    [g_controller shutdownSync];
}

bool
sc_macos_toolbar_init(SDL_Window *window, sc_toolbar_callback callback,
                      sc_frame_callback frame_callback,
                      sc_shape_callback shape_callback,
                      sc_scale_callback scale_callback, void *userdata,
                      const char *adb_executable, const char *serial) {
    SDL_PropertiesID props = SDL_GetWindowProperties(window);
    NSWindow *nswindow = (__bridge NSWindow *)
        SDL_GetPointerProperty(props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER,
                               NULL);
    if (!nswindow) {
        LOGW("Could not get NSWindow, navigation toolbar disabled");
        return false;
    }

    g_controller = [[SCController alloc] init];
    g_controller.callback = callback;
    g_controller.frameCallback = frame_callback;
    g_controller.shapeCallback = shape_callback;
    g_controller.scaleCallback = scale_callback;
    g_controller.userdata = userdata;
    g_controller.adb = adb_executable ? @(adb_executable) : @"adb";
    g_controller.serial = serial ? @(serial) : nil;
    g_controller.window = nswindow;
    g_controller.sdlWindow = window;
    [g_controller installEditMenu];
    [g_controller installDeviceMenu];
    [g_controller installDeveloperMenu];
    [g_controller installViewMenuItems];
    [g_controller installWindowMenuItem];
    [g_controller applyShortcutsToMenu:NSApp.mainMenu];
    dump_menu_if_requested();
    [g_controller applySavedKeepOnTop];
    if ([g_controller keepAwakeEnabled]) {
        [g_controller applyKeepAwake];
    }
    // The launcher starts the session with the display off in this case
    g_controller.screenOffUsed = [g_controller screenOffOnStart];
    g_controller.toolsMenu = [g_controller buildToolsMenu];

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"scrcpy.nav"];
    toolbar.delegate = g_controller;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = NO;
    nswindow.toolbar = toolbar;
    if (@available(macOS 11.0, *)) {
        nswindow.toolbarStyle = NSWindowToolbarStyleUnified;
    }

    SCNavBar *bar = [[SCNavBar alloc] initWithController:g_controller];

    SCDropOverlay *overlay = [[SCDropOverlay alloc] initWithFrame:
        NSMakeRect(0, SC_NAV_BAR_HEIGHT, nswindow.contentView.bounds.size.width,
                   nswindow.contentView.bounds.size.height - SC_NAV_BAR_HEIGHT)];
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.hidden = YES;
    NSTextField *label = [NSTextField labelWithString:@""];
    label.alignment = NSTextAlignmentCenter;
    label.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    label.textColor = NSColor.controlAccentColor;
    label.frame = NSMakeRect(0, 0, overlay.bounds.size.width, 60);
    label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin
                           | NSViewMaxYMargin;
    label.frame = NSMakeRect(0, overlay.bounds.size.height / 2 - 30,
                             overlay.bounds.size.width, 60);
    [overlay addSubview:label];
    [nswindow.contentView addSubview:overlay positioned:NSWindowAbove
                          relativeTo:nil];
    g_controller.dropOverlay = overlay;
    g_controller.dropLabel = label;

    // Debug: SCRCPY_TEST_INFO="show@8,report@14" opens the panel and logs it
    const char *test_info = getenv("SCRCPY_TEST_INFO");
    if (test_info) {
        for (NSString *entry in [@(test_info) componentsSeparatedByString:@","]) {
            NSArray *parts = [entry componentsSeparatedByString:@"@"];
            if (parts.count != 2) {
                continue;
            }
            NSString *name = parts[0];
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t) ([parts[1] doubleValue] * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                if ([name isEqualToString:@"show"]) {
                    [NSApp activateIgnoringOtherApps:YES];
                    [g_controller showDeviceInfo:nil];
                } else if ([name isEqualToString:@"report"]) {
                    [g_controller flash:[@"\n" stringByAppendingString:
                        g_controller.lastInfo
                            ? live_info_text(g_controller.lastInfo)
                            : @"no data"]];
                    [g_controller flash:[NSString stringWithFormat:
                        @"samples: temp=%lu mem=%lu", (unsigned long)
                        g_controller.tempHistory.count, (unsigned long)
                        g_controller.memHistory.count]];
                }
            });
        }
    }

    // Debug: SCRCPY_TEST_APPS="show@8,act:stop:<package>@12" drives the app
    // manager; after the list loads, it logs the number of apps
    const char *test_apps = getenv("SCRCPY_TEST_APPS");
    if (test_apps) {
        for (NSString *entry in [@(test_apps) componentsSeparatedByString:@","]) {
            NSArray *parts = [entry componentsSeparatedByString:@"@"];
            if (parts.count != 2) {
                continue;
            }
            NSString *name = parts[0];
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t) ([parts[1] doubleValue] * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                if ([name isEqualToString:@"show"]) {
                    [NSApp activateIgnoringOtherApps:YES];
                    [g_controller showAppManager:nil];
                } else if ([name isEqualToString:@"state"]) {
                    NSWindow *m = g_controller.window;
                    NSWindow *a = g_controller.appWindow;
                    [g_controller flash:[NSString stringWithFormat:
                        @"main level=%ld visible=%d | panel exists=%d visible=%d "
                        @"level=%ld occlusion=%lu hidesOnDeactivate=%d | "
                        @"app active=%d", (long) m.level, m.isVisible, a != nil,
                        a.isVisible, (long) a.level,
                        (unsigned long) a.occlusionState,
                        (int) ((NSPanel *) a).hidesOnDeactivate,
                        NSApp.isActive]];
                } else if ([name isEqualToString:@"report"]) {
                    NSMutableString *r = [NSMutableString stringWithFormat:
                        @"apps: %lu total, %lu shown", (unsigned long)
                        g_controller.apps.count, (unsigned long)
                        g_controller.shownApps.count];
                    for (NSDictionary *app in g_controller.apps) {
                        if ([app[@"package"] isEqualToString:@"com.opositatest"]
                            || [app[@"package"] isEqualToString:@"com.android.settings"]) {
                            [r appendFormat:@" | %@ v%@ %@ upd=%@ inst=%@",
                                app[@"package"], app[@"version"],
                                [app[@"system"] boolValue] ? @"system" : @"user",
                                app[@"updated"], app[@"installer"]];
                        }
                    }
                    [g_controller flash:r];
                } else if ([name hasPrefix:@"act:"]) {
                    NSArray *a = [name componentsSeparatedByString:@":"];
                    [g_controller runAppAction:a[1] package:a[2]];
                }
            });
        }
    }

    // Debug: SCRCPY_TEST_SIM="size_720@9,font_130@11,proxy=host:port@12"
    // runs menu actions of the simulation menus after the given seconds
    const char *test_sim = getenv("SCRCPY_TEST_SIM");
    if (test_sim) {
        for (NSString *entry in [@(test_sim) componentsSeparatedByString:@","]) {
            NSArray *parts = [entry componentsSeparatedByString:@"@"];
            if (parts.count != 2) {
                continue;
            }
            NSString *name = parts[0];
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t) ([parts[1] doubleValue] * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                if ([name hasPrefix:@"proxy="]) {
                    g_controller.proxyOverridden = YES;
                    [g_controller runShell:[@"settings put global http_proxy "
                        stringByAppendingString:[name substringFromIndex:6]]
                                   success:@"Proxy set (test)" completion:nil];
                    return;
                }
                NSMenuItem *item = [[NSMenuItem alloc] init];
                item.representedObject = name;
                [g_controller simItem:item];
            });
        }
    }

    // Debug: SCRCPY_TEST_CLIPBOARD="paste@9,copy@18" clicks the clipboard
    // buttons after the given seconds
    const char *test_clipboard = getenv("SCRCPY_TEST_CLIPBOARD");
    if (test_clipboard) {
        for (NSString *entry in [@(test_clipboard)
                                    componentsSeparatedByString:@","]) {
            NSArray *parts = [entry componentsSeparatedByString:@"@"];
            if (parts.count != 2) {
                continue;
            }
            NSString *action = parts[0];
            // "mac=<text>@<seconds>" simulates the device clipboard arriving
            NSString *mac_text = [action hasPrefix:@"mac="]
                ? [action substringFromIndex:4] : nil;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t) ([parts[1] doubleValue] * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                if (mac_text) {
                    NSPasteboard *pb = [NSPasteboard generalPasteboard];
                    [pb clearContents];
                    [pb setString:mac_text forType:NSPasteboardTypeString];
                } else if ([action isEqualToString:@"paste"]) {
                    [g_controller pasteToDevice:nil];
                } else if ([action isEqualToString:@"copy"]) {
                    [g_controller copyFromDevice:nil];
                } else if ([action isEqualToString:@"type"]) {
                    [g_controller typeClipboard:nil];
                }
            });
        }
    }

    // Debug: SCRCPY_TEST_DROP=<path>[:<path>...] drops files without the mouse
    const char *test_drop = getenv("SCRCPY_TEST_DROP");
    if (test_drop) {
        NSArray *paths = [@(test_drop) componentsSeparatedByString:@":"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            for (NSString *path in paths) {
                [g_controller dropFile:path];
            }
        });
    }
    NSView *content = nswindow.contentView;
    bar.frame = NSMakeRect(0, 0, content.bounds.size.width,
                           SC_NAV_BAR_HEIGHT);
    [content addSubview:bar positioned:NSWindowAbove relativeTo:nil];
    return true;
}
