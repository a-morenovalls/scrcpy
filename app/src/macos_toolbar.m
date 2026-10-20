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

// Horizontal bar (battery, memory, storage) with a color that follows the value
@interface SCBarView : NSView
@property(nonatomic, assign) double fraction;
@property(nonatomic, strong) NSColor *color;
@end

@implementation SCBarView

- (void)setFraction:(double)fraction {
    _fraction = MAX(0, MIN(1, fraction));
    self.needsDisplay = YES;
}

- (void)setColor:(NSColor *)color {
    _color = color;
    self.needsDisplay = YES;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, 10);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect r = NSInsetRect(self.bounds, 0, 1);
    CGFloat radius = r.size.height / 2;
    [[NSColor.quaternaryLabelColor colorWithAlphaComponent:0.35] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius]
        fill];
    NSRect fill = r;
    fill.size.width = MAX(r.size.height, r.size.width * self.fraction);
    [(self.color ?: NSColor.controlAccentColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:radius yRadius:radius]
        fill];
}

@end

// Line chart of the last values
@interface SCSparkView : NSView
@property(nonatomic, strong) NSArray<NSNumber *> *values;
@property(nonatomic, strong) NSColor *color;
@end

@implementation SCSparkView

- (void)setValues:(NSArray<NSNumber *> *)values {
    _values = values;
    self.needsDisplay = YES;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, 34);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect r = NSInsetRect(self.bounds, 1, 3);
    if (self.values.count < 2) {
        return;
    }
    double lo = INFINITY, hi = -INFINITY;
    for (NSNumber *n in self.values) {
        lo = MIN(lo, n.doubleValue);
        hi = MAX(hi, n.doubleValue);
    }
    if (hi - lo < 1) { // a flat line in the middle
        double mid = (hi + lo) / 2;
        lo = mid - 0.5;
        hi = mid + 0.5;
    }
    NSColor *color = self.color ?: NSColor.controlAccentColor;
    NSBezierPath *line = [NSBezierPath bezierPath];
    NSBezierPath *area = [NSBezierPath bezierPath];
    NSUInteger count = self.values.count;
    for (NSUInteger i = 0; i < count; ++i) {
        CGFloat x = r.origin.x + r.size.width * i / (count - 1);
        CGFloat y = r.origin.y
                  + r.size.height * ([self.values[i] doubleValue] - lo) / (hi - lo);
        if (i == 0) {
            [line moveToPoint:NSMakePoint(x, y)];
            [area moveToPoint:NSMakePoint(x, r.origin.y)];
            [area lineToPoint:NSMakePoint(x, y)];
        } else {
            [line lineToPoint:NSMakePoint(x, y)];
            [area lineToPoint:NSMakePoint(x, y)];
        }
    }
    [area lineToPoint:NSMakePoint(r.origin.x + r.size.width, r.origin.y)];
    [area closePath];
    [[color colorWithAlphaComponent:0.18] setFill];
    [area fill];
    [color setStroke];
    line.lineWidth = 1.5;
    line.lineJoinStyle = NSLineJoinStyleRound;
    [line stroke];
}

@end

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

#pragma mark - Device menu (adb over Wi-Fi)

static NSString *const kLastWifiAddressKey = @"scrcpy.lastWifiAddress";
static const uint16_t kDefaultTcpipPort = 5555;

- (BOOL)isWifiSerial {
    return [self.serial containsString:@":"]
        || [self.serial containsString:@"_adb-tls-connect"];
}

static NSString *
trimmed(NSString *s) {
    return [s stringByTrimmingCharactersInSet:
               NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Add the default port if the user typed only an IP address
static NSString *
normalized_address(NSString *input) {
    NSString *addr = trimmed(input);
    if (!addr.length) {
        return nil;
    }
    if (![addr containsString:@":"]) {
        addr = [NSString stringWithFormat:@"%@:%u", addr, kDefaultTcpipPort];
    }
    return addr;
}

// Devices advertised on the network (mDNS). The connect list holds the devices
// with Wireless debugging enabled; the pairing list those showing a pairing
// code.
- (void)discoverDevices:(void (^)(NSArray<NSString *> *connect,
                                  NSArray<NSString *> *pairing))done {
    [self runAdb:@[@"mdns", @"services"]
        useSerial:NO
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        NSMutableArray *connect = [NSMutableArray array];
        NSMutableArray *pairing = [NSMutableArray array];
        for (NSString *line in [out componentsSeparatedByCharactersInSet:
                                    NSCharacterSet.newlineCharacterSet]) {
            // "<name> <type> <ip:port>", separated by tabs or spaces
            NSArray *f = [trimmed(line) componentsSeparatedByCharactersInSet:
                             NSCharacterSet.whitespaceCharacterSet];
            f = [f filteredArrayUsingPredicate:
                    [NSPredicate predicateWithFormat:@"length > 0"]];
            if (f.count < 3) {
                continue;
            }
            NSString *type = f[f.count - 2];
            NSString *address = f.lastObject;
            if ([type containsString:@"_adb-tls-connect"]) {
                [connect addObject:address];
            } else if ([type containsString:@"_adb-tls-pairing"]) {
                [pairing addObject:address];
            }
        }
        done(connect, pairing);
    }];
}

// In the app bundle, new sessions go through the launcher script, which applies
// the stream quality for the device (Wi-Fi or USB). Otherwise, the binary.
- (NSString *)launcherPath {
    NSString *launcher = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Contents/MacOS/scrcpy"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:launcher]) {
        return launcher;
    }
    return NSBundle.mainBundle.executablePath;
}

// Start another scrcpy session for the given device
- (void)launchSessionFor:(NSString *)serial {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:[self launcherPath]];
    task.arguments = @[@"-s", serial];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self flash:[NSString stringWithFormat:@"Could not open a session: %@",
                        error.localizedDescription]];
    }
}

- (void)quitCurrentSession {
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_QUIT;
    SDL_PushEvent(&event);
}

// adb connect, then open a session for the device on success
- (void)connectToAddress:(NSString *)input
              completion:(void (^)(BOOL ok))completion {
    NSString *addr = normalized_address(input);
    if (!addr) {
        return;
    }
    [self flash:[NSString stringWithFormat:@"Connecting to %@…", addr]];
    [self runAdb:@[@"connect", addr]
        useSerial:NO
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        // adb connect exits with 0 even when the connection fails
        BOOL ok = [out containsString:@"connected to"];
        if (ok) {
            [[NSUserDefaults standardUserDefaults]
                setObject:addr forKey:kLastWifiAddressKey];
            [self flash:[NSString stringWithFormat:@"Connected to %@", addr]];
            if ([addr isEqualToString:self.serial]) {
                // Already mirroring this device
            } else {
                [self launchSessionFor:addr];
            }
        } else {
            NSString *reason = trimmed(out.length ? out : err);
            [self flash:[NSString stringWithFormat:@"Could not connect: %@",
                            reason]];
        }
        if (completion) {
            completion(ok);
        }
    }];
}

- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    return label;
}

// Sheet with a checkbox per device and a field for another address. The
// handler receives the checked rows and the typed address (may be empty).
- (void)showDevicePickerWithTitle:(NSString *)title
                          message:(NSString *)message
                             rows:(NSArray<NSDictionary *> *)rows
                       confirmTitle:(NSString *)confirmTitle
                          handler:(void (^)(NSArray<NSDictionary *> *selected,
                                            NSString *manual))handler {
    const CGFloat width = 380;
    const CGFloat row_height = 24;
    CGFloat list_height = rows.count * row_height;
    CGFloat total = list_height + (rows.count ? 14 : 0) + 50;

    NSView *accessory =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, total)];
    NSMutableArray<NSButton *> *boxes = [NSMutableArray array];
    for (NSUInteger i = 0; i < rows.count; ++i) {
        NSButton *box = [NSButton checkboxWithTitle:rows[i][@"title"]
                                             target:nil
                                             action:nil];
        box.frame = NSMakeRect(0, total - (i + 1) * row_height,
                               width, row_height);
        // Devices ready to open are checked by default
        box.state = rows[i][@"checked"] ? NSControlStateValueOn
                                        : NSControlStateValueOff;
        [accessory addSubview:box];
        [boxes addObject:box];
    }

    NSTextField *manual =
        [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, width, 24)];
    manual.placeholderString = @"192.168.1.20 or 192.168.1.20:5555";
    [accessory addSubview:manual];
    [accessory addSubview:[self labelWithText:@"Other device (IP address):"
                                        frame:NSMakeRect(0, 28, width, 18)]];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:confirmTitle];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            return;
        }
        NSMutableArray *selected = [NSMutableArray array];
        for (NSUInteger i = 0; i < boxes.count; ++i) {
            if (boxes[i].state == NSControlStateValueOn) {
                [selected addObject:rows[i]];
            }
        }
        handler(selected, trimmed(manual.stringValue));
    }];
}

// Serials of the sessions already open (the other processes are found by the
// "-s <serial>" argument that the launcher always passes)
- (NSSet<NSString *> *)openSerials {
    NSMutableSet *serials = [NSMutableSet set];
    if (self.serial) {
        [serials addObject:self.serial];
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
    task.arguments = @[@"-axww", @"-o", @"args="];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) {
        return serials;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *out = [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"(?:\\s-s\\s+|--serial=)(\\S+)"
                             options:0
                               error:nil];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if (![line containsString:@"/scrcpy-bin"]) {
            continue;
        }
        NSTextCheckingResult *m =
            [re firstMatchInString:line
                           options:0
                             range:NSMakeRange(0, line.length)];
        if (m) {
            [serials addObject:[line substringWithRange:[m rangeAtIndex:1]]];
        }
    }
    return serials;
}

// Devices known by adb (USB and Wi-Fi), as {serial, model}
- (void)listConnectedDevices:(void (^)(NSArray<NSDictionary *> *))done {
    [self runAdb:@[@"devices", @"-l"]
        useSerial:NO
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        NSMutableArray *devices = [NSMutableArray array];
        for (NSString *line in [out componentsSeparatedByCharactersInSet:
                                    NSCharacterSet.newlineCharacterSet]) {
            NSArray *f = [trimmed(line) componentsSeparatedByCharactersInSet:
                             NSCharacterSet.whitespaceCharacterSet];
            f = [f filteredArrayUsingPredicate:
                    [NSPredicate predicateWithFormat:@"length > 0"]];
            if (f.count < 2 || ![f[1] isEqualToString:@"device"]) {
                continue;
            }
            NSString *model = @"";
            for (NSString *token in f) {
                if ([token hasPrefix:@"model:"]) {
                    model = [[token substringFromIndex:6]
                        stringByReplacingOccurrencesOfString:@"_"
                                                  withString:@" "];
                }
            }
            [devices addObject:@{@"serial": f[0], @"model": model}];
        }
        done(devices);
    }];
}

// Open the selected rows: connected devices get a window, devices only seen
// on the network are connected first
- (void)openRows:(NSArray<NSDictionary *> *)rows manual:(NSString *)manual {
    for (NSDictionary *row in rows) {
        if (row[@"serial"]) {
            [self launchSessionFor:row[@"serial"]];
        } else if (row[@"address"]) {
            [self connectToAddress:row[@"address"] completion:nil];
        }
    }
    if (manual.length) {
        [self connectToAddress:manual completion:nil];
    }
}

- (void)openAnotherDevice:(id)sender {
    [self flash:@"Looking for devices…"];
    [self listConnectedDevices:^(NSArray<NSDictionary *> *devices) {
        [self discoverDevices:^(NSArray *connect, NSArray *pairing) {
            NSSet *open = [self openSerials];
            NSMutableArray *rows = [NSMutableArray array];
            NSMutableString *known = [NSMutableString string];
            for (NSDictionary *d in devices) {
                NSString *serial = d[@"serial"];
                [known appendString:serial];
                if ([open containsObject:serial]) {
                    continue;
                }
                BOOL wifi = [serial containsString:@":"]
                         || [serial containsString:@"_adb-tls"];
                NSString *name = [d[@"model"] length] ? d[@"model"]
                                                       : @"Android device";
                [rows addObject:@{
                    @"title": [NSString stringWithFormat:@"%@ — %@ (%@)", name,
                                  serial, wifi ? @"Wi-Fi" : @"USB"],
                    @"serial": serial,
                    @"checked": @YES,
                }];
            }
            for (NSString *address in connect) {
                if ([known containsString:address]) {
                    continue;
                }
                [rows addObject:@{
                    @"title": [NSString stringWithFormat:
                                  @"%@ (found on the network)", address],
                    @"address": address,
                }];
            }
            [self showDevicePickerWithTitle:@"Open Another Device"
                                    message:rows.count
                ? @"Pick the devices to open, each one in its own window."
                : @"Every connected device is already open. Type an IP "
                  @"address to connect another one."
                                       rows:rows
                               confirmTitle:@"Open"
                                    handler:^(NSArray *selected,
                                              NSString *manual) {
                [self openRows:selected manual:manual];
            }];
        }];
    }];
}

- (void)connectWifi:(id)sender {
    [self flash:@"Looking for devices on the network…"];
    [self discoverDevices:^(NSArray *connect, NSArray *pairing) {
        NSMutableArray *rows = [NSMutableArray array];
        for (NSString *address in connect) {
            [rows addObject:@{
                @"title": address,
                @"address": address,
                @"checked": @YES,
            }];
        }
        [self showDevicePickerWithTitle:@"Connect via Wi-Fi"
                                message:rows.count
            ? @"Devices found on the network. Check the ones to connect."
            : @"No device found automatically. Type its IP address (Settings "
              @"→ Developer options → Wireless debugging). If it was never "
              @"paired, use Device → Pair Device…."
                                   rows:rows
                           confirmTitle:@"Connect"
                                handler:^(NSArray *selected, NSString *manual) {
            [self openRows:selected manual:manual];
        }];
    }];
}

- (void)pairDevice:(id)sender {
    [self discoverDevices:^(NSArray *connect, NSArray *pairing) {
        NSComboBox *address = [[NSComboBox alloc]
            initWithFrame:NSMakeRect(0, 52, 340, 26)];
        [address addItemsWithObjectValues:pairing];
        address.stringValue = pairing.firstObject ?: @"";
        address.placeholderString = @"192.168.1.20:37215";
        NSTextField *code =
            [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 340, 24)];
        code.placeholderString = @"123456";

        NSView *accessory =
            [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 100)];
        [accessory addSubview:address];
        [accessory addSubview:[self labelWithText:@"Pairing address:"
                                            frame:NSMakeRect(0, 80, 340, 18)]];
        [accessory addSubview:code];
        [accessory addSubview:[self labelWithText:@"Pairing code:"
                                            frame:NSMakeRect(0, 26, 340, 18)]];

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Pair Device";
        alert.informativeText =
            @"On the device: Developer options → Wireless debugging → Pair "
            @"device with pairing code. Enter the address and code shown.";
        alert.accessoryView = accessory;
        [alert addButtonWithTitle:@"Pair"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert beginSheetModalForWindow:self.window
                      completionHandler:^(NSModalResponse response) {
            if (response != NSAlertFirstButtonReturn) {
                return;
            }
            NSString *addr = trimmed(address.stringValue);
            NSString *pin = trimmed(code.stringValue);
            if (!addr.length || !pin.length) {
                return;
            }
            [self runAdb:@[@"pair", addr, pin]
                useSerial:NO
                stdoutFile:nil
                      done:^(int status, NSString *out, NSString *err) {
                if ([out containsString:@"Successfully paired"]) {
                    [self flash:@"Paired. Now connect to the device."];
                    [self connectWifi:nil];
                } else {
                    [self flash:[NSString stringWithFormat:@"Pairing failed: %@",
                                    trimmed(out.length ? out : err)]];
                }
            }];
        }];
    }];
}

// Move the current (USB) device to Wi-Fi so that the cable can be unplugged
- (void)switchToWifi:(id)sender {
    if ([self isWifiSerial]) {
        [self flash:@"Already connected over Wi-Fi"];
        return;
    }

    [self flash:@"Switching to Wi-Fi…"];
    [self runAdb:@[@"shell", @"ip -f inet addr show wlan0"]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"inet (\\d+\\.\\d+\\.\\d+\\.\\d+)/"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *m =
            [re firstMatchInString:out
                           options:0
                             range:NSMakeRange(0, out.length)];
        if (status != 0 || !m) {
            [self flash:@"The device is not connected to a Wi-Fi network"];
            return;
        }
        NSString *address = [NSString stringWithFormat:@"%@:%u",
            [out substringWithRange:[m rangeAtIndex:1]], kDefaultTcpipPort];

        // Restarting adbd in TCP mode drops the USB connection, which ends
        // this session (and this process). The rest of the switch is thus
        // done by a detached helper that outlives it.
        static NSString *const script =
            @"adb=\"$1\"; serial=\"$2\"; addr=\"$3\"; exe=\"$4\"; port=\"$5\"\n"
            @"if [ -n \"$serial\" ]; then\n"
            @"    \"$adb\" -s \"$serial\" tcpip \"$port\" >/dev/null 2>&1\n"
            @"else\n"
            @"    \"$adb\" tcpip \"$port\" >/dev/null 2>&1\n"
            @"fi\n"
            @"for i in 1 2 3 4 5 6 7 8 9 10 11 12; do\n"
            @"    sleep 1\n"
            @"    out=$(\"$adb\" connect \"$addr\" 2>&1)\n"
            @"    case \"$out\" in\n"
            @"        *\"connected to\"*)\n"
            @"            exec \"$exe\" -s \"$addr\" >/dev/null 2>&1 ;;\n"
            @"    esac\n"
            @"done\n"
            @"osascript -e 'display dialog \"Could not connect to '\"$addr\"'"
            @" over Wi-Fi. The device and this Mac must be on the same network.\""
            @" buttons {\"OK\"} default button \"OK\" with icon caution"
            @" with title \"scrcpy\"' >/dev/null 2>&1\n";

        NSTask *helper = [[NSTask alloc] init];
        helper.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
        helper.arguments = @[@"-c", script, @"sh", self.adb, self.serial ?: @"",
                             address, [self launcherPath],
                             [NSString stringWithFormat:@"%u",
                                 kDefaultTcpipPort]];
        helper.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        helper.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSError *error = nil;
        if (![helper launchAndReturnError:&error]) {
            [self flash:[NSString stringWithFormat:@"Could not switch: %@",
                            error.localizedDescription]];
            return;
        }

        [[NSUserDefaults standardUserDefaults]
            setObject:address forKey:kLastWifiAddressKey];
        [self flash:@"Switching to Wi-Fi… a new window will open"];
    }];
}

- (void)disconnectWifi:(id)sender {
    if (![self isWifiSerial]) {
        return;
    }
    [self runAdb:@[@"disconnect", self.serial]
        useSerial:NO
        stdoutFile:nil
              done:nil];
}

- (void)insertTopMenu:(NSMenu *)menu title:(NSString *)title {
    NSMenu *main = NSApp.mainMenu;
    if (!main) {
        return;
    }
    NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:title
                                                 action:nil
                                          keyEquivalent:@""];
    top.submenu = menu;

    // Before the Window menu
    NSInteger index = main.numberOfItems;
    NSInteger window_index = [main indexOfItemWithSubmenu:NSApp.windowsMenu];
    if (window_index >= 0) {
        index = window_index;
    }
    [main insertItem:top atIndex:index];
}

- (NSMenuItem *)wifiItemWithTitle:(NSString *)title
                           symbol:(NSString *)symbol
                           action:(SEL)action
                              key:(NSString *)key {
    NSMenuItem *item = [self itemWithTitle:title
                                    symbol:symbol
                                    action:action
                                       tag:0];
    if (key.length) {
        item.keyEquivalent = key;
        item.keyEquivalentModifierMask =
            NSEventModifierFlagCommand | NSEventModifierFlagOption;
    }
    return item;
}

// Wi-Fi connection items, shared by the menu bar and the window controls
- (void)addWifiItemsTo:(NSMenu *)menu {
    [menu addItem:[self wifiItemWithTitle:@"Open Another Device…"
                                   symbol:@"iphone.gen3.badge.plus"
                                   action:@selector(openAnotherDevice:)
                                      key:@"n"]];
    [menu addItem:[self wifiItemWithTitle:@"Connect via Wi-Fi…"
                                   symbol:@"wifi"
                                   action:@selector(connectWifi:)
                                      key:@"w"]];
    [menu addItem:[self wifiItemWithTitle:@"Pair Device…"
                                   symbol:@"link"
                                   action:@selector(pairDevice:)
                                      key:@""]];
    [menu addItem:[self wifiItemWithTitle:@"Switch This Device to Wi-Fi"
                                   symbol:@"cable.connector.slash"
                                   action:@selector(switchToWifi:)
                                      key:@""]];
    [menu addItem:[self wifiItemWithTitle:@"Disconnect Wi-Fi Device"
                                   symbol:@"wifi.slash"
                                   action:@selector(disconnectWifi:)
                                      key:@""]];
}

// "Device" menu of the menu bar: everything the window controls do
- (void)installDeviceMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Device"];

    struct {
        __unsafe_unretained NSString *title;
        __unsafe_unretained NSString *symbol;
        NSInteger tag;
    } nav[] = {
        {@"Back", @"arrowtriangle.backward", SC_TOOLBAR_BUTTON_BACK},
        {@"Home", @"circle", SC_TOOLBAR_BUTTON_HOME},
        {@"Recents", @"square", SC_TOOLBAR_BUTTON_APP_SWITCH},
        {@"Notifications", @"bell", SC_TOOLBAR_BUTTON_NOTIFICATIONS},
        {@"Settings Panel", @"gearshape", SC_TOOLBAR_BUTTON_SETTINGS},
    };
    for (size_t i = 0; i < sizeof(nav) / sizeof(nav[0]); ++i) {
        [menu addItem:[self itemWithTitle:nav[i].title
                                   symbol:nav[i].symbol
                                   action:@selector(buttonClicked:)
                                      tag:nav[i].tag]];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self itemWithTitle:@"Rotate Device"
                               symbol:@"rotate.right"
                               action:@selector(rotateItem:)
                                  tag:SC_ROTATE_TOGGLE]];
    [menu addItem:[self itemWithTitle:@"Rotate Device Left"
                               symbol:@"rotate.left"
                               action:@selector(rotateItem:)
                                  tag:SC_ROTATE_LEFT]];
    [menu addItem:[self itemWithTitle:@"Rotate Device Right"
                               symbol:@"rotate.right"
                               action:@selector(rotateItem:)
                                  tag:SC_ROTATE_RIGHT]];
    [menu addItem:[self itemWithTitle:@"Toggle Auto-Rotate"
                               symbol:@"lock.rotation"
                               action:@selector(toggleAutoRotate:)
                                  tag:0]];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self itemWithTitle:@"Volume Up"
                               symbol:@"speaker.plus"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_VOLUME_UP]];
    [menu addItem:[self itemWithTitle:@"Volume Down"
                               symbol:@"speaker.minus"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_VOLUME_DOWN]];
    [menu addItem:[self itemWithTitle:@"Power"
                               symbol:@"power"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_POWER]];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self itemWithTitle:@"Screenshot"
                               symbol:@"camera"
                               action:@selector(buttonClicked:)
                                  tag:SC_TAG_SCREENSHOT]];
    [menu addItem:[self itemWithTitle:@"Start Recording"
                               symbol:@"record.circle"
                               action:@selector(buttonClicked:)
                                  tag:SC_TAG_RECORD]];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *awake = [self itemWithTitle:@"Keep Device Awake"
                                     symbol:@"sun.max"
                                     action:@selector(toggleKeepAwake:)
                                        tag:0];
    awake.keyEquivalent = @"a";
    awake.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [menu addItem:awake];
    [menu addItem:[self qualityMenuItem]];
    [menu addItem:[self frameRateMenuItem]];
    [menu addItem:[self audioMenuItem]];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self itemWithTitle:@"Turn Device Screen Off"
                               symbol:@"moon.fill"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_SCREEN_OFF]];
    [menu addItem:[self itemWithTitle:@"Turn Device Screen On"
                               symbol:@"sun.max"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_SCREEN_ON]];
    [menu addItem:[self itemWithTitle:@"Start With Device Screen Off"
                               symbol:@"moon.zzz"
                               action:@selector(toggleScreenOffOnStart:)
                                  tag:0]];
    [menu addItem:[NSMenuItem separatorItem]];

    [self addCopyIdItemsTo:menu];
    [menu addItem:[self deviceInfoMenuItem]];
    [menu addItem:[NSMenuItem separatorItem]];

    [self addFileItemsTo:menu];
    [menu addItem:[NSMenuItem separatorItem]];

    [self addWifiItemsTo:menu];
    [self insertTopMenu:menu title:@"Device"];
}

// "Developer" menu of the menu bar
- (void)installDeveloperMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Developer"];
    [menu addItem:[self itemWithTitle:@"App Manager…"
                               symbol:@"square.grid.2x2"
                               action:@selector(showAppManager:)
                                  tag:0]];
    [menu addItem:[self itemWithTitle:@"Device Info…"
                               symbol:@"gauge"
                               action:@selector(showDeviceInfo:)
                                  tag:0]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self itemWithTitle:@"React Native Developer Menu"
                               symbol:@"ladybug"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_DEV_MENU]];
    [menu addItem:[self itemWithTitle:@"Reload React Native"
                               symbol:@"arrow.clockwise"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_DEV_RELOAD]];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenu *tools = [self buildToolsMenu];
    NSArray *items = tools.itemArray;
    [tools removeAllItems];
    for (NSMenuItem *item in items) {
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [self addSimulationItemsTo:menu];
    [self insertTopMenu:menu title:@"Developer"];
}

#pragma mark - Edit menu (clipboard)

// Text of the Mac clipboard, if any
- (NSString *)macClipboardText {
    return [[NSPasteboard generalPasteboard]
               stringForType:NSPasteboardTypeString];
}

static NSString *
short_text(NSString *text);

static NSString *
preview_text(NSString *text) {
    NSString *line = [[trimmed(text)
        stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "]
        stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    return short_text(line);
}

// Paste the Mac clipboard on the device (it needs a focused text field there)
- (void)pasteToDevice:(id)sender {
    NSString *text = [self macClipboardText];
    if (!trimmed(text ?: @"").length) {
        [self flash:@"The Mac clipboard has no text to paste"];
        return;
    }
    if (self.callback) {
        self.callback(SC_TOOLBAR_BUTTON_PASTE, self.userdata);
    }
    [self flash:[NSString stringWithFormat:@"Pasted on the device: %@",
                    preview_text(text)]];
}

// Type the clipboard as keystrokes (for the fields that don't accept a paste)
- (void)typeClipboard:(id)sender {
    NSString *text = [self macClipboardText];
    if (!trimmed(text ?: @"").length) {
        [self flash:@"The Mac clipboard has no text to type"];
        return;
    }
    if (self.callback) {
        self.callback(SC_TOOLBAR_BUTTON_TYPE_CLIPBOARD, self.userdata);
    }
    [self flash:[NSString stringWithFormat:@"Typed on the device: %@",
                    preview_text(text)]];
}

// Copy the selection of the device to the Mac clipboard. The device answers
// asynchronously: wait for the clipboard to change to confirm it.
- (void)copyFromDevice:(id)sender {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSInteger before = pb.changeCount;
    if (self.callback) {
        self.callback(SC_TOOLBAR_BUTTON_COPY, self.userdata);
    }
    [self waitForClipboardChange:before attempts:12];
}

- (void)waitForClipboardChange:(NSInteger)before attempts:(NSInteger)attempts {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    if (pb.changeCount != before) {
        NSString *text = [self macClipboardText];
        [self flash:text.length
            ? [NSString stringWithFormat:@"Copied from the device: %@",
                  preview_text(text)]
            : @"Copied from the device"];
        return;
    }
    if (attempts <= 0) {
        [self flash:@"Nothing copied: select some text on the device first"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [self waitForClipboardChange:before attempts:attempts - 1];
    });
}

// SDL only creates the application, View and Window menus. Without an Edit
// menu, text fields (URL, pairing code...) cannot use Cmd+V/C/X/A. The standard
// items are disabled when nothing handles them, so the Cmd+C/V shortcuts of
// scrcpy (device clipboard) still reach the SDL view.
- (void)installEditMenu {
    NSMenu *main = NSApp.mainMenu;
    if (!main || [main itemWithTitle:@"Edit"]) {
        return;
    }

    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:)
             keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:)
             keyEquivalent:@"a"];
    [edit addItem:[NSMenuItem separatorItem]];

    NSMenuItem *paste = [[NSMenuItem alloc]
        initWithTitle:@"Paste to Device"
               action:@selector(pasteToDevice:)
        keyEquivalent:@""];
    paste.target = self;
    paste.image = menu_image(@"doc.on.clipboard", @"Paste to Device");
    [edit addItem:paste];

    NSMenuItem *type = [[NSMenuItem alloc]
        initWithTitle:@"Type Clipboard as Keystrokes"
               action:@selector(typeClipboard:)
        keyEquivalent:@""];
    type.target = self;
    type.image = menu_image(@"keyboard", @"Type Clipboard as Keystrokes");
    [edit addItem:type];

    NSMenuItem *copy = [[NSMenuItem alloc]
        initWithTitle:@"Copy from Device"
               action:@selector(copyFromDevice:)
        keyEquivalent:@""];
    copy.target = self;
    copy.image = menu_image(@"doc.on.doc", @"Copy from Device");
    [edit addItem:copy];

    NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:@"Edit"
                                                 action:nil
                                          keyEquivalent:@""];
    top.submenu = edit;
    // After the application menu
    [main insertItem:top atIndex:MIN(1, main.numberOfItems)];
}

// Density of the device (dpi): read once, with adb
int
sc_macos_device_density(void) {
    static int density;
    if (density > 0 || !g_controller) {
        return density;
    }
    NSMutableArray *argv = [NSMutableArray arrayWithObject:g_controller.adb];
    if (g_controller.serial) {
        [argv addObjectsFromArray:@[@"-s", g_controller.serial]];
    }
    [argv addObjectsFromArray:@[@"shell", @"wm density | tail -1"]];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = argv;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) {
        return 0;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *t) {
        dispatch_semaphore_signal(done);
    };
    if (dispatch_semaphore_wait(
            done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) {
        [task terminate];
        return 0;
    }
    NSString *out = [[NSString alloc]
        initWithData:[pipe.fileHandleForReading readDataToEndOfFile]
            encoding:NSUTF8StringEncoding];
    // "Physical density: 420" or "Override density: 320"
    NSArray *parts = [trimmed(out) componentsSeparatedByString:@":"];
    NSInteger value = parts.count ? [parts.lastObject integerValue] : 0;
    density = value >= 80 && value <= 1200 ? (int) value : 0;
    return density;
}

// Points per inch of the display of the window (from the size of the panel)
float
sc_macos_points_per_inch(SDL_Window *window) {
    NSWindow *nswindow = (__bridge NSWindow *)
        SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                               SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    NSScreen *screen = nswindow.screen ?: NSScreen.mainScreen;
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    if (number) {
        CGSize mm = CGDisplayScreenSize((CGDirectDisplayID) number.unsignedIntValue);
        if (mm.width > 50) {
            float ppi = screen.frame.size.width / (mm.width / 25.4f);
            if (ppi >= 50 && ppi <= 400) {
                return ppi;
            }
        }
    }
    return 110.f; // typical external display
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

#pragma mark - Device controls

static NSString *const kKeepAwakeKey = @"scrcpy.keepAwake";
static NSString *const kAwakeStateKey = @"scrcpy.awakeOriginal";
static NSString *const kScreenOffMax = @"2147483647";

// Lock the rotation of the device to the requested orientation. scrcpy's own
// rotation request restores the automatic rotation right away, and the device,
// held upright, rotates back to portrait: here the rotation stays locked.
- (void)rotateDevice:(enum sc_rotate_direction)direction {
    NSString *target = direction == SC_ROTATE_LEFT ? @"left"
                     : direction == SC_ROTATE_RIGHT ? @"right" : @"toggle";
    NSString *cmd = [NSString stringWithFormat:
        @"T=%@; r=$(dumpsys window displays"
        @" | grep -oE 'mCurrentRotation=ROTATION_[0-9]+' | head -1"
        @" | sed 's/.*_//');"
        @" case $r in 90) c=1;; 180) c=2;; 270) c=3;; *) c=0;; esac;"
        @" case $T in"
        @" left) [ $c = 1 ] && n=0 || n=1;;"
        @" right) [ $c = 3 ] && n=0 || n=3;;"
        @" *) case $c in 1|3) n=0;; *) n=1;; esac;; esac;"
        @" settings put system accelerometer_rotation 0;"
        @" settings put system user_rotation $n; echo $n", target];
    [self runShell:cmd
           success:@"Device rotated"
        completion:^(int status, NSString *out, NSString *err) {
        if (status == 0) {
            [self flash:[trimmed(out) isEqualToString:@"0"]
                ? @"Device rotated: portrait"
                : @"Device rotated: landscape"];
        }
    }];
}

- (void)rotateItem:(NSMenuItem *)item {
    [self rotateDevice:(enum sc_rotate_direction) item.tag];
}

- (void)toggleAutoRotate:(id)sender {
    [self runShell:@"[ \"$(settings get system accelerometer_rotation)\" = 1 ]"
                   @" && settings put system accelerometer_rotation 0"
                   @" || settings put system accelerometer_rotation 1"
           success:@"Auto-rotate toggled"
        completion:nil];
}

- (BOOL)keepAwakeEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kKeepAwakeKey];
}

- (NSString *)awakeStateKey {
    return self.serial ?: @"default";
}

- (void)updateAwakeUI {
    BOOL on = [self keepAwakeEnabled];
    NSString *symbol = on ? @"sun.max.fill" : @"sun.max";
    NSImage *image = menu_image(symbol, @"Keep device awake");
    if (image) {
        self.awakeItem.image = image;
    }
    self.awakeItem.toolTip = on ? @"Device stays awake (click to disable)"
                                : @"Keep device awake";
}

// The device stays on (so it never locks) by setting the screen timeout to its
// maximum. The original value is stored to be restored when the app closes.
- (void)applyKeepAwake {
    [self runAdb:@[@"shell", @"settings get system screen_off_timeout"]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        if (status != 0) {
            [self flash:@"Could not keep the device awake"];
            return;
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *state =
            [[defaults dictionaryForKey:kAwakeStateKey] mutableCopy]
                ?: [NSMutableDictionary dictionary];
        if (!state[[self awakeStateKey]]) {
            NSString *current = trimmed(out);
            BOOL numeric = current.length
                && [current rangeOfCharacterFromSet:
                       NSCharacterSet.decimalDigitCharacterSet.invertedSet]
                       .location == NSNotFound;
            state[[self awakeStateKey]] =
                numeric && ![current isEqualToString:kScreenOffMax]
                    ? current : @"60000";
            [defaults setObject:state forKey:kAwakeStateKey];
        }
        [self runShell:[NSString stringWithFormat:
                @"settings put system screen_off_timeout %@", kScreenOffMax]
               success:@"The device will stay awake while scrcpy is open"
            completion:nil];
    }];
}

// Shell command that gives back the original screen timeout (and forgets it),
// or nil if there is nothing to restore
- (NSString *)takeKeepAwakeRestoreCommand {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *state =
        [[defaults dictionaryForKey:kAwakeStateKey] mutableCopy];
    NSString *original = state[[self awakeStateKey]];
    if (!original) {
        return nil;
    }
    [state removeObjectForKey:[self awakeStateKey]];
    [defaults setObject:state forKey:kAwakeStateKey];
    return [NSString stringWithFormat:
        @"settings put system screen_off_timeout %@", original];
}

- (void)restoreKeepAwakeAsync {
    NSString *cmd = [self takeKeepAwakeRestoreCommand];
    if (cmd) {
        [self runAdb:@[@"shell", cmd] stdoutFile:nil done:nil];
    }
}

// Before the app quits: give back the device settings (screen timeout) and wake
// the display if it was turned off from here, so that the device never stays
// dark if the server could not restore it. Waits for adb, but not for long if
// the device does not answer.
- (void)shutdownSync {
    NSMutableArray *commands = [NSMutableArray array];
    NSString *restore = [self takeKeepAwakeRestoreCommand];
    if (restore) {
        [commands addObject:restore];
    }
    if ([self restoreOnQuit]) {
        [commands addObjectsFromArray:[self restoreCommands]];
    }
    [self clearSimulationFlags];
    if (self.screenOffUsed) {
        // Ask the server to power the display on, then do it from adb too: the
        // display must never stay dark after the app is gone
        if (self.callback) {
            self.callback(SC_TOOLBAR_BUTTON_SCREEN_ON, self.userdata);
            usleep(250 * 1000);
        }
        [commands addObject:@"cmd display power-reset 0"];
        [commands addObject:@"input keyevent KEYCODE_WAKEUP"];
        self.screenOffUsed = NO;
    }
    if (!commands.count) {
        return;
    }

    NSMutableArray *argv = [NSMutableArray arrayWithObject:self.adb];
    if (self.serial) {
        [argv addObjectsFromArray:@[@"-s", self.serial]];
    }
    [argv addObjectsFromArray:@[@"shell",
                                [commands componentsJoinedByString:@"; "]]];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = argv;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *t) {
        dispatch_semaphore_signal(done);
    };
    if (![task launchAndReturnError:nil]) {
        return;
    }
    if (dispatch_semaphore_wait(
            done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) {
        [task terminate];
    }
}

- (void)toggleKeepAwake:(id)sender {
    BOOL on = ![self keepAwakeEnabled];
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kKeepAwakeKey];
    [self updateAwakeUI];
    if (on) {
        [self applyKeepAwake];
    } else {
        [self restoreKeepAwakeAsync];
        [self flash:@"The device can lock again"];
    }
}

- (NSMenuItem *)itemWithTitle:(NSString *)title
                       symbol:(NSString *)symbol
                       action:(SEL)action
                          tag:(NSInteger)tag {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:@""];
    item.target = self;
    item.tag = tag;
    item.image = menu_image(symbol, title);
    return item;
}

#pragma mark - Stream quality

static NSString *const kQualityKey = @"scrcpy.quality";

// Keep in sync with the launcher (release/make_macos_app.sh)
static NSString *const kQualityIds[] = {
    @"auto", @"balanced", @"saver", @"high", @"default",
};
static NSString *const kQualityNames[] = {
    @"Auto (tuned for Wi-Fi)",
    @"Wi-Fi Balanced — 6 Mbps, up to 1600 px",
    @"Data Saver — 3 Mbps, 30 fps",
    @"High Quality — 16 Mbps",
    @"scrcpy Default",
};
#define QUALITY_COUNT (sizeof(kQualityIds) / sizeof(kQualityIds[0]))

- (NSString *)currentQuality {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kQualityKey]
        ?: kQualityIds[0];
}

// The video settings are fixed when the session starts: restart it. The new
// session is started by a detached helper once this one has quit, so that the
// device settings restored on quit are not applied over the new session's.
- (void)restartSession {
    [self flash:@"Restarting the stream…"];

    static NSString *const script =
        @"sleep 2; exec \"$1\" ${2:+-s \"$2\"}";
    NSTask *helper = [[NSTask alloc] init];
    helper.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    helper.arguments = @[@"-c", script, @"sh", [self launcherPath],
                         self.serial ?: @""];
    helper.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    helper.standardError = NSFileHandle.fileHandleWithNullDevice;
    if ([helper launchAndReturnError:nil]) {
        [self quitCurrentSession];
    }
}

- (void)selectQuality:(NSMenuItem *)item {
    NSString *quality = kQualityIds[item.tag];
    if ([quality isEqualToString:[self currentQuality]]) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:quality
                                              forKey:kQualityKey];
    [self restartSession];
}

// Maximum frame rate of the stream (the device can't go over its refresh
// rate). "Auto" uses the one of the quality profile.
static NSString *const kFpsKey = @"scrcpy.fps";
static NSString *const kFpsIds[] = {@"auto", @"30", @"45", @"60", @"90", @"120"};
static NSString *const kFpsNames[] = {
    @"Auto (from the quality)", @"30 fps", @"45 fps", @"60 fps", @"90 fps",
    @"120 fps",
};
#define FPS_COUNT (sizeof(kFpsIds) / sizeof(kFpsIds[0]))

- (NSString *)currentFps {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kFpsKey]
        ?: kFpsIds[0];
}

- (void)selectFps:(NSMenuItem *)item {
    NSString *fps = kFpsIds[item.tag];
    if ([fps isEqualToString:[self currentFps]]) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:fps forKey:kFpsKey];
    [self restartSession];
}

- (NSMenuItem *)frameRateMenuItem {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Frame Rate"];
    for (NSUInteger i = 0; i < FPS_COUNT; ++i) {
        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:kFpsNames[i]
                                       action:@selector(selectFps:)
                                keyEquivalent:@""];
        item.target = self;
        item.tag = i;
        [menu addItem:item];
        if (i == 0) {
            [menu addItem:[NSMenuItem separatorItem]];
        }
    }
    NSMenuItem *item = [self itemWithTitle:@"Frame Rate"
                                    symbol:@"speedometer"
                                    action:nil
                                       tag:0];
    item.submenu = menu;
    return item;
}

- (NSMenu *)buildQualityMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Stream Quality"];
    for (NSUInteger i = 0; i < QUALITY_COUNT; ++i) {
        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:kQualityNames[i]
                                       action:@selector(selectQuality:)
                                keyEquivalent:@""];
        item.target = self;
        item.tag = i;
        [menu addItem:item];
        if (i == 0) {
            [menu addItem:[NSMenuItem separatorItem]];
        }
    }
    return menu;
}

- (NSMenuItem *)qualityMenuItem {
    NSMenuItem *item = [self itemWithTitle:@"Stream Quality"
                                    symbol:@"dial.medium"
                                    action:nil
                                       tag:0];
    item.submenu = [self buildQualityMenu];
    return item;
}

#pragma mark - Device info (copied to the Mac clipboard)

// {key, title, shell command (nil: local), format}
static NSArray<NSArray<NSString *> *> *
info_defs(void) {
    static NSArray *defs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defs = @[
            @[@"adb_serial", @"ADB ID (the serial of adb -s)", @"", @""],
            @[@"adb_cmd", @"ADB command (adb -s …)", @"", @""],
            @[@"hw_serial", @"Device ID (hardware serial)", @"getprop ro.serialno", @""],
            @[@"name", @"Name",
              (@"n=$(settings get global device_name);"
               @" [ -z \"$n\" -o \"$n\" = null ] && n=$(getprop ro.product.model);"
               @" echo $n"), @""],
            @[@"model", @"Model", @"getprop ro.product.model", @""],
            @[@"manufacturer", @"Manufacturer",
              @"getprop ro.product.manufacturer", @""],
            @[@"brand", @"Brand", @"getprop ro.product.brand", @""],
            @[@"codename", @"Codename", @"getprop ro.product.device", @""],
            @[@"-", @"", @"", @""],
            @[@"android", @"Android version",
              @"getprop ro.build.version.release", @""],
            @[@"api", @"API level", @"getprop ro.build.version.sdk", @""],
            @[@"patch", @"Security patch",
              @"getprop ro.build.version.security_patch", @""],
            @[@"build", @"Build ID", @"getprop ro.build.id", @""],
            @[@"fingerprint", @"Build fingerprint",
              @"getprop ro.build.fingerprint", @""],
            @[@"kernel", @"Kernel", @"uname -r", @""],
            @[@"abi", @"CPU architecture", @"getprop ro.product.cpu.abi", @""],
            @[@"-", @"", @"", @""],
            @[@"resolution", @"Screen resolution",
              @"wm size | tail -1 | sed 's/.*: //'", @""],
            @[@"density", @"Screen density",
              @"wm density | tail -1 | sed 's/.*: //'", @"dpi"],
            @[@"ram", @"Memory (RAM)",
              @"grep MemTotal /proc/meminfo | tr -s ' ' | cut -d' ' -f2", @"kb"],
            @[@"storage", @"Storage",
              @"df -h /data | tail -1 | tr -s ' ' | cut -d' ' -f2,3,4",
              @"storage"],
            @[@"battery", @"Battery level",
              @"dumpsys battery | sed -n 's/^ *level: //p'", @"percent"],
            @[@"ip", @"Wi-Fi IP address",
              (@"ip -f inet addr show wlan0 | sed -n 's/.*inet \\([0-9.]*\\).*/\\1/p'"
               @" | head -1"), @""],
            @[@"android_id", @"Android ID",
              @"settings get secure android_id", @""],
            @[@"locale", @"Language",
              (@"l=$(getprop persist.sys.locale);"
               @" [ -z \"$l\" ] && l=$(getprop ro.product.locale); echo $l"), @""],
            @[@"timezone", @"Time zone", @"getprop persist.sys.timezone", @""],
        ];
    });
    return defs;
}

static NSString *
format_info(NSString *raw, NSString *format) {
    NSString *v = trimmed(raw);
    if (!v.length || [v isEqualToString:@"null"]) {
        return @"";
    }
    if ([format isEqualToString:@"kb"]) {
        return [NSString stringWithFormat:@"%.1f GB", v.doubleValue / 1048576];
    }
    if ([format isEqualToString:@"percent"]) {
        return [v stringByAppendingString:@"%"];
    }
    if ([format isEqualToString:@"dpi"]) {
        return [v stringByAppendingString:@" dpi"];
    }
    if ([format isEqualToString:@"storage"]) {
        NSArray *p = [v componentsSeparatedByString:@" "];
        if (p.count == 3) {
            return [NSString stringWithFormat:@"%@ total, %@ used, %@ free",
                       p[0], p[1], p[2]];
        }
    }
    return v;
}

- (void)copyToClipboard:(NSString *)text {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
}

static NSString *
short_text(NSString *text) {
    return text.length > 48 ? [[text substringToIndex:45]
                                  stringByAppendingString:@"…"] : text;
}

- (void)copyInfoItem:(NSMenuItem *)item {
    NSString *key = item.representedObject;
    for (NSArray<NSString *> *def in info_defs()) {
        if (![def[0] isEqualToString:key]) {
            continue;
        }
        NSString *title = def[1];
        if ([key isEqualToString:@"adb_serial"]
                || [key isEqualToString:@"adb_cmd"]) {
            if (!self.serial) {
                [self flash:@"The ADB ID is not known"];
                return;
            }
            NSString *text = [key isEqualToString:@"adb_cmd"]
                ? [NSString stringWithFormat:@"adb -s %@", self.serial]
                : self.serial;
            [self copyToClipboard:text];
            [self flash:[NSString stringWithFormat:@"Copied %@: %@", title,
                            short_text(text)]];
            return;
        }
        [self runAdb:@[@"shell", def[2]]
            stdoutFile:nil
                  done:^(int status, NSString *out, NSString *err) {
            NSString *value = status == 0 ? format_info(out, def[3]) : @"";
            if (!value.length) {
                [self flash:[NSString stringWithFormat:
                                @"%@ is not available on this device", title]];
                return;
            }
            [self copyToClipboard:value];
            [self flash:[NSString stringWithFormat:@"Copied %@: %@", title,
                            short_text(value)]];
        }];
        return;
    }
}

// Every value in one adb call, copied as "Title: value" lines
- (void)copyAllInfo:(id)sender {
    NSMutableString *script = [NSMutableString string];
    for (NSArray<NSString *> *def in info_defs()) {
        if ([def[0] isEqualToString:@"-"] || !def[2].length) {
            continue;
        }
        [script appendFormat:@"echo '@@%@'; { %@; } 2>/dev/null;\n", def[0],
            def[2]];
    }
    [self runAdb:@[@"shell", script]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        if (status != 0) {
            [self flash:@"Could not read the device info"];
            return;
        }
        NSMutableDictionary<NSString *, NSMutableString *> *values =
            [NSMutableDictionary dictionary];
        NSMutableString *current = nil;
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"@@"]) {
                current = [NSMutableString string];
                values[[line substringFromIndex:2]] = current;
            } else if (current) {
                [current appendFormat:@"%@\n", line];
            }
        }
        NSMutableArray *lines = [NSMutableArray array];
        for (NSArray<NSString *> *def in info_defs()) {
            NSString *key = def[0];
            if ([key isEqualToString:@"-"]) {
                continue;
            }
            NSString *value = [key isEqualToString:@"adb_serial"]
                ? (self.serial ?: @"")
                : [key isEqualToString:@"adb_cmd"]
                    ? (self.serial ? [@"adb -s " stringByAppendingString:
                                         self.serial] : @"")
                    : format_info(values[key] ?: @"", def[3]);
            if (value.length) {
                [lines addObject:[NSString stringWithFormat:@"%@: %@", def[1],
                                     value]];
            }
        }
        [self copyToClipboard:[lines componentsJoinedByString:@"\n"]];
        [self flash:[NSString stringWithFormat:@"Copied %lu device values",
                        (unsigned long) lines.count]];
    }];
}

- (NSMenuItem *)copyIdItemWithTitle:(NSString *)title
                                key:(NSString *)key
                             symbol:(NSString *)symbol {
    NSMenuItem *item = [self itemWithTitle:title
                                    symbol:symbol
                                    action:@selector(copyInfoItem:)
                                       tag:0];
    item.representedObject = key;
    return item;
}

// Quick access to the two identifiers
// Install APKs and send files (also by dropping them on the window)
- (void)addFileItemsTo:(NSMenu *)menu {
    [menu addItem:[self itemWithTitle:@"Install APK…"
                               symbol:@"square.and.arrow.down"
                               action:@selector(installAPKItem:)
                                  tag:0]];
    [menu addItem:[self itemWithTitle:@"Send Files to Device…"
                               symbol:@"arrow.up.doc"
                               action:@selector(sendFilesItem:)
                                  tag:0]];
    [menu addItem:[self transferFolderMenuItem]];
    [menu addItem:[self itemWithTitle:@"Open Files After Sending"
                               symbol:@"arrow.up.forward.app"
                               action:@selector(toggleOpenAfterSend:)
                                  tag:0]];
    [menu addItem:[self itemWithTitle:@"Grant Permissions When Installing"
                               symbol:@"checkmark.shield"
                               action:@selector(toggleGrantPermissions:)
                                  tag:0]];
}

- (void)addCopyIdItemsTo:(NSMenu *)menu {
    [menu addItem:[self copyIdItemWithTitle:@"Copy Device ID"
                                        key:@"hw_serial"
                                     symbol:@"number"]];
    [menu addItem:[self copyIdItemWithTitle:@"Copy ADB ID"
                                        key:@"adb_serial"
                                     symbol:@"terminal"]];
}

- (NSMenuItem *)deviceInfoMenuItem {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Copy Device Info"];
    for (NSArray<NSString *> *def in info_defs()) {
        if ([def[0] isEqualToString:@"-"]) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }
        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:def[1]
                                       action:@selector(copyInfoItem:)
                                keyEquivalent:@""];
        item.target = self;
        item.representedObject = def[0];
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self itemWithTitle:@"Copy All"
                               symbol:@"doc.on.doc"
                               action:@selector(copyAllInfo:)
                                  tag:0]];

    NSMenuItem *item = [self itemWithTitle:@"Copy Device Info"
                                    symbol:@"info.circle"
                                    action:nil
                                       tag:0];
    item.submenu = menu;
    return item;
}

#pragma mark - Audio output

static NSString *const kAudioKey = @"scrcpy.audio";
// Keep in sync with the launcher (release/make_macos_app.sh)
static NSString *const kAudioIds[] = {@"mac", @"device", @"both"};
static NSString *const kAudioNames[] = {
    @"Play on Mac (default)", @"Play on Device", @"Play on Mac and Device",
};
#define AUDIO_COUNT (sizeof(kAudioIds) / sizeof(kAudioIds[0]))

- (NSString *)currentAudio {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kAudioKey]
        ?: kAudioIds[0];
}

// The audio source is fixed when the session starts
- (void)selectAudio:(NSMenuItem *)item {
    NSString *audio = kAudioIds[item.tag];
    if ([audio isEqualToString:[self currentAudio]]) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:audio forKey:kAudioKey];
    [self restartSession];
}

- (NSMenuItem *)audioMenuItem {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Audio"];
    for (NSUInteger i = 0; i < AUDIO_COUNT; ++i) {
        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:kAudioNames[i]
                                       action:@selector(selectAudio:)
                                keyEquivalent:@""];
        item.target = self;
        item.tag = i;
        [menu addItem:item];
    }
    NSMenuItem *item = [self itemWithTitle:@"Audio Output"
                                    symbol:@"speaker.wave.2"
                                    action:nil
                                       tag:0];
    item.submenu = menu;
    return item;
}

#pragma mark - Device screen off

static NSString *const kScreenOffOnStartKey = @"scrcpy.screenOffOnStart";

- (BOOL)screenOffOnStart {
    return [[NSUserDefaults standardUserDefaults]
                boolForKey:kScreenOffOnStartKey];
}

// The display of the device is off but it stays awake and controllable: the
// clicks of the mirror still reach it. Persistent: the next sessions start so.
- (void)toggleScreenOffOnStart:(id)sender {
    BOOL on = ![self screenOffOnStart];
    [[NSUserDefaults standardUserDefaults] setBool:on
                                            forKey:kScreenOffOnStartKey];
    self.screenOffUsed = on;
    if (self.callback) {
        self.callback(on ? SC_TOOLBAR_BUTTON_SCREEN_OFF
                         : SC_TOOLBAR_BUTTON_SCREEN_ON, self.userdata);
    }
    [self flash:on ? @"Sessions will start with the device screen off"
                   : @"Sessions will start with the device screen on"];
}

#pragma mark - Drag and drop (install APKs, send files)

static NSString *const kTransferFolderKey = @"scrcpy.transferFolder";
static NSString *const kTransferFolders[] = {
    @"Download", @"Documents", @"Pictures", @"Movies", @"Music", @"DCIM",
};
#define TRANSFER_FOLDER_COUNT \
    (sizeof(kTransferFolders) / sizeof(kTransferFolders[0]))

static NSString *
shell_quote(NSString *text) {
    return [NSString stringWithFormat:@"'%@'",
        [text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

- (NSString *)transferFolder {
    NSString *folder = [[NSUserDefaults standardUserDefaults]
                            stringForKey:kTransferFolderKey];
    for (NSUInteger i = 0; i < TRANSFER_FOLDER_COUNT; ++i) {
        if ([kTransferFolders[i] isEqualToString:folder]) {
            return folder;
        }
    }
    return kTransferFolders[0];
}

static NSString *const kOpenAfterSendKey = @"scrcpy.openAfterSend";

// On by default: a file sent to the device is opened there
- (BOOL)openAfterSend {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:kOpenAfterSendKey]
        ? [defaults boolForKey:kOpenAfterSendKey] : YES;
}

- (void)toggleOpenAfterSend:(id)sender {
    BOOL on = ![self openAfterSend];
    [[NSUserDefaults standardUserDefaults] setBool:on
                                            forKey:kOpenAfterSendKey];
    [self flash:on ? @"A file sent to the device will be opened there"
                   : @"Files sent to the device will not be opened"];
}

// MIME type from the extension (the common ones); nil lets Android decide
static NSString *
mime_type_for_extension(NSString *ext) {
    static NSDictionary *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = @{
            @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg",
            @"gif": @"image/gif", @"webp": @"image/webp", @"heic": @"image/heic",
            @"bmp": @"image/bmp", @"svg": @"image/svg+xml",
            @"mp4": @"video/mp4", @"mov": @"video/quicktime",
            @"mkv": @"video/x-matroska", @"webm": @"video/webm",
            @"mp3": @"audio/mpeg", @"m4a": @"audio/mp4", @"wav": @"audio/x-wav",
            @"ogg": @"audio/ogg", @"flac": @"audio/flac",
            @"pdf": @"application/pdf", @"txt": @"text/plain",
            @"md": @"text/plain", @"log": @"text/plain",
            @"json": @"application/json", @"csv": @"text/csv",
            @"html": @"text/html", @"xml": @"text/xml",
            @"zip": @"application/zip",
            @"doc": @"application/msword",
            @"docx": @"application/vnd.openxmlformats-officedocument."
                     @"wordprocessingml.document",
            @"xls": @"application/vnd.ms-excel",
            @"xlsx": @"application/vnd.openxmlformats-officedocument."
                     @"spreadsheetml.sheet",
            @"ppt": @"application/vnd.ms-powerpoint",
            @"pptx": @"application/vnd.openxmlformats-officedocument."
                     @"presentationml.presentation",
        };
    });
    return types[ext.lowercaseString];
}

// Open a file of the device with the app that handles it. The MediaStore URI
// (content://) is preferred: the apps can't always read a plain file:// path
// with the storage restrictions of recent Android versions.
- (void)openOnDevice:(NSString *)remote {
    NSString *name = remote.lastPathComponent;
    NSString *mime = mime_type_for_extension(remote.pathExtension);
    NSString *type_arg = mime ? [@" -t " stringByAppendingString:mime] : @"";
    NSString *file_view = [NSString stringWithFormat:
        @"am start -a android.intent.action.VIEW -d %@%@",
        shell_quote([@"file://" stringByAppendingString:remote]), type_arg];

    NSCharacterSet *unsafe =
        [NSCharacterSet characterSetWithCharactersInString:@"'\"$`\\"];
    NSString *script = file_view;
    if ([remote rangeOfCharacterFromSet:unsafe].location == NSNotFound) {
        NSString *canonical = [remote hasPrefix:@"/sdcard/"]
            ? [@"/storage/emulated/0/" stringByAppendingString:
                  [remote substringFromIndex:8]] : remote;
        // The media scanner is asynchronous: wait for the file to be indexed
        script = [NSString stringWithFormat:
            @"for i in 1 2 3 4 5 6; do"
            @" id=$(content query --uri content://media/external/file"
            @" --projection _id --where \"_data='%@'\" 2>/dev/null"
            @" | sed -n 's/.*_id=\\([0-9]*\\).*/\\1/p' | head -1);"
            @" [ -n \"$id\" ] && break; sleep 0.4; done;"
            @" if [ -n \"$id\" ]; then"
            @" am start -a android.intent.action.VIEW"
            @" -d content://media/external/file/$id%@"
            @" --grant-read-uri-permission; else %@; fi",
            canonical, type_arg, file_view];
    }

    [self runAdb:@[@"shell", script]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        if (status == 0 && ![out containsString:@"Error"]) {
            [self flash:[NSString stringWithFormat:@"Opened %@ on the device",
                            name]];
        } else {
            [self flash:[NSString stringWithFormat:
                            @"No app on the device can open %@", name]];
        }
    }];
}

static NSString *const kGrantPermissionsKey = @"scrcpy.grantPermissions";

- (BOOL)grantPermissions {
    return [[NSUserDefaults standardUserDefaults]
                boolForKey:kGrantPermissionsKey];
}

// Off by default: an APK dropped on the window does not get every permission
- (void)toggleGrantPermissions:(id)sender {
    BOOL on = ![self grantPermissions];
    [[NSUserDefaults standardUserDefaults] setBool:on
                                            forKey:kGrantPermissionsKey];
    [self flash:on ? @"Installed apps will get all their permissions"
                   : @"Installed apps will ask for their permissions"];
}

- (void)selectTransferFolder:(NSMenuItem *)item {
    [[NSUserDefaults standardUserDefaults]
        setObject:kTransferFolders[item.tag] forKey:kTransferFolderKey];
    [self flash:[NSString stringWithFormat:@"Files will be sent to /sdcard/%@",
                    kTransferFolders[item.tag]]];
}

- (NSMenuItem *)transferFolderMenuItem {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Transfer Folder"];
    for (NSUInteger i = 0; i < TRANSFER_FOLDER_COUNT; ++i) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"/sdcard/%@",
                              kTransferFolders[i]]
                   action:@selector(selectTransferFolder:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = i;
        [menu addItem:item];
    }
    NSMenuItem *item = [self itemWithTitle:@"Transfer Folder"
                                    symbol:@"folder"
                                    action:nil
                                       tag:0];
    item.submenu = menu;
    return item;
}

// Show a status that stays until the next message (no timeout)
- (void)showProgress:(NSString *)message {
    if (@available(macOS 11.0, *)) {
        ++self.subtitleToken; // keeps the previous messages from clearing it
        self.window.subtitle = message;
    }
}

// Drop target shown while a file is dragged over the window
- (void)setDropHover:(BOOL)on {
    self.dropLabel.stringValue = [NSString stringWithFormat:
        @"Drop to install APKs\nor send files to /sdcard/%@",
        [self transferFolder]];
    self.dropOverlay.hidden = !on;
}

// Files may arrive one by one: wait a moment to take them as one batch
- (void)dropFile:(NSString *)path {
    if (!self.dropQueue) {
        self.dropQueue = [NSMutableArray array];
    }
    [self.dropQueue addObject:path];
    NSUInteger token = ++self.dropToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (token == self.dropToken && !self.dropBusy) {
            [self startDropBatch];
        }
    });
}

- (void)startDropBatch {
    if (!self.dropQueue.count) {
        return;
    }
    self.dropBusy = YES;
    self.dropTotal = self.dropQueue.count;
    self.dropIndex = 0;
    self.dropInstalled = 0;
    self.dropSent = 0;
    self.dropFailures = [NSMutableArray array];
    self.dropDowngrades = [NSMutableArray array];
    self.dropSentFiles = [NSMutableArray array];
    [self processNextDrop];
}

// Install reason: "Failure [INSTALL_FAILED_...]"
static NSString *
install_failure_reason(NSString *out, NSString *err) {
    NSString *text = [out stringByAppendingString:err];
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"Failure \\[([^\\]]+)\\]"
                             options:0
                               error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:text
                                             options:0
                                               range:NSMakeRange(0, text.length)];
    if (m) {
        // "INSTALL_FAILED_X: details" -> "INSTALL_FAILED_X"
        return [[[text substringWithRange:[m rangeAtIndex:1]]
            componentsSeparatedByString:@":"] firstObject];
    }
    NSString *line = trimmed(text.length ? text : @"unknown error");
    return [[line componentsSeparatedByString:@"\n"] lastObject];
}

- (void)finishDropFile:(NSString *)name
                  kind:(NSString *)kind
                    ok:(BOOL)ok
                reason:(NSString *)reason
                  path:(NSString *)path {
    if (ok) {
        if ([kind isEqualToString:@"install"]) {
            self.dropInstalled++;
        } else {
            self.dropSent++;
        }
    } else {
        [self.dropFailures addObject:[NSString stringWithFormat:@"%@: %@",
                                         name, reason]];
        if ([reason containsString:@"VERSION_DOWNGRADE"]) {
            [self.dropDowngrades addObject:path];
        }
    }
    [self processNextDrop];
}

- (void)processNextDrop {
    if (!self.dropQueue.count) {
        [self finishDropBatch];
        return;
    }
    NSString *path = self.dropQueue.firstObject;
    [self.dropQueue removeObjectAtIndex:0];
    self.dropIndex++;

    NSString *name = path.lastPathComponent;
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *counter = self.dropTotal > 1
        ? [NSString stringWithFormat:@" (%lu/%lu)", (unsigned long) self.dropIndex,
              (unsigned long) self.dropTotal] : @"";

    if ([ext isEqualToString:@"apk"]) {
        [self showProgress:[NSString stringWithFormat:@"Installing %@%@…", name,
                               counter]];
        [self installAPKs:@[path] extraFlags:@[] name:name path:path];
    } else if ([ext isEqualToString:@"apks"] || [ext isEqualToString:@"xapk"]) {
        [self showProgress:[NSString stringWithFormat:@"Installing %@%@…", name,
                               counter]];
        [self installBundle:path];
    } else {
        [self showProgress:[NSString stringWithFormat:@"Sending %@%@…", name,
                               counter]];
        [self sendFile:path];
    }
}

- (void)installAPKs:(NSArray<NSString *> *)apks
         extraFlags:(NSArray<NSString *> *)flags
               name:(NSString *)name
               path:(NSString *)path {
    NSMutableArray *args = [NSMutableArray arrayWithObject:
        apks.count > 1 ? @"install-multiple" : @"install"];
    [args addObjectsFromArray:@[@"-r", @"-t"]];
    if ([self grantPermissions]) {
        [args addObject:@"-g"];
    }
    if (self.dropDowngradeMode) {
        [args addObject:@"-d"];
    }
    [args addObjectsFromArray:flags];
    [args addObjectsFromArray:apks];
    [self runAdb:args
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        BOOL ok = status == 0 && [out containsString:@"Success"];
        [self finishDropFile:name
                        kind:@"install"
                          ok:ok
                      reason:ok ? @"" : install_failure_reason(out, err)
                        path:path];
    }];
}

// .apks (bundletool) and .xapk are zip files of split APKs
- (void)installBundle:(NSString *)path {
    NSString *name = path.lastPathComponent;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"scrcpy-bundle-" stringByAppendingString:
            [NSUUID UUID].UUIDString]];
    NSTask *unzip = [[NSTask alloc] init];
    unzip.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
    unzip.arguments = @[@"-x", @"-k", path, dir];
    unzip.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![unzip launchAndReturnError:&error]) {
        [self finishDropFile:name kind:@"install" ok:NO
                      reason:@"could not unzip" path:path];
        return;
    }
    [unzip waitUntilExit];

    // The APKs of the bundle: splits/ for .apks, the root for .xapk
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *apks = [NSMutableArray array];
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    for (NSString *relative in [fm enumeratorAtPath:dir]) {
        if (![relative.pathExtension.lowercaseString isEqualToString:@"apk"]) {
            continue;
        }
        NSString *full = [dir stringByAppendingPathComponent:relative];
        [all addObject:full];
        BOOL in_splits = [relative hasPrefix:@"splits/"];
        BOOL in_root = ![relative containsString:@"/"];
        if (in_splits || in_root) {
            [apks addObject:full];
        }
    }
    if (!apks.count) {
        apks = all;
    }
    if (!apks.count) {
        [fm removeItemAtPath:dir error:nil];
        [self finishDropFile:name kind:@"install" ok:NO
                      reason:@"no APK found inside" path:path];
        return;
    }

    NSMutableArray *args = [NSMutableArray arrayWithObject:@"install-multiple"];
    [args addObjectsFromArray:@[@"-r", @"-t"]];
    if ([self grantPermissions]) {
        [args addObject:@"-g"];
    }
    if (self.dropDowngradeMode) {
        [args addObject:@"-d"];
    }
    [args addObjectsFromArray:apks];
    [self runAdb:args
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        BOOL ok = status == 0 && [out containsString:@"Success"];
        if (ok) {
            // .xapk may carry expansion files: Android/obb/<package>/
            NSString *obb = [dir stringByAppendingPathComponent:@"Android/obb"];
            for (NSString *package in [fm contentsOfDirectoryAtPath:obb
                                                              error:nil]) {
                [self runAdb:@[@"push",
                               [obb stringByAppendingPathComponent:package],
                               @"/sdcard/Android/obb/"]
                    stdoutFile:nil
                          done:nil];
            }
        }
        // The OBB push is asynchronous: leave the files for a while
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        });
        [self finishDropFile:name
                        kind:@"install"
                          ok:ok
                      reason:ok ? @"" : install_failure_reason(out, err)
                        path:path];
    }];
}

- (void)sendFile:(NSString *)path {
    NSString *name = path.lastPathComponent;
    NSString *target = [NSString stringWithFormat:@"/sdcard/%@/",
                           [self transferFolder]];
    [self runAdb:@[@"shell", [@"mkdir -p " stringByAppendingString:
                                 shell_quote(target)]]
        stdoutFile:nil
              done:^(int mkdirStatus, NSString *mkOut, NSString *mkErr) {
        [self runAdb:@[@"push", path, target]
            stdoutFile:nil
                  done:^(int status, NSString *out, NSString *err) {
            BOOL ok = status == 0;
            if (ok) {
                // Make it show up in the gallery and the file apps
                NSString *remote = [target stringByAppendingString:name];
                [self runAdb:@[@"shell",
                    [NSString stringWithFormat:
                        @"am broadcast -a "
                        @"android.intent.action.MEDIA_SCANNER_SCAN_FILE -d %@",
                        shell_quote([@"file://" stringByAppendingString:
                                        remote])]]
                    stdoutFile:nil
                          done:nil];
            }
            NSString *reason = trimmed(err.length ? err : out);
            BOOL is_dir = NO;
            [[NSFileManager defaultManager] fileExistsAtPath:path
                                                 isDirectory:&is_dir];
            if (ok && !is_dir) {
                [self.dropSentFiles addObject:@{
                    @"remote": [target stringByAppendingString:name]}];
            }
            [self finishDropFile:name
                            kind:@"send"
                              ok:ok
                          reason:reason
                            path:path];
        }];
    }];
}

- (void)finishDropBatch {
    self.dropBusy = NO;
    self.dropDowngradeMode = NO;
    NSMutableArray *parts = [NSMutableArray array];
    if (self.dropInstalled) {
        [parts addObject:[NSString stringWithFormat:@"installed %lu app%@",
            (unsigned long) self.dropInstalled,
            self.dropInstalled == 1 ? @"" : @"s"]];
    }
    if (self.dropSent) {
        [parts addObject:[NSString stringWithFormat:
            @"sent %lu file%@ to /sdcard/%@", (unsigned long) self.dropSent,
            self.dropSent == 1 ? @"" : @"s", [self transferFolder]]];
    }
    NSString *summary = [parts componentsJoinedByString:@", "];
    NSString *ok_text = summary.length
        ? [[summary substringToIndex:1].uppercaseString
              stringByAppendingString:[summary substringFromIndex:1]]
        : @"";

    // Debug: SCRCPY_TEST_DROP_LOG=<file> gets the result of each batch
    const char *log_path = getenv("SCRCPY_TEST_DROP_LOG");
    if (log_path) {
        NSString *line = [NSString stringWithFormat:@"%@ | failures: %@\n",
            summary.length ? summary : @"nothing",
            [self.dropFailures componentsJoinedByString:@" ; "]];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:@(log_path)];
        if (!h) {
            [[NSFileManager defaultManager] createFileAtPath:@(log_path)
                                                    contents:nil attributes:nil];
            h = [NSFileHandle fileHandleForWritingAtPath:@(log_path)];
        }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
    // A single file sent: open it on the device
    if ([self openAfterSend] && self.dropSentFiles.count == 1
            && !self.dropInstalled && !self.dropFailures.count) {
        [self openOnDevice:self.dropSentFiles.firstObject[@"remote"]];
        return;
    }
    if (!self.dropFailures.count) {
        [self flash:ok_text.length ? ok_text : @"Nothing to do"];
        return;
    }

    [self flash:[NSString stringWithFormat:@"%@%lu failed",
                    ok_text.length ? [ok_text stringByAppendingString:@" · "]
                                   : @"", (unsigned long) self.dropFailures.count]];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Some files could not be transferred";
    alert.informativeText = [self.dropFailures componentsJoinedByString:@"\n"];
    [alert addButtonWithTitle:@"OK"];
    NSArray<NSString *> *downgrades = [self.dropDowngrades copy];
    if (downgrades.count) {
        [alert addButtonWithTitle:@"Install Anyway (downgrade)"];
    }
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response == NSAlertSecondButtonReturn && downgrades.count) {
            [self.dropQueue addObjectsFromArray:downgrades];
            self.dropBusy = YES;
            self.dropTotal = downgrades.count;
            self.dropIndex = 0;
            self.dropInstalled = 0;
            self.dropSent = 0;
            self.dropFailures = [NSMutableArray array];
            self.dropDowngrades = [NSMutableArray array];
            self.dropDowngradeMode = YES;
            [self processNextDrop];
        }
    }];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)chooseFilesFor:(NSArray<NSString *> *)types
                 title:(NSString *)title {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.message = title;
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = !types;
    if (types) {
        panel.allowedFileTypes = types;
    }
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) {
            return;
        }
        if (!self.dropQueue) {
            self.dropQueue = [NSMutableArray array];
        }
        for (NSURL *url in panel.URLs) {
            [self.dropQueue addObject:url.path];
        }
        if (!self.dropBusy) {
            [self startDropBatch];
        }
    }];
}
#pragma clang diagnostic pop

- (void)installAPKItem:(id)sender {
    [self chooseFilesFor:@[@"apk", @"apks", @"xapk"]
                   title:@"Choose the apps to install on the device"];
}

- (void)sendFilesItem:(id)sender {
    [self chooseFilesFor:nil
                   title:[NSString stringWithFormat:
                       @"Choose the files to send to /sdcard/%@",
                       [self transferFolder]]];
}

#pragma mark - Network, display and battery simulation

static NSString *const kRestoreOnQuitKey = @"scrcpy.restoreOnQuit";
static NSString *const kProxyKey = @"scrcpy.proxy";

struct sim_def {
    __unsafe_unretained NSString *identifier;
    __unsafe_unretained NSString *title;
    __unsafe_unretained NSString *symbol;
    __unsafe_unretained NSString *spec; // shortcut, see apply_shortcut()
    __unsafe_unretained NSString *command; // device shell, or "@handler"
    __unsafe_unretained NSString *message;
};

#define SIM(...) {__VA_ARGS__}

static const struct sim_def NETWORK_DEFS[] = {
    SIM(@"proxy_set", @"Set Proxy…", @"network", @"k+s+o+c+p", @"@proxy", @""),
    SIM(@"proxy_clear", @"Clear Proxy", @"network.slash", @"k+s+o+c+x",
        @"settings put global http_proxy :0", @"Proxy cleared"),
    SIM(@"proxy_show", @"Show Current Proxy", @"info.circle", @"k+s+o+c+u",
        @"@proxy_show", @""),
    SIM(@"wifi", @"Toggle Wi-Fi", @"wifi", @"k+s+o+c+w", @"@wifi", @""),
    SIM(@"data", @"Toggle Mobile Data", @"antenna.radiowaves.left.and.right",
        @"k+s+o+c+d",
        @"[ \"$(settings get global mobile_data)\" = 1 ] && svc data disable"
        @" || svc data enable", @"Mobile data toggled"),
    SIM(@"airplane", @"Toggle Airplane Mode", @"airplane", @"k+s+o+c+a",
        @"@airplane", @""),
};

static const struct sim_def SIZE_DEFS[] = {
    SIM(@"size_720", @"720 × 1280 (HD)", @"rectangle.portrait", @"k+s+o+c+q",
        @"wm size 720x1280", @"Screen size: 720 × 1280"),
    SIM(@"size_1080", @"1080 × 1920 (Full HD 16:9)", @"rectangle.portrait",
        @"k+s+o+c+e", @"wm size 1080x1920", @"Screen size: 1080 × 1920"),
    SIM(@"size_2400", @"1080 × 2400 (20:9)", @"rectangle.portrait",
        @"k+s+o+c+t", @"wm size 1080x2400", @"Screen size: 1080 × 2400"),
    SIM(@"size_1440", @"1440 × 3120 (QHD+)", @"rectangle.portrait",
        @"k+s+o+c+y", @"wm size 1440x3120", @"Screen size: 1440 × 3120"),
    SIM(@"size_custom", @"Custom…", @"slider.horizontal.3", @"k+s+o+c+h",
        @"@size_custom", @""),
};

static const struct sim_def DENSITY_DEFS[] = {
    SIM(@"dpi_280", @"280 dpi", @"textformat.size", @"k+s+o+c+7",
        @"wm density 280", @"Density: 280 dpi"),
    SIM(@"dpi_320", @"320 dpi", @"textformat.size", @"k+s+o+c+8",
        @"wm density 320", @"Density: 320 dpi"),
    SIM(@"dpi_420", @"420 dpi", @"textformat.size", @"k+s+o+c+9",
        @"wm density 420", @"Density: 420 dpi"),
    SIM(@"dpi_480", @"480 dpi", @"textformat.size", @"k+s+o+c+0",
        @"wm density 480", @"Density: 480 dpi"),
    SIM(@"dpi_560", @"560 dpi", @"textformat.size", @"k+s+o+c+z",
        @"wm density 560", @"Density: 560 dpi"),
    SIM(@"dpi_custom", @"Custom…", @"slider.horizontal.3", @"k+s+o+c+j",
        @"@density_custom", @""),
};

static const struct sim_def FONT_DEFS[] = {
    SIM(@"font_085", @"Small (0.85×)", @"textformat", @"k+s+o+c+b",
        @"settings put system font_scale 0.85", @"Font size: 0.85×"),
    SIM(@"font_100", @"Default (1.0×)", @"textformat", @"k+s+o+c+c",
        @"settings put system font_scale 1.0", @"Font size: 1.0×"),
    SIM(@"font_115", @"Large (1.15×)", @"textformat", @"k+s+o+c+f",
        @"settings put system font_scale 1.15", @"Font size: 1.15×"),
    SIM(@"font_130", @"Larger (1.3×)", @"textformat", @"k+s+o+c+g",
        @"settings put system font_scale 1.3", @"Font size: 1.3×"),
    SIM(@"font_150", @"Largest (1.5×)", @"textformat", @"k+s+o+c+i",
        @"settings put system font_scale 1.5", @"Font size: 1.5×"),
    SIM(@"font_200", @"Huge (2.0×)", @"textformat", @"k+s+o+c+k",
        @"settings put system font_scale 2.0", @"Font size: 2.0×"),
};

static const struct sim_def BATTERY_DEFS[] = {
    SIM(@"level_100", @"Level 100%", @"battery.100", @"k+s+o+c+l",
        @"dumpsys battery set level 100", @"Battery shown at 100%"),
    SIM(@"level_50", @"Level 50%", @"battery.50", @"k+s+o+c+m",
        @"dumpsys battery set level 50", @"Battery shown at 50%"),
    SIM(@"level_20", @"Level 20% (low)", @"battery.25", @"k+s+o+c+n",
        @"dumpsys battery set level 20", @"Battery shown at 20%"),
    SIM(@"level_5", @"Level 5% (critical)", @"battery.0", @"k+s+o+c+s",
        @"dumpsys battery set level 5", @"Battery shown at 5%"),
    SIM(@"charging", @"Charging", @"battery.100.bolt", @"k+s+o+c+v",
        @"dumpsys battery set ac 1", @"Showing the device as charging"),
    SIM(@"unplug", @"Unplugged", @"battery.100", @"k+s+o+c+o",
        @"dumpsys battery unplug", @"Showing the device as unplugged"),
    SIM(@"saver_on", @"Battery Saver On", @"leaf", @"k+s+o+c+,",
        @"cmd power set-mode 1", @"Battery saver on"),
    SIM(@"saver_off", @"Battery Saver Off", @"leaf", @"k+s+o+c+.",
        @"cmd power set-mode 0", @"Battery saver off"),
    SIM(@"doze_on", @"Enter Doze", @"moon.zzz", @"k+s+o+c+/",
        @"dumpsys deviceidle force-idle", @"Device forced into Doze"),
    SIM(@"doze_off", @"Exit Doze", @"moon.zzz", @"k+s+o+c+;",
        @"dumpsys deviceidle unforce", @"Doze released"),
    SIM(@"battery_reset", @"Reset Battery Simulation", @"arrow.counterclockwise",
        @"k+s+o+c+'", @"@battery_reset", @""),
};

static const struct sim_def *
find_sim_def(NSString *identifier) {
    static const struct {
        const struct sim_def *defs;
        size_t count;
    } groups[] = {
        {NETWORK_DEFS, sizeof(NETWORK_DEFS) / sizeof(NETWORK_DEFS[0])},
        {SIZE_DEFS, sizeof(SIZE_DEFS) / sizeof(SIZE_DEFS[0])},
        {DENSITY_DEFS, sizeof(DENSITY_DEFS) / sizeof(DENSITY_DEFS[0])},
        {FONT_DEFS, sizeof(FONT_DEFS) / sizeof(FONT_DEFS[0])},
        {BATTERY_DEFS, sizeof(BATTERY_DEFS) / sizeof(BATTERY_DEFS[0])},
    };
    for (size_t g = 0; g < sizeof(groups) / sizeof(groups[0]); ++g) {
        for (size_t i = 0; i < groups[g].count; ++i) {
            if ([groups[g].defs[i].identifier isEqualToString:identifier]) {
                return &groups[g].defs[i];
            }
        }
    }
    return NULL;
}

// First private IPv4 address of this Mac (what the device must use as proxy)
static NSString *
mac_lan_ip(void) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) {
        return nil;
    }
    NSString *found = nil;
    for (struct ifaddrs *a = list; a && !found; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET
                || !(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK)
                || strncmp(a->ifa_name, "en", 2) != 0) {
            continue;
        }
        char buf[INET_ADDRSTRLEN];
        struct sockaddr_in *sin = (struct sockaddr_in *) a->ifa_addr;
        inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
        if (strncmp(buf, "169.254.", 8) != 0) {
            found = @(buf);
        }
    }
    freeifaddrs(list);
    return found;
}

- (BOOL)restoreOnQuit {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:kRestoreOnQuitKey]
        ? [defaults boolForKey:kRestoreOnQuitKey] : YES;
}

- (void)toggleRestoreOnQuit:(id)sender {
    BOOL on = ![self restoreOnQuit];
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kRestoreOnQuitKey];
    [self flash:on ? @"Proxy, display and battery changes are undone on quit"
                   : @"Proxy, display and battery changes stay after quitting"];
}

// Commands that give back what this session changed on the device
- (NSArray<NSString *> *)restoreCommands {
    NSMutableArray *commands = [NSMutableArray array];
    if (self.displayOverridden) {
        [commands addObject:@"wm size reset"];
        [commands addObject:@"wm density reset"];
        [commands addObject:[NSString stringWithFormat:
            @"settings put system font_scale %@", self.fontOriginal ?: @"1.0"]];
    }
    if (self.batteryOverridden) {
        [commands addObject:@"dumpsys battery reset"];
        [commands addObject:@"dumpsys deviceidle unforce"];
    }
    if (self.saverOn) {
        [commands addObject:@"cmd power set-mode 0"];
    }
    if (self.proxyOverridden) {
        [commands addObject:@"settings put global http_proxy :0"];
    }
    return commands;
}

- (void)clearSimulationFlags {
    self.displayOverridden = NO;
    self.batteryOverridden = NO;
    self.saverOn = NO;
    self.proxyOverridden = NO;
}

// Ask before an action that would drop the Wi-Fi connection of this session
- (void)confirmDisconnectingThen:(void (^)(void))action {
    if (![self isWifiSerial]) {
        action();
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"This session is connected over Wi-Fi";
    alert.informativeText = @"Turning the Wi-Fi of the device off disconnects "
                            @"this window. Continue?";
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            action();
        }
    }];
}

- (void)askProxy {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *last = [defaults dictionaryForKey:kProxyKey];
    NSString *mac_ip = mac_lan_ip();

    NSTextField *host =
        [[NSTextField alloc] initWithFrame:NSMakeRect(0, 52, 250, 24)];
    host.stringValue = last[@"host"] ?: (mac_ip ?: @"");
    host.placeholderString = @"192.168.1.20";
    NSTextField *port =
        [[NSTextField alloc] initWithFrame:NSMakeRect(262, 52, 78, 24)];
    port.stringValue = last[@"port"] ?: @"8888";
    port.placeholderString = @"8888";

    NSView *accessory =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 100)];
    [accessory addSubview:host];
    [accessory addSubview:port];
    [accessory addSubview:[self labelWithText:@"Host"
                                        frame:NSMakeRect(0, 80, 250, 18)]];
    [accessory addSubview:[self labelWithText:@"Port"
                                        frame:NSMakeRect(262, 80, 78, 18)]];
    [accessory addSubview:[self labelWithText:
        mac_ip ? [NSString stringWithFormat:
                     @"This Mac: %@ (Charles 8888, Proxyman 9090, mitmproxy 8080)",
                     mac_ip]
               : @"Charles 8888, Proxyman 9090, mitmproxy 8080"
                                        frame:NSMakeRect(0, 20, 340, 18)]];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Set HTTP Proxy on the Device";
    alert.informativeText = @"All the HTTP traffic of the device goes through "
                            @"this host, to inspect it on the Mac.";
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:@"Set Proxy"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            return;
        }
        NSString *h = trimmed(host.stringValue);
        NSInteger p = trimmed(port.stringValue).integerValue;
        NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:
                                  @" '\"$`\\;&|<>"];
        if (!h.length || p < 1 || p > 65535
                || [h rangeOfCharacterFromSet:bad].location != NSNotFound) {
            [self flash:@"Invalid proxy: type a host and a port (1–65535)"];
            return;
        }
        [defaults setObject:@{@"host": h,
                              @"port": [NSString stringWithFormat:@"%ld", (long) p]}
                     forKey:kProxyKey];
        self.proxyOverridden = YES;
        [self runShell:[NSString stringWithFormat:
                @"settings put global http_proxy %@:%ld", h, (long) p]
               success:[NSString stringWithFormat:@"Proxy set: %@:%ld", h,
                           (long) p]
            completion:nil];
    }];
}

// One value in a sheet (size "1080x2400", density "420")
- (void)askValue:(NSString *)title
         message:(NSString *)message
     placeholder:(NSString *)placeholder
         handler:(void (^)(NSString *value))handler {
    NSTextField *field =
        [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    field.placeholderString = placeholder;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Apply"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            handler(trimmed(field.stringValue));
        }
    }];
}

- (void)runSimCommand:(NSString *)identifier
              command:(NSString *)command
              message:(NSString *)message {
    if ([identifier hasPrefix:@"size_"] || [identifier hasPrefix:@"dpi_"]
            || [identifier hasPrefix:@"font_"]) {
        self.displayOverridden = YES;
    } else if ([identifier hasPrefix:@"level_"]
            || [identifier isEqualToString:@"charging"]
            || [identifier isEqualToString:@"unplug"]
            || [identifier hasPrefix:@"doze_"]) {
        self.batteryOverridden = YES;
    } else if ([identifier isEqualToString:@"saver_on"]) {
        self.saverOn = YES;
    } else if ([identifier isEqualToString:@"saver_off"]) {
        self.saverOn = NO;
    }
    [self runShell:command success:message completion:nil];
}

- (void)simItem:(NSMenuItem *)item {
    NSString *identifier = item.representedObject;
    const struct sim_def *def = find_sim_def(identifier);
    if (!def) {
        return;
    }
    NSString *command = def->command;

    if ([command isEqualToString:@"@proxy"]) {
        [self askProxy];
    } else if ([command isEqualToString:@"@proxy_show"]) {
        [self runAdb:@[@"shell", @"settings get global http_proxy"]
            stdoutFile:nil
                  done:^(int status, NSString *out, NSString *err) {
            NSString *value = trimmed(out);
            BOOL none = !value.length || [value isEqualToString:@"null"]
                     || [value isEqualToString:@":0"];
            [self flash:none ? @"No proxy set on the device"
                             : [NSString stringWithFormat:@"Proxy: %@", value]];
        }];
    } else if ([command isEqualToString:@"@wifi"]) {
        [self confirmDisconnectingThen:^{
            [self runShell:@"[ \"$(settings get global wifi_on)\" = 1 ]"
                           @" && svc wifi disable || svc wifi enable"
                   success:@"Wi-Fi toggled"
                completion:nil];
        }];
    } else if ([command isEqualToString:@"@airplane"]) {
        [self confirmDisconnectingThen:^{
            [self runShell:@"[ \"$(settings get global airplane_mode_on)\" = 1 ]"
                           @" && cmd connectivity airplane-mode disable"
                           @" || cmd connectivity airplane-mode enable"
                   success:@"Airplane mode toggled"
                completion:nil];
        }];
    } else if ([command isEqualToString:@"@size_custom"]) {
        [self askValue:@"Custom Screen Size"
               message:@"Width × height in pixels, for example 1080x2400. The "
                       @"window follows the new size."
           placeholder:@"1080x2400"
               handler:^(NSString *value) {
            NSArray *p = [[value lowercaseString]
                componentsSeparatedByString:@"x"];
            NSInteger w = p.count == 2 ? [p[0] integerValue] : 0;
            NSInteger h = p.count == 2 ? [p[1] integerValue] : 0;
            if (w < 200 || h < 200 || w > 8000 || h > 8000) {
                [self flash:@"Invalid size: use WIDTHxHEIGHT, like 1080x2400"];
                return;
            }
            [self runSimCommand:@"size_custom"
                        command:[NSString stringWithFormat:@"wm size %ldx%ld",
                                    (long) w, (long) h]
                        message:[NSString stringWithFormat:
                                    @"Screen size: %ld × %ld", (long) w,
                                    (long) h]];
        }];
    } else if ([command isEqualToString:@"@density_custom"]) {
        [self askValue:@"Custom Screen Density"
               message:@"Dots per inch, between 120 and 800 (a Pixel is 420)."
           placeholder:@"420"
               handler:^(NSString *value) {
            NSInteger d = value.integerValue;
            if (d < 120 || d > 800) {
                [self flash:@"Invalid density: use a number from 120 to 800"];
                return;
            }
            [self runSimCommand:@"dpi_custom"
                        command:[NSString stringWithFormat:@"wm density %ld",
                                    (long) d]
                        message:[NSString stringWithFormat:@"Density: %ld dpi",
                                    (long) d]];
        }];
    } else if ([command isEqualToString:@"@battery_reset"]) {
        self.batteryOverridden = NO;
        [self runShell:@"dumpsys battery reset; dumpsys deviceidle unforce"
               success:@"Battery simulation reset"
            completion:nil];
    } else if ([identifier hasPrefix:@"font_"] && !self.fontOriginal) {
        // Remember the real font size before the first change
        [self runAdb:@[@"shell", @"settings get system font_scale"]
            stdoutFile:nil
                  done:^(int status, NSString *out, NSString *err) {
            NSString *value = trimmed(out);
            self.fontOriginal = (value.length && ![value isEqualToString:@"null"])
                ? value : @"1.0";
            [self runSimCommand:identifier command:command
                        message:def->message];
        }];
    } else {
        [self runSimCommand:identifier command:command message:def->message];
    }
}

- (void)resetDisplay:(id)sender {
    NSArray *commands = @[@"wm size reset", @"wm density reset",
        [NSString stringWithFormat:@"settings put system font_scale %@",
            self.fontOriginal ?: @"1.0"]];
    self.displayOverridden = NO;
    [self runShell:[commands componentsJoinedByString:@"; "]
           success:@"Screen size, density and font size reset"
        completion:nil];
}

- (NSMenu *)buildSimMenu:(NSString *)title
                    defs:(const struct sim_def *)defs
                   count:(size_t)count {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    for (size_t i = 0; i < count; ++i) {
        NSMenuItem *item = [self itemWithTitle:defs[i].title
                                        symbol:defs[i].symbol
                                        action:@selector(simItem:)
                                           tag:0];
        item.representedObject = defs[i].identifier;
        apply_shortcut(item, defs[i].spec);
        [menu addItem:item];
    }
    return menu;
}

- (NSMenuItem *)submenuItem:(NSString *)title
                     symbol:(NSString *)symbol
                       menu:(NSMenu *)menu {
    NSMenuItem *item = [self itemWithTitle:title symbol:symbol action:nil tag:0];
    item.submenu = menu;
    return item;
}

#define SIM_MENU(menu_title, table) \
    [self buildSimMenu:menu_title defs:table count:sizeof(table) / sizeof(table[0])]

- (NSMenuItem *)networkMenuItem {
    return [self submenuItem:@"Network" symbol:@"network"
                        menu:SIM_MENU(@"Network", NETWORK_DEFS)];
}

- (NSMenuItem *)displayMenuItem {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Display"];
    [menu addItem:[self submenuItem:@"Screen Size"
                             symbol:@"rectangle.portrait"
                               menu:SIM_MENU(@"Screen Size", SIZE_DEFS)]];
    [menu addItem:[self submenuItem:@"Density"
                             symbol:@"textformat.size"
                               menu:SIM_MENU(@"Density", DENSITY_DEFS)]];
    [menu addItem:[self submenuItem:@"Font Size"
                             symbol:@"textformat"
                               menu:SIM_MENU(@"Font Size", FONT_DEFS)]];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *reset = [self itemWithTitle:@"Reset Size, Density and Font"
                                     symbol:@"arrow.counterclockwise"
                                     action:@selector(resetDisplay:)
                                        tag:0];
    apply_shortcut(reset, @"k+s+o+c+r");
    [menu addItem:reset];
    return [self submenuItem:@"Display" symbol:@"display" menu:menu];
}

- (NSMenuItem *)batteryMenuItem {
    return [self submenuItem:@"Battery and Power" symbol:@"battery.50"
                        menu:SIM_MENU(@"Battery and Power", BATTERY_DEFS)];
}

// The three simulation menus plus the option that undoes them on quit
- (void)addSimulationItemsTo:(NSMenu *)menu {
    [menu addItem:[self networkMenuItem]];
    [menu addItem:[self displayMenuItem]];
    [menu addItem:[self batteryMenuItem]];
    NSMenuItem *restore = [self itemWithTitle:@"Undo These Changes When Closing"
                                       symbol:@"arrow.uturn.backward"
                                       action:@selector(toggleRestoreOnQuit:)
                                          tag:0];
    apply_shortcut(restore, @"k+s+o+c+]");
    [menu addItem:restore];
}

#pragma mark - Tool panels

// The app manager and the device info stay above the simulator window (also if
// it is kept on top), and hide when another app is in front, as the tool
// windows of macOS do.
- (void)configureToolPanel:(NSPanel *)panel {
    panel.floatingPanel = YES;
    panel.hidesOnDeactivate = YES;
    panel.becomesKeyOnlyIfNeeded = NO;
    panel.level = [self toolPanelLevel];
}

- (NSWindowLevel)toolPanelLevel {
    return MAX(NSFloatingWindowLevel, self.window.level + 1);
}

// Call it when the level of the simulator window changes (Keep on Top)
- (void)updateToolPanelLevels {
    for (NSWindow *w in @[self.appWindow ?: [NSNull null],
                          self.infoWindow ?: [NSNull null]]) {
        if ([w isKindOfClass:[NSWindow class]]) {
            w.level = [self toolPanelLevel];
        }
    }
}

#pragma mark - App manager

// {identifier, title, symbol}
static NSArray<NSArray<NSString *> *> *
app_actions(void) {
    static NSArray *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        actions = @[
            @[@"open", @"Open", @"play.circle"],
            @[@"restart", @"Restart", @"arrow.clockwise.circle"],
            @[@"stop", @"Force Stop", @"stop.circle"],
            @[@"cache", @"Clear Cache", @"trash.slash"],
            @[@"data", @"Clear Data…", @"trash"],
            @[@"toggle", @"Disable", @"nosign"],
            @[@"uninstall", @"Uninstall…", @"xmark.bin"],
            @[@"info", @"App Info", @"info.circle"],
            @[@"permissions", @"Permissions…", @"checkmark.shield"],
            @[@"pull", @"Save APK", @"square.and.arrow.down"],
            @[@"copy", @"Copy Package", @"doc.on.doc"],
        ];
    });
    return actions;
}

// Parse "dumpsys package packages" + the list of disabled packages
static NSArray<NSDictionary *> *
parse_packages(NSString *out) {
    NSArray *parts = [out componentsSeparatedByString:@"\n@@DISABLED\n"];
    NSMutableSet *disabled = [NSMutableSet set];
    if (parts.count > 1) {
        for (NSString *line in [parts[1] componentsSeparatedByString:@"\n"]) {
            NSString *l = trimmed(line);
            if ([l hasPrefix:@"package:"]) {
                [disabled addObject:[l substringFromIndex:8]];
            }
        }
    }

    NSRegularExpression *header = [NSRegularExpression
        regularExpressionWithPattern:@"^  Package \\[([^\\]]+)\\]"
                             options:0 error:nil];
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableDictionary *current = nil;
    for (NSString *line in [parts[0] componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *m = [header firstMatchInString:line
                                                     options:0
                                                       range:NSMakeRange(0, line.length)];
        if (m) {
            NSString *package = [line substringWithRange:[m rangeAtIndex:1]];
            if ([seen containsObject:package]) {
                current = nil; // "Hidden system packages" repeats them
                continue;
            }
            [seen addObject:package];
            current = [NSMutableDictionary dictionaryWithDictionary:@{
                @"package": package, @"version": @"", @"updated": @"",
                @"installer": @"", @"system": @NO,
                @"disabled": @([disabled containsObject:package]),
            }];
            [result addObject:current];
            continue;
        }
        if (!current) {
            continue;
        }
        NSString *t = trimmed(line);
        if ([t hasPrefix:@"versionName="]) {
            current[@"version"] = [t substringFromIndex:12];
        } else if ([t hasPrefix:@"lastUpdateTime="]) {
            current[@"updated"] = [t substringFromIndex:15];
        } else if ([t hasPrefix:@"installerPackageName="]) {
            current[@"installer"] = [t substringFromIndex:21];
        } else if (([t hasPrefix:@"flags=["] || [t hasPrefix:@"pkgFlags=["])
                   && [t containsString:@" SYSTEM"]) {
            current[@"system"] = @YES;
        }
    }
    return result;
}

- (NSDictionary *)selectedApp {
    NSInteger row = self.appTable.selectedRow;
    return row >= 0 && row < (NSInteger) self.shownApps.count
        ? self.shownApps[row] : nil;
}

- (void)updateAppStatus {
    NSDictionary *app = [self selectedApp];
    if (self.appsLoading) {
        self.appStatus.stringValue = @"Loading apps…";
    } else if (app) {
        self.appStatus.stringValue = [NSString stringWithFormat:@"%@%@",
            app[@"package"], [app[@"disabled"] boolValue] ? @" — disabled" : @""];
    } else {
        self.appStatus.stringValue = [NSString stringWithFormat:
            @"%lu apps", (unsigned long) self.shownApps.count];
    }
    for (NSButton *b in self.appButtons) {
        b.enabled = app != nil;
        if ([b.identifier isEqualToString:@"toggle"]) {
            b.title = [app[@"disabled"] boolValue] ? @"Enable" : @"Disable";
        }
    }
}

- (void)applyAppFilter {
    NSString *query = trimmed(self.appSearch.stringValue).lowercaseString;
    BOOL system = self.appSystemCheck.state == NSControlStateValueOn;
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *app in self.apps) {
        if (!system && [app[@"system"] boolValue]) {
            continue;
        }
        if (query.length
                && ![[app[@"package"] lowercaseString] containsString:query]) {
            continue;
        }
        [list addObject:app];
    }
    NSArray *descriptors = self.appTable.sortDescriptors;
    if (descriptors.count) {
        [list sortUsingDescriptors:descriptors];
    }
    self.shownApps = list;
    [self.appTable reloadData];
    [self updateAppStatus];
}

- (void)reloadApps {
    self.appsLoading = YES;
    [self updateAppStatus];
    [self runAdb:@[@"shell",
                   (@"dumpsys package packages; echo; echo @@DISABLED;"
                    @" pm list packages -d")]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        self.appsLoading = NO;
        if (status != 0) {
            [self flash:@"Could not read the apps of the device"];
            [self updateAppStatus];
            return;
        }
        // The marker has an empty line before it
        self.apps = parse_packages([out stringByReplacingOccurrencesOfString:
                                       @"\n\n@@DISABLED\n"
                                                                  withString:
                                       @"\n@@DISABLED\n"]);
        [self applyAppFilter];
    }];
}

- (NSButton *)appButton:(NSArray<NSString *> *)def {
    NSButton *b = [NSButton buttonWithTitle:def[1]
                                     target:self
                                     action:@selector(appButtonClicked:)];
    b.identifier = def[0];
    b.bezelStyle = NSBezelStyleRounded;
    NSImage *image = menu_image(def[2], def[1]);
    if (image) {
        b.image = image;
        b.imagePosition = NSImageLeading;
    }
    b.controlSize = NSControlSizeSmall;
    b.enabled = NO;
    return b;
}

- (void)buildAppManagerWindow {
    NSPanel *w = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 880, 540)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                          | NSWindowStyleMaskResizable
                          | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [self configureToolPanel:w];
    w.title = [NSString stringWithFormat:@"App Manager — %@", self.serial ?: @"device"];
    w.releasedWhenClosed = NO;
    w.minSize = NSMakeSize(640, 360);
    [w setFrameAutosaveName:@"scrcpy.appManager"];
    [w center];

    NSSearchField *search = [[NSSearchField alloc] init];
    search.placeholderString = @"Filter by package name";
    search.delegate = self;
    NSButton *system = [NSButton checkboxWithTitle:@"Show system apps"
                                            target:self
                                            action:@selector(appFilterChanged:)];
    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh"
                                           target:self
                                           action:@selector(refreshApps:)];
    refresh.image = menu_image(@"arrow.clockwise", @"Refresh");
    refresh.imagePosition = NSImageLeading;
    NSButton *trim = [NSButton buttonWithTitle:@"Clear All Caches"
                                        target:self
                                        action:@selector(clearAllCaches:)];
    trim.image = menu_image(@"trash.slash", @"Clear All Caches");
    trim.imagePosition = NSImageLeading;
    NSStackView *top = [NSStackView stackViewWithViews:@[search, system, refresh,
                                                         trim]];
    top.spacing = 12;
    [search.widthAnchor constraintGreaterThanOrEqualToConstant:240].active = YES;
    [search setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSTableView *table = [[NSTableView alloc] init];
    table.usesAlternatingRowBackgroundColors = YES;
    table.allowsMultipleSelection = NO;
    table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    table.rowHeight = 22;
    struct {
        __unsafe_unretained NSString *key;
        __unsafe_unretained NSString *title;
        CGFloat width;
    } cols[] = {
        {@"package", @"Package", 330}, {@"version", @"Version", 100},
        {@"type", @"Type", 60}, {@"updated", @"Updated", 140},
        {@"installer", @"Installed by", 200},
    };
    for (size_t i = 0; i < sizeof(cols) / sizeof(cols[0]); ++i) {
        NSTableColumn *c = [[NSTableColumn alloc]
            initWithIdentifier:cols[i].key];
        c.title = cols[i].title;
        c.width = cols[i].width;
        c.minWidth = 50;
        NSString *sort_key = [cols[i].key isEqualToString:@"type"] ? @"system"
                                                                   : cols[i].key;
        c.sortDescriptorPrototype =
            [NSSortDescriptor sortDescriptorWithKey:sort_key ascending:YES];
        [table addTableColumn:c];
    }
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.doubleAction = @selector(appDoubleClicked:);
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;

    NSMutableArray *buttons = [NSMutableArray array];
    for (NSArray<NSString *> *def in app_actions()) {
        [buttons addObject:[self appButton:def]];
    }
    NSStackView *row1 = [NSStackView stackViewWithViews:
        [buttons subarrayWithRange:NSMakeRange(0, 6)]];
    NSStackView *row2 = [NSStackView stackViewWithViews:
        [buttons subarrayWithRange:NSMakeRange(6, buttons.count - 6)]];
    row1.spacing = row2.spacing = 8;
    row1.distribution = row2.distribution = NSStackViewDistributionFill;

    NSTextField *status = [NSTextField labelWithString:@""];
    status.textColor = NSColor.secondaryLabelColor;
    status.lineBreakMode = NSLineBreakByTruncatingMiddle;

    NSStackView *root = [NSStackView stackViewWithViews:
        @[top, scroll, row1, row2, status]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 8;
    root.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [w.contentView addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:w.contentView.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:w.contentView.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:w.contentView.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:w.contentView.bottomAnchor],
        [top.trailingAnchor constraintEqualToAnchor:root.trailingAnchor
                                           constant:-12],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor
                                              constant:-12],
        [status.trailingAnchor constraintEqualToAnchor:root.trailingAnchor
                                              constant:-12],
    ]];
    [scroll setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                       forOrientation:NSLayoutConstraintOrientationVertical];

    self.appWindow = w;
    self.appTable = table;
    self.appSearch = search;
    self.appSystemCheck = system;
    self.appStatus = status;
    self.appButtons = buttons;
    table.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"package"
                                                             ascending:YES]];
}

- (void)showAppManager:(id)sender {
    if (!self.appWindow) {
        [self buildAppManagerWindow];
    }
    [self updateToolPanelLevels];
    [self.appWindow makeKeyAndOrderFront:nil];
    [self reloadApps];
}

- (void)refreshApps:(id)sender {
    [self reloadApps];
}

- (void)appFilterChanged:(id)sender {
    [self applyAppFilter];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self applyAppFilter];
}

- (void)appDoubleClicked:(id)sender {
    NSDictionary *app = [self selectedApp];
    if (app) {
        [self runAppAction:@"open" package:app[@"package"]];
    }
}

- (void)appButtonClicked:(NSButton *)sender {
    NSDictionary *app = [self selectedApp];
    if (!app) {
        return;
    }
    NSString *identifier = sender.identifier;
    if ([identifier isEqualToString:@"toggle"]) {
        identifier = [app[@"disabled"] boolValue] ? @"enable" : @"disable";
    }
    [self runAppAction:identifier package:app[@"package"]];
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.shownApps.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)column
                  row:(NSInteger)row {
    NSTextField *cell = [tableView makeViewWithIdentifier:column.identifier
                                                    owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = column.identifier;
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    NSDictionary *app = self.shownApps[row];
    NSString *value = @"";
    if ([column.identifier isEqualToString:@"type"]) {
        value = [app[@"system"] boolValue] ? @"System" : @"User";
    } else {
        value = app[column.identifier] ?: @"";
    }
    cell.stringValue = value;
    cell.textColor = [app[@"disabled"] boolValue] ? NSColor.secondaryLabelColor
                                                  : NSColor.labelColor;
    return cell;
}

- (void)tableView:(NSTableView *)tableView
    sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    [self applyAppFilter];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateAppStatus];
    NSDictionary *app = [self selectedApp];
    if (!app) {
        return;
    }
    // Is it running?
    NSString *package = app[@"package"];
    [self runAdb:@[@"shell", [NSString stringWithFormat:@"pidof %@",
                                 shell_quote(package)]]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        if (![[self selectedApp][@"package"] isEqualToString:package]) {
            return; // another row was selected meanwhile
        }
        NSString *pid = trimmed(out);
        self.appStatus.stringValue = [NSString stringWithFormat:@"%@ — %@",
            package, pid.length ? [@"running (pid " stringByAppendingFormat:
                                      @"%@)", pid] : @"not running"];
    }];
}

#pragma mark Actions

- (void)confirm:(NSString *)message
         detail:(NSString *)detail
         action:(NSString *)button
        handler:(void (^)(void))handler {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = message;
    alert.informativeText = detail;
    [alert addButtonWithTitle:button];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.appWindow ?: self.window
                  completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            handler();
        }
    }];
}

// Shell command and success message for the actions without a dialog
- (void)runAppShell:(NSString *)command
            success:(NSString *)message
            refresh:(BOOL)refresh {
    [self runAdb:@[@"shell", command]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        NSString *text = trimmed(out.length ? out : err);
        BOOL failed = status != 0 || [text containsString:@"Failure"]
                   || [text hasPrefix:@"Error"];
        [self flash:failed ? [NSString stringWithFormat:@"Failed: %@", text]
                           : message];
        if (refresh && !failed) {
            [self reloadApps];
        }
    }];
}

- (void)openApp:(NSString *)package then:(void (^)(void))then {
    [self runAdb:@[@"shell", [NSString stringWithFormat:
                                 @"cmd package resolve-activity --brief %@ | tail -1",
                                 shell_quote(package)]]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        NSString *component = trimmed(out);
        NSString *command = [component containsString:@"/"]
            ? [NSString stringWithFormat:@"am start -n %@", shell_quote(component)]
            : [NSString stringWithFormat:
                  @"monkey -p %@ -c android.intent.category.LAUNCHER 1",
                  shell_quote(package)];
        [self runAdb:@[@"shell", command]
            stdoutFile:nil
                  done:^(int s2, NSString *o2, NSString *e2) {
            BOOL ok = s2 == 0 && ![o2 containsString:@"Error"]
                   && ![o2 containsString:@"No activities"];
            [self flash:ok ? [NSString stringWithFormat:@"Opened %@", package]
                           : [NSString stringWithFormat:
                                 @"%@ has no screen to open", package]];
            if (then) {
                then();
            }
        }];
    }];
}

- (void)showPermissionsOf:(NSString *)package {
    [self runAdb:@[@"shell", [NSString stringWithFormat:
        @"dumpsys package %@ | grep -E 'permission[.].*granted='"
        @" | sed 's/^ *//; s/, flags=.*//'", shell_quote(package)]]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        NSMutableString *text = [NSMutableString string];
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSString *l = trimmed(line);
            if (!l.length) {
                continue;
            }
            BOOL granted = [l containsString:@"granted=true"];
            NSString *name = [[l componentsSeparatedByString:@":"] firstObject];
            [text appendFormat:@"%@ %@\n", granted ? @"✓" : @"✗", name];
        }
        if (!text.length) {
            [text appendString:@"No runtime permissions."];
        }
        [self flash:[NSString stringWithFormat:@"%@: %lu permissions", package,
                        (unsigned long) [text componentsSeparatedByString:@"\n"]
                            .count - 1]];
        NSTextView *view = [[NSTextView alloc]
            initWithFrame:NSMakeRect(0, 0, 520, 300)];
        view.editable = NO;
        view.font = [NSFont monospacedSystemFontOfSize:11
                                                weight:NSFontWeightRegular];
        view.string = text;
        NSScrollView *scroll = [[NSScrollView alloc]
            initWithFrame:NSMakeRect(0, 0, 520, 300)];
        scroll.documentView = view;
        scroll.hasVerticalScroller = YES;
        scroll.borderType = NSBezelBorder;

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Permissions";
        alert.informativeText = package;
        alert.accessoryView = scroll;
        [alert addButtonWithTitle:@"Close"];
        [alert beginSheetModalForWindow:self.appWindow ?: self.window
                      completionHandler:nil];
    }];
}

- (void)saveAPKOf:(NSString *)package {
    [self runAdb:@[@"shell", [NSString stringWithFormat:@"pm path %@",
                                 shell_quote(package)]]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSString *l = trimmed(line);
            if ([l hasPrefix:@"package:"]) {
                [paths addObject:[l substringFromIndex:8]];
            }
        }
        if (!paths.count) {
            [self flash:@"Could not find the APK of the app"];
            return;
        }
        // One APK: <package>.apk; split APKs: a folder with all of them
        NSString *target = paths.count == 1
            ? [self desktopPathForFile:[package stringByAppendingString:@".apk"]]
            : [self desktopPathForFile:package];
        if (paths.count > 1) {
            [[NSFileManager defaultManager] createDirectoryAtPath:target
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }
        [self showProgress:[NSString stringWithFormat:@"Saving %@…", package]];
        __block NSUInteger pending = paths.count;
        __block BOOL failed = NO;
        for (NSString *path in paths) {
            [self runAdb:@[@"pull", path, target]
                stdoutFile:nil
                      done:^(int s2, NSString *o2, NSString *e2) {
                failed = failed || s2 != 0;
                if (--pending == 0) {
                    if (failed) {
                        [self flash:@"Could not save the APK"];
                    } else {
                        [self flash:[NSString stringWithFormat:
                            @"APK saved on Desktop: %@", target.lastPathComponent]];
                        [[NSWorkspace sharedWorkspace]
                            activateFileViewerSelectingURLs:
                                @[[NSURL fileURLWithPath:target]]];
                    }
                }
            }];
        }
    }];
}

// Clear the cache of one app. Android 17 leaves `pm clear --cache-only` hanging
// when it comes from adb, so it gets a time limit; the external cache (which
// adb can delete) is always cleared.
- (void)clearCacheOfPackage:(NSString *)package {
    NSString *quoted = shell_quote(package);
    NSString *external = shell_quote([NSString stringWithFormat:
        @"/sdcard/Android/data/%@/cache", package]);
    NSString *script = [NSString stringWithFormat:
        @"rm -rf %@/* 2>/dev/null;"
        @" timeout -s KILL 3 pm clear --cache-only %@ >/dev/null 2>&1; echo $?",
        external, quoted];
    [self showProgress:[NSString stringWithFormat:@"Clearing the cache of %@…",
                           package]];
    NSTask *task = [self runAdb:@[@"shell", script]
                     stdoutFile:nil
                           done:^(int status, NSString *out, NSString *err) {
        // The shell session may be closed from here (see below): the result
        // is the exit code printed before
        BOOL ok = [trimmed(out) isEqualToString:@"0"];
        [self flash:ok
            ? [NSString stringWithFormat:@"Cache of %@ cleared", package]
            : [NSString stringWithFormat:
                  @"External cache of %@ cleared. Android does not let adb clear"
                  @" its internal cache: use Clear All Caches", package]];
    }];
    // A command killed on the device can leave the adb session open
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (task.isRunning) {
            [task terminate];
        }
    });
}

// Every app: Android frees the caches (they are rebuilt when needed)
- (void)clearAllCaches:(id)sender {
    [self showProgress:@"Clearing the caches of all the apps…"];
    [self runAdb:@[@"shell", @"timeout 90 pm trim-caches 100G; echo $?"]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        [self flash:status == 0 && [trimmed(out) hasSuffix:@"0"]
            ? @"Caches of all the apps cleared"
            : @"Could not clear all the caches"];
    }];
}

- (void)runAppAction:(NSString *)action package:(NSString *)package {
    NSString *quoted = shell_quote(package);
    if ([action isEqualToString:@"open"]) {
        [self openApp:package then:nil];
    } else if ([action isEqualToString:@"restart"]) {
        [self runAdb:@[@"shell", [@"am force-stop " stringByAppendingString:quoted]]
            stdoutFile:nil
                  done:^(int status, NSString *out, NSString *err) {
            [self openApp:package then:nil];
        }];
    } else if ([action isEqualToString:@"stop"]) {
        [self runAppShell:[@"am force-stop " stringByAppendingString:quoted]
                  success:[NSString stringWithFormat:@"Stopped %@", package]
                  refresh:NO];
    } else if ([action isEqualToString:@"cache"]) {
        [self clearCacheOfPackage:package];
    } else if ([action isEqualToString:@"cacheall"]) {
        [self clearAllCaches:nil];
    } else if ([action isEqualToString:@"data"]) {
        [self confirm:[NSString stringWithFormat:@"Clear all the data of %@?",
                          package]
               detail:@"The app signs out and loses its settings, accounts and "
                      @"files. This cannot be undone."
               action:@"Clear Data"
              handler:^{
            [self runAppShell:[@"pm clear " stringByAppendingString:quoted]
                      success:[NSString stringWithFormat:@"Data of %@ cleared",
                                  package]
                      refresh:NO];
        }];
    } else if ([action isEqualToString:@"disable"]
            || [action isEqualToString:@"enable"]) {
        BOOL disable = [action isEqualToString:@"disable"];
        [self runAppShell:[NSString stringWithFormat:
                              disable ? @"pm disable-user --user 0 %@"
                                      : @"pm enable %@", quoted]
                  success:[NSString stringWithFormat:@"%@ %@", package,
                              disable ? @"disabled" : @"enabled"]
                  refresh:YES];
    } else if ([action isEqualToString:@"uninstall"]) {
        NSDictionary *app = [self selectedApp];
        BOOL system = [app[@"system"] boolValue];
        [self confirm:[NSString stringWithFormat:@"Uninstall %@?", package]
               detail:system
                   ? @"It is a system app: it is removed for the current user "
                     @"only (a factory reset or reinstall brings it back)."
                   : @"The app and its data are removed from the device."
               action:@"Uninstall"
              handler:^{
            [self runAppShell:[NSString stringWithFormat:
                                  system ? @"pm uninstall --user 0 %@"
                                         : @"pm uninstall %@", quoted]
                      success:[NSString stringWithFormat:@"%@ uninstalled",
                                  package]
                      refresh:YES];
        }];
    } else if ([action isEqualToString:@"info"]) {
        [self runAppShell:[NSString stringWithFormat:
            @"am start -a android.settings.APPLICATION_DETAILS_SETTINGS"
            @" -d package:%@", package]
                  success:@"Opened the app info on the device"
                  refresh:NO];
    } else if ([action isEqualToString:@"permissions"]) {
        [self showPermissionsOf:package];
    } else if ([action isEqualToString:@"pull"]) {
        [self saveAPKOf:package];
    } else if ([action isEqualToString:@"copy"]) {
        [self copyToClipboard:package];
        [self flash:[NSString stringWithFormat:@"Copied: %@", package]];
    }
}

#pragma mark - Live device info

static NSString *const kLiveInfoScript =
    @"echo '@@battery'; dumpsys battery;"
    @" echo '@@mem'; grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree'"
    @" /proc/meminfo;"
    @" echo '@@df'; df /data | tail -1;"
    @" echo '@@focus'; dumpsys activity activities 2>/dev/null"
    @" | grep -m1 topResumedActivity;"
    @" echo '@@focus2'; dumpsys window 2>/dev/null | grep -m1 mCurrentFocus;"
    @" echo '@@wifi'; dumpsys wifi 2>/dev/null | grep -m1 mWifiInfo;"
    @" echo '@@load'; cat /proc/loadavg;"
    @" echo '@@uptime'; cat /proc/uptime;"
    @" echo '@@thermal'; dumpsys thermalservice 2>/dev/null"
    @" | grep -E 'Temperature[{]mValue|Thermal Status' | head -24;"
    @" echo '@@power'; dumpsys power 2>/dev/null | grep -m1 'mWakefulness=';"
    @" echo '@@end'";

static NSString *
format_bytes_kb(double kb) {
    double gb = kb / 1048576.0;
    return gb >= 1 ? [NSString stringWithFormat:@"%.1f GB", gb]
                   : [NSString stringWithFormat:@"%.0f MB", kb / 1024.0];
}

static NSString *
first_match(NSString *text, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:text
                                             options:0
                                               range:NSMakeRange(0, text.length)];
    return m && m.numberOfRanges > 1 ? [text substringWithRange:[m rangeAtIndex:1]]
                                     : nil;
}

// Split the output of kLiveInfoScript in sections and read the values
static NSDictionary<NSString *, id> *
parse_live_info(NSString *out) {
    NSMutableDictionary *sections = [NSMutableDictionary dictionary];
    NSString *current = nil;
    NSMutableString *buffer = nil;
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"@@"]) {
            current = [line substringFromIndex:2];
            buffer = [NSMutableString string];
            sections[current] = buffer;
        } else if (buffer) {
            [buffer appendFormat:@"%@\n", line];
        }
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    NSString *battery = sections[@"battery"] ?: @"";
    NSString *level = first_match(battery, @"\n\\s*level: (\\d+)");
    NSString *temp = first_match(battery, @"\n\\s*temperature: (-?\\d+)");
    NSString *status = first_match(battery, @"\n\\s*status: (\\d+)");
    NSString *health = first_match(battery, @"\n\\s*health: (\\d+)");
    NSString *voltage = first_match(battery, @"\n\\s*voltage: (\\d+)");
    if (level) { info[@"level"] = @(level.intValue); }
    if (temp) { info[@"batteryTemp"] = @(temp.doubleValue / 10.0); }
    if (voltage) { info[@"voltage"] = @(voltage.doubleValue / 1000.0); }
    NSArray *statuses = @[@"Unknown", @"Unknown", @"Charging", @"Discharging",
                          @"Not charging", @"Full"];
    NSInteger st = status.integerValue;
    info[@"status"] = st >= 0 && st < (NSInteger) statuses.count ? statuses[st]
                                                                  : @"Unknown";
    NSArray *healths = @[@"Unknown", @"Unknown", @"Good", @"Overheated", @"Dead",
                         @"Over voltage", @"Failure", @"Cold"];
    NSInteger h = health.integerValue;
    info[@"health"] = h >= 0 && h < (NSInteger) healths.count ? healths[h]
                                                               : @"Unknown";
    NSMutableArray *power = [NSMutableArray array];
    if ([battery containsString:@"AC powered: true"]) { [power addObject:@"AC"]; }
    if ([battery containsString:@"USB powered: true"]) { [power addObject:@"USB"]; }
    if ([battery containsString:@"Wireless powered: true"]) {
        [power addObject:@"Wireless"];
    }
    info[@"plugged"] = [power componentsJoinedByString:@" + "];

    NSString *mem = sections[@"mem"] ?: @"";
    for (NSString *key in @[@"MemTotal", @"MemAvailable", @"SwapTotal",
                            @"SwapFree"]) {
        NSString *v = first_match(mem, [NSString stringWithFormat:
                                           @"%@:\\s+(\\d+) kB", key]);
        if (v) { info[key] = @(v.doubleValue); }
    }

    NSString *df = trimmed(sections[@"df"] ?: @"");
    NSArray *cols = [[df componentsSeparatedByString:@" "]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (cols.count >= 4) {
        info[@"dfTotal"] = @([cols[1] doubleValue]);
        info[@"dfUsed"] = @([cols[2] doubleValue]);
        info[@"dfAvail"] = @([cols[3] doubleValue]);
    }

    NSString *focus = sections[@"focus"] ?: @"";
    NSString *package = nil, *activity = nil;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"u0 ([A-Za-z0-9_.]+)/([A-Za-z0-9_.$]+)"
                             options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:focus options:0
                                               range:NSMakeRange(0, focus.length)];
    if (m) {
        package = [focus substringWithRange:[m rangeAtIndex:1]];
        activity = [focus substringWithRange:[m rangeAtIndex:2]];
    } else {
        NSString *f2 = sections[@"focus2"] ?: @"";
        m = [re firstMatchInString:f2 options:0 range:NSMakeRange(0, f2.length)];
        if (m) {
            package = [f2 substringWithRange:[m rangeAtIndex:1]];
            activity = [f2 substringWithRange:[m rangeAtIndex:2]];
        }
    }
    if (package) { info[@"package"] = package; }
    if (activity) { info[@"activity"] = activity; }

    NSString *wifi = sections[@"wifi"] ?: @"";
    NSString *ssid = first_match(wifi, @"SSID: \"([^\"]*)\"");
    if (ssid) { info[@"ssid"] = ssid; }
    NSString *rssi = first_match(wifi, @"RSSI: (-?\\d+)");
    if (rssi) { info[@"rssi"] = @(rssi.intValue); }
    NSString *speed = first_match(wifi, @"Link speed: (\\d+)Mbps");
    if (speed) { info[@"linkSpeed"] = @(speed.intValue); }
    NSString *std = first_match(wifi, @"Wi-Fi standard: (\\w+)");
    if (std) { info[@"wifiStandard"] = std; }
    NSString *freq = first_match(wifi, @"Frequency: (\\d+)MHz");
    if (freq) { info[@"frequency"] = @(freq.intValue); }

    NSArray *load = [trimmed(sections[@"load"] ?: @"")
        componentsSeparatedByString:@" "];
    if (load.count >= 3) {
        info[@"load"] = [NSString stringWithFormat:@"%@ · %@ · %@", load[0],
                            load[1], load[2]];
    }
    NSString *up = first_match(sections[@"uptime"] ?: @"", @"^\\s*([0-9.]+)");
    if (up) { info[@"uptime"] = @(up.doubleValue); }
    info[@"awake"] = [(sections[@"power"] ?: @"") containsString:@"Awake"]
        ? @"Awake" : ([(sections[@"power"] ?: @"") containsString:@"Dozing"]
                          ? @"Screen off" : @"");

    // Thermal sensors of the SoC
    NSString *thermal = sections[@"thermal"] ?: @"";
    NSString *tstatus = first_match(thermal, @"Thermal Status: (\\d+)");
    NSArray *tnames = @[@"None", @"Light", @"Moderate", @"Severe", @"Critical",
                        @"Emergency", @"Shutdown"];
    NSInteger ts = tstatus.integerValue;
    info[@"thermalStatus"] = ts >= 0 && ts < (NSInteger) tnames.count
        ? tnames[ts] : @"Unknown";
    NSRegularExpression *tre = [NSRegularExpression
        regularExpressionWithPattern:@"mValue=([0-9.]+), mType=(-?\\d+), mName=([^,]+),"
                             options:0 error:nil];
    double cpu = 0, soc = 0, disp = 0, skin = 0;
    for (NSTextCheckingResult *t in [tre matchesInString:thermal options:0
                                                  range:NSMakeRange(0, thermal.length)]) {
        double value = [[thermal substringWithRange:[t rangeAtIndex:1]] doubleValue];
        NSInteger type = [[thermal substringWithRange:[t rangeAtIndex:2]] integerValue];
        NSString *name = [thermal substringWithRange:[t rangeAtIndex:3]];
        if (value <= 0) { continue; }
        if (type == 0) { cpu = MAX(cpu, value); }
        else if ([name isEqualToString:@"soc_therm"]) { soc = value; }
        else if ([name isEqualToString:@"disp_therm"]) { disp = value; }
        else if ([name.uppercaseString containsString:@"SKIN"]) { skin = MAX(skin, value); }
    }
    if (cpu) { info[@"cpuTemp"] = @(cpu); }
    if (soc) { info[@"socTemp"] = @(soc); }
    if (disp) { info[@"dispTemp"] = @(disp); }
    if (skin) { info[@"skinTemp"] = @(skin); }
    return info;
}

static NSString *
format_uptime(double seconds) {
    long s = (long) seconds;
    long d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
    return d ? [NSString stringWithFormat:@"%ldd %ldh %ldm", d, h, m]
             : [NSString stringWithFormat:@"%ldh %ldm", h, m];
}

static NSString *
signal_quality(int rssi) {
    return rssi >= -55 ? @"Excellent" : rssi >= -67 ? @"Good"
         : rssi >= -75 ? @"Fair" : @"Weak";
}

static NSColor *
temperature_color(double c) {
    return c >= 45 ? NSColor.systemRedColor
         : c >= 40 ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
}

// Plain text of the info, for the clipboard and the tests
static NSString *
live_info_text(NSDictionary *i) {
    NSMutableArray *lines = [NSMutableArray array];
    if (i[@"level"]) {
        [lines addObject:[NSString stringWithFormat:
            @"Battery: %@%% · %@%@ · %.1f °C · %.2f V · %@", i[@"level"],
            i[@"status"], [i[@"plugged"] length]
                ? [NSString stringWithFormat:@" (%@)", i[@"plugged"]] : @"",
            [i[@"batteryTemp"] doubleValue], [i[@"voltage"] doubleValue],
            i[@"health"]]];
    }
    if (i[@"MemTotal"]) {
        [lines addObject:[NSString stringWithFormat:
            @"Memory: %@ free of %@ (swap %@ free of %@)",
            format_bytes_kb([i[@"MemAvailable"] doubleValue]),
            format_bytes_kb([i[@"MemTotal"] doubleValue]),
            format_bytes_kb([i[@"SwapFree"] doubleValue]),
            format_bytes_kb([i[@"SwapTotal"] doubleValue])]];
    }
    if (i[@"dfTotal"]) {
        [lines addObject:[NSString stringWithFormat:
            @"Storage: %@ free of %@", format_bytes_kb([i[@"dfAvail"] doubleValue]),
            format_bytes_kb([i[@"dfTotal"] doubleValue])]];
    }
    if (i[@"package"]) {
        [lines addObject:[NSString stringWithFormat:@"Foreground: %@/%@",
            i[@"package"], i[@"activity"]]];
    }
    if (i[@"ssid"]) {
        [lines addObject:[NSString stringWithFormat:
            @"Wi-Fi: %@ · %@ dBm (%@) · %@ Mbps · %@ · %@ MHz", i[@"ssid"],
            i[@"rssi"], signal_quality([i[@"rssi"] intValue]), i[@"linkSpeed"],
            i[@"wifiStandard"] ?: @"", i[@"frequency"] ?: @"?"]];
    }
    [lines addObject:[NSString stringWithFormat:
        @"Thermal: %@ · CPU %.1f °C · SoC %.1f °C · Display %.1f °C · Skin %.1f °C",
        i[@"thermalStatus"], [i[@"cpuTemp"] doubleValue],
        [i[@"socTemp"] doubleValue], [i[@"dispTemp"] doubleValue],
        [i[@"skinTemp"] doubleValue]]];
    if (i[@"load"]) {
        [lines addObject:[NSString stringWithFormat:@"Load average: %@", i[@"load"]]];
    }
    if (i[@"uptime"]) {
        [lines addObject:[NSString stringWithFormat:@"Uptime: %@",
            format_uptime([i[@"uptime"] doubleValue])]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSTextField *)infoLabel:(NSString *)text bold:(BOOL)bold {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = bold ? [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                  : [NSFont systemFontOfSize:12];
    l.textColor = bold ? NSColor.labelColor : NSColor.secondaryLabelColor;
    l.lineBreakMode = NSLineBreakByTruncatingMiddle;
    l.maximumNumberOfLines = 1;
    return l;
}

- (NSStackView *)infoSection:(NSString *)title
                      symbol:(NSString *)symbol
                       views:(NSArray<NSView *> *)views {
    NSTextField *header = [self infoLabel:title bold:YES];
    NSImageView *icon = [NSImageView imageViewWithImage:
        menu_image(symbol, title) ?: [NSImage imageNamed:NSImageNameInfo]];
    icon.contentTintColor = NSColor.controlAccentColor;
    NSStackView *head = [NSStackView stackViewWithViews:@[icon, header]];
    head.spacing = 6;
    NSMutableArray *all = [NSMutableArray arrayWithObject:head];
    [all addObjectsFromArray:views];
    NSStackView *section = [NSStackView stackViewWithViews:all];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 4;
    return section;
}

- (void)buildDeviceInfoWindow {
    NSPanel *w = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 400, 620)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                          | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [self configureToolPanel:w];
    w.title = [NSString stringWithFormat:@"Device Info — %@",
                  self.serial ?: @"device"];
    w.releasedWhenClosed = NO;
    w.delegate = self;
    [w setFrameAutosaveName:@"scrcpy.deviceInfo"];

    NSMutableDictionary *labels = [NSMutableDictionary dictionary];
    NSTextField *(^value)(NSString *) = ^NSTextField *(NSString *key) {
        NSTextField *l = [self infoLabel:@"—" bold:NO];
        labels[key] = l;
        return l;
    };
    SCBarView *(^bar)(NSString *) = ^SCBarView *(NSString *key) {
        SCBarView *b = [[SCBarView alloc] init];
        labels[key] = b;
        return b;
    };
    SCSparkView *(^spark)(NSString *) = ^SCSparkView *(NSString *key) {
        SCSparkView *v = [[SCSparkView alloc] init];
        labels[key] = v;
        return v;
    };
    NSTextField *(^big)(NSString *) = ^NSTextField *(NSString *key) {
        NSTextField *l = [NSTextField labelWithString:@"—"];
        l.font = [NSFont monospacedDigitSystemFontOfSize:26
                                                  weight:NSFontWeightSemibold];
        labels[key] = l;
        return l;
    };

    NSArray<NSView *> *sections = @[
        [self infoSection:@"Battery" symbol:@"battery.100" views:@[
            big(@"batteryBig"), bar(@"batteryBar"), value(@"batteryLine"),
            value(@"batteryLine2"), spark(@"tempSpark")]],
        [self infoSection:@"Memory" symbol:@"memorychip" views:@[
            value(@"memLine"), bar(@"memBar"), value(@"swapLine"),
            spark(@"memSpark")]],
        [self infoSection:@"Storage" symbol:@"internaldrive" views:@[
            value(@"dfLine"), bar(@"dfBar")]],
        [self infoSection:@"Temperatures" symbol:@"thermometer.medium" views:@[
            value(@"thermalLine"), value(@"thermalLine2")]],
        [self infoSection:@"Wi-Fi" symbol:@"wifi" views:@[
            value(@"wifiLine"), value(@"wifiLine2")]],
        [self infoSection:@"Foreground app" symbol:@"app.badge" views:@[
            value(@"focusLine"), value(@"focusLine2")]],
        [self infoSection:@"System" symbol:@"cpu" views:@[
            value(@"loadLine"), value(@"uptimeLine")]],
    ];

    NSButton *live = [NSButton checkboxWithTitle:@"Live (every 3 s)"
                                          target:self
                                          action:@selector(infoLiveChanged:)];
    live.state = NSControlStateValueOn;
    NSButton *copy = [NSButton buttonWithTitle:@"Copy"
                                        target:self
                                        action:@selector(copyDeviceInfoText:)];
    copy.image = menu_image(@"doc.on.doc", @"Copy");
    copy.imagePosition = NSImageLeading;
    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh"
                                           target:self
                                           action:@selector(refreshDeviceInfo)];
    NSStackView *footer = [NSStackView stackViewWithViews:@[live, copy, refresh]];
    footer.spacing = 12;

    NSMutableArray *rows = [NSMutableArray arrayWithArray:sections];
    [rows addObject:footer];
    NSStackView *root = [NSStackView stackViewWithViews:rows];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 14;
    root.edgeInsets = NSEdgeInsetsMake(16, 18, 16, 18);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [w.contentView addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:w.contentView.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:w.contentView.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:w.contentView.topAnchor],
        [root.bottomAnchor constraintLessThanOrEqualToAnchor:
            w.contentView.bottomAnchor],
    ]];
    // Bars and charts use the whole width
    for (NSString *key in @[@"batteryBar", @"memBar", @"dfBar", @"tempSpark",
                            @"memSpark"]) {
        NSView *v = labels[key];
        [v.widthAnchor constraintEqualToAnchor:root.widthAnchor
                                      constant:-36].active = YES;
    }

    self.infoWindow = w;
    self.infoLabels = labels;
    self.infoLive = live;
    self.tempHistory = [NSMutableArray array];
    self.memHistory = [NSMutableArray array];
    self.batteryHistory = [NSMutableArray array];
    [w layoutIfNeeded];
    NSSize fit = root.fittingSize;
    [w setContentSize:NSMakeSize(MAX(400, fit.width), fit.height)];
    [w center];
}

- (void)setInfoText:(NSString *)text forKey:(NSString *)key {
    NSTextField *l = self.infoLabels[key];
    if ([l isKindOfClass:[NSTextField class]]) {
        l.stringValue = text ?: @"—";
    }
}

- (void)updateDeviceInfoUI:(NSDictionary *)i {
    self.lastInfo = i;
    NSDictionary *L = self.infoLabels;

    if (i[@"level"]) {
        int level = [i[@"level"] intValue];
        [self setInfoText:[NSString stringWithFormat:@"%d %%", level]
                   forKey:@"batteryBig"];
        SCBarView *bar = L[@"batteryBar"];
        bar.fraction = level / 100.0;
        bar.color = level <= 15 ? NSColor.systemRedColor
                  : level <= 30 ? NSColor.systemOrangeColor
                                : NSColor.systemGreenColor;
        [self setInfoText:[NSString stringWithFormat:@"%@%@ · %@", i[@"status"],
                              [i[@"plugged"] length]
                                  ? [NSString stringWithFormat:@" (%@)", i[@"plugged"]]
                                  : @"", i[@"health"]]
                   forKey:@"batteryLine"];
        double temp = [i[@"batteryTemp"] doubleValue];
        [self setInfoText:[NSString stringWithFormat:@"%.1f °C · %.2f V", temp,
                              [i[@"voltage"] doubleValue]]
                   forKey:@"batteryLine2"];
        ((NSTextField *) L[@"batteryLine2"]).textColor = temperature_color(temp);
        [self.tempHistory addObject:@(temp)];
        SCSparkView *spark = L[@"tempSpark"];
        spark.color = temperature_color(temp);
        spark.values = [self.tempHistory copy];
    }

    if (i[@"MemTotal"]) {
        double total = [i[@"MemTotal"] doubleValue];
        double avail = [i[@"MemAvailable"] doubleValue];
        [self setInfoText:[NSString stringWithFormat:@"%@ free of %@",
                              format_bytes_kb(avail), format_bytes_kb(total)]
                   forKey:@"memLine"];
        SCBarView *bar = L[@"memBar"];
        double used = total ? (total - avail) / total : 0;
        bar.fraction = used;
        bar.color = used >= 0.9 ? NSColor.systemRedColor
                  : used >= 0.75 ? NSColor.systemOrangeColor
                                 : NSColor.controlAccentColor;
        double swap_total = [i[@"SwapTotal"] doubleValue];
        [self setInfoText:swap_total
            ? [NSString stringWithFormat:@"Swap: %@ used of %@",
                  format_bytes_kb(swap_total - [i[@"SwapFree"] doubleValue]),
                  format_bytes_kb(swap_total)]
            : @"No swap" forKey:@"swapLine"];
        [self.memHistory addObject:@(used * 100)];
        SCSparkView *spark = L[@"memSpark"];
        spark.color = bar.color;
        spark.values = [self.memHistory copy];
    }

    if (i[@"dfTotal"]) {
        double total = [i[@"dfTotal"] doubleValue];
        double avail = [i[@"dfAvail"] doubleValue];
        [self setInfoText:[NSString stringWithFormat:@"%@ free of %@",
                              format_bytes_kb(avail), format_bytes_kb(total)]
                   forKey:@"dfLine"];
        SCBarView *bar = L[@"dfBar"];
        double used = total ? 1 - avail / total : 0;
        bar.fraction = used;
        bar.color = used >= 0.9 ? NSColor.systemRedColor
                  : used >= 0.75 ? NSColor.systemOrangeColor
                                 : NSColor.controlAccentColor;
    }

    [self setInfoText:[NSString stringWithFormat:@"%@ · CPU %@ · SoC %@",
        i[@"thermalStatus"],
        i[@"cpuTemp"] ? [NSString stringWithFormat:@"%.0f °C", [i[@"cpuTemp"] doubleValue]] : @"—",
        i[@"socTemp"] ? [NSString stringWithFormat:@"%.0f °C", [i[@"socTemp"] doubleValue]] : @"—"]
               forKey:@"thermalLine"];
    [self setInfoText:[NSString stringWithFormat:@"Display %@ · Skin %@",
        i[@"dispTemp"] ? [NSString stringWithFormat:@"%.0f °C", [i[@"dispTemp"] doubleValue]] : @"—",
        i[@"skinTemp"] ? [NSString stringWithFormat:@"%.0f °C", [i[@"skinTemp"] doubleValue]] : @"—"]
               forKey:@"thermalLine2"];

    if (i[@"ssid"]) {
        [self setInfoText:[NSString stringWithFormat:@"%@ · %@ dBm (%@)", i[@"ssid"],
                              i[@"rssi"], signal_quality([i[@"rssi"] intValue])]
                   forKey:@"wifiLine"];
        [self setInfoText:[NSString stringWithFormat:@"%@ Mbps · %@ · %@ MHz",
                              i[@"linkSpeed"], i[@"wifiStandard"] ?: @"",
                              i[@"frequency"] ?: @"?"]
                   forKey:@"wifiLine2"];
    } else {
        [self setInfoText:@"Not connected to Wi-Fi" forKey:@"wifiLine"];
        [self setInfoText:@"" forKey:@"wifiLine2"];
    }

    if (i[@"package"]) {
        [self setInfoText:i[@"package"] forKey:@"focusLine"];
        [self setInfoText:[NSString stringWithFormat:@"%@ · %@", i[@"activity"],
                              i[@"awake"]]
                   forKey:@"focusLine2"];
    } else {
        [self setInfoText:@"No app in the foreground" forKey:@"focusLine"];
        [self setInfoText:i[@"awake"] forKey:@"focusLine2"];
    }

    [self setInfoText:[NSString stringWithFormat:@"Load average %@", i[@"load"] ?: @"—"]
               forKey:@"loadLine"];
    [self setInfoText:[NSString stringWithFormat:@"Up %@",
                          i[@"uptime"] ? format_uptime([i[@"uptime"] doubleValue])
                                       : @"—"]
               forKey:@"uptimeLine"];
    // Keep the history short
    for (NSMutableArray *history in @[self.tempHistory, self.memHistory]) {
        while (history.count > 60) {
            [history removeObjectAtIndex:0];
        }
    }
}

- (void)refreshDeviceInfo {
    if (self.infoBusy || !self.infoWindow) {
        return;
    }
    self.infoBusy = YES;
    [self runAdb:@[@"shell", kLiveInfoScript]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        self.infoBusy = NO;
        if (status != 0 || ![out containsString:@"@@end"]) {
            return; // try again at the next tick
        }
        [self updateDeviceInfoUI:parse_live_info(out)];
    }];
}

- (void)startInfoTimer {
    [self.infoTimer invalidate];
    __weak SCController *weak = self;
    self.infoTimer = [NSTimer scheduledTimerWithTimeInterval:3
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        SCController *strong = weak;
        // No work while the window can't be seen or the live mode is paused
        if (!strong.infoWindow.visible
                || !(strong.infoWindow.occlusionState
                     & NSWindowOcclusionStateVisible)
                || strong.infoLive.state != NSControlStateValueOn) {
            return;
        }
        [strong refreshDeviceInfo];
    }];
}

- (void)showDeviceInfo:(id)sender {
    if (!self.infoWindow) {
        [self buildDeviceInfoWindow];
    }
    [self updateToolPanelLevels];
    [self.infoWindow makeKeyAndOrderFront:nil];
    [self refreshDeviceInfo];
    [self startInfoTimer];
}

- (void)infoLiveChanged:(id)sender {
    if (self.infoLive.state == NSControlStateValueOn) {
        [self refreshDeviceInfo];
    }
}

- (void)copyDeviceInfoText:(id)sender {
    if (!self.lastInfo) {
        return;
    }
    [self copyToClipboard:live_info_text(self.lastInfo)];
    [self flash:@"Device info copied"];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.infoWindow) {
        [self.infoTimer invalidate];
        self.infoTimer = nil;
    }
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

#pragma mark - More developer tools

- (void)openURLOnDevice {
    NSTextField *field =
        [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 380, 24)];
    field.placeholderString = @"https://example.com or myapp://screen/42";
    // Prefill with the Mac clipboard if it holds a link, else the last URL
    NSString *clip = trimmed([[NSPasteboard generalPasteboard]
                                 stringForType:NSPasteboardTypeString] ?: @"");
    NSRegularExpression *scheme = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z][A-Za-z0-9+.-]*://\\S+$"
                             options:0
                               error:nil];
    BOOL clip_is_url = clip.length
        && [scheme firstMatchInString:clip
                              options:0
                                range:NSMakeRange(0, clip.length)];
    field.stringValue = clip_is_url ? clip
        : ([[NSUserDefaults standardUserDefaults]
               stringForKey:@"scrcpy.lastURL"] ?: @"");

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Open URL on device";
    alert.informativeText =
        @"Opens a web link or a deep link in the matching app.";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Open"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        NSString *url = trimmed(field.stringValue);
        if (response != NSAlertFirstButtonReturn || !url.length) {
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:url
                                                  forKey:@"scrcpy.lastURL"];
        // Single-quote the URL for the device shell
        NSString *quoted = [url stringByReplacingOccurrencesOfString:@"'"
                                                          withString:@"'\\''"];
        [self runShell:[NSString stringWithFormat:
                @"am start -a android.intent.action.VIEW -d '%@'", quoted]
               success:@"URL opened on the device"
            completion:nil];
    }];
}

// Logcat in a Terminal window (a .command file is opened by Terminal)
- (void)openLogcat {
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"scrcpy-logcat.command"];
    NSString *serial_arg = self.serial
        ? [NSString stringWithFormat:@"-s '%@' ", self.serial] : @"";
    NSString *content = [NSString stringWithFormat:
        @"#!/bin/bash\nclear\nexec '%@' %@logcat -v color\n", self.adb,
        serial_arg];
    NSError *error = nil;
    if (![content writeToFile:path
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:&error]) {
        [self flash:@"Could not create the logcat script"];
        return;
    }
    [[NSFileManager defaultManager]
        setAttributes:@{NSFilePosixPermissions: @0755}
         ofItemAtPath:path
                error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

#pragma mark - Clear app cache

// Ask which app to clear (the foreground one is preselected), then clear its
// cache. Clearing the data too is opt-in because it is destructive.
- (void)clearAppCache {
    NSString *cmd = @"pm list packages -3; echo ---;"
                    @" dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'";
    [self runAdb:@[@"shell", cmd]
        stdoutFile:nil
              done:^(int status, NSString *out, NSString *err) {
        if (status != 0) {
            [self flash:@"Could not list the installed apps"];
            return;
        }

        NSArray<NSString *> *parts = [out componentsSeparatedByString:@"---"];
        NSMutableArray<NSString *> *packages = [NSMutableArray array];
        for (NSString *line in [parts[0] componentsSeparatedByCharactersInSet:
                                    NSCharacterSet.newlineCharacterSet]) {
            NSString *l = [line stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceCharacterSet];
            if ([l hasPrefix:@"package:"]) {
                [packages addObject:[l substringFromIndex:8]];
            }
        }
        [packages sortUsingSelector:@selector(caseInsensitiveCompare:)];
        if (!packages.count) {
            [self flash:@"No third-party apps found"];
            return;
        }

        NSString *foreground = nil;
        if (parts.count > 1) {
            NSRegularExpression *re = [NSRegularExpression
                regularExpressionWithPattern:@"([A-Za-z0-9_.]+)/"
                                     options:0
                                       error:nil];
            NSTextCheckingResult *m =
                [re firstMatchInString:parts[1]
                               options:0
                                 range:NSMakeRange(0, [parts[1] length])];
            if (m) {
                foreground = [parts[1] substringWithRange:
                                  [m rangeAtIndex:1]];
            }
        }

        NSPopUpButton *popup = [[NSPopUpButton alloc]
            initWithFrame:NSMakeRect(0, 28, 360, 26) pullsDown:NO];
        [popup addItemsWithTitles:packages];
        if (foreground && [packages containsObject:foreground]) {
            [popup selectItemWithTitle:foreground];
        }
        NSButton *data = [NSButton checkboxWithTitle:
            @"Also clear app data (signs out and resets the app)"
                                              target:nil
                                              action:nil];
        data.frame = NSMakeRect(0, 0, 360, 22);
        NSView *accessory =
            [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 56)];
        [accessory addSubview:popup];
        [accessory addSubview:data];

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Clear app cache";
        alert.informativeText = @"Choose the app on the device.";
        alert.accessoryView = accessory;
        [alert addButtonWithTitle:@"Clear"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert beginSheetModalForWindow:self.window
                      completionHandler:^(NSModalResponse response) {
            if (response != NSAlertFirstButtonReturn) {
                return;
            }
            NSString *package = popup.selectedItem.title;
            BOOL clearData = data.state == NSControlStateValueOn;
            if (!clearData) {
                [self clearCacheOfPackage:package];
                return;
            }
            NSString *shell = [NSString stringWithFormat:
                @"pm clear '%@'", package];
            [self runShell:shell
                   success:[NSString stringWithFormat:@"%@ of %@ cleared",
                               clearData ? @"Data and cache" : @"Cache",
                               package]
                completion:nil];
        }];
    }];
}

- (void)setRecording:(BOOL)recording {
    NSToolbarItem *item = self.recordItem;
    NSString *symbol = recording ? @"stop.circle.fill" : @"record.circle";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol
                               accessibilityDescription:@"Record"];
    if (image && recording) {
        // Red while recording
        if (@available(macOS 12.0, *)) {
            image = [image imageWithSymbolConfiguration:
                [NSImageSymbolConfiguration configurationWithPaletteColors:
                    @[NSColor.systemRedColor]]];
        }
    }
    if (image) {
        item.image = image;
    }
    item.toolTip = recording ? @"Stop recording" : @"Record screen";
    item.label = recording ? @"Stop" : @"Record";
    if (@available(macOS 11.0, *)) {
        self.window.subtitle = recording
                             ? @"● Recording… (click record to stop)" : @"";
    }
}

- (void)toggleRecording {
    if (self.recordTask) {
        // Ask screenrecord to finish properly; the termination of the
        // recording task then pulls the file
        [self runAdb:@[@"shell", @"pkill", @"-2", @"screenrecord"]
            stdoutFile:nil
                  done:nil];
        return;
    }

    NSString *stamp = [self timestamp];
    self.recordRemotePath =
        [NSString stringWithFormat:@"/sdcard/scrcpy-rec-%@.mp4", stamp];
    self.recordLocalPath = [self desktopPathForFile:
        [NSString stringWithFormat:@"scrcpy-%@.mp4", stamp]];

    // screenrecord stops by itself after the time limit (Android max is 180s)
    self.recordTask = [self runAdb:@[@"shell", @"screenrecord",
                                     @"--time-limit", @"180",
                                     self.recordRemotePath]
                        stdoutFile:nil
                              done:^(int status, NSString *out, NSString *err) {
        [self recordingFinished:status error:err];
    }];
    if (!self.recordTask) {
        [self flash:@"Could not start recording"];
        return;
    }
    [self setRecording:YES];
}

- (void)recordingFinished:(int)status error:(NSString *)err {
    self.recordTask = nil;
    [self setRecording:NO];

    NSString *remote = self.recordRemotePath;
    NSString *local = self.recordLocalPath;
    // screenrecord exits with 130 on SIGINT, which is expected
    if (status != 0 && status != 130 && status != 255) {
        [self flash:[NSString stringWithFormat:@"Recording failed: %@", err]];
        return;
    }

    [self flash:@"Saving recording…"];
    [self runAdb:@[@"pull", remote, local]
        stdoutFile:nil
              done:^(int pullStatus, NSString *out, NSString *pullErr) {
        [self runAdb:@[@"shell", @"rm", @"-f", remote] stdoutFile:nil done:nil];
        if (pullStatus == 0) {
            [self flash:[NSString stringWithFormat:
                @"Recording saved on Desktop: %@", local.lastPathComponent]];
        } else {
            [self flash:@"Could not pull the recording"];
        }
    }];
}

#pragma mark - Developer tools menu

- (void)toolsMenuItem:(NSMenuItem *)item {
    NSString *key = item.representedObject;

    if ([key isEqualToString:@"metro"]) {
        [self runAdb:@[@"reverse", @"tcp:8081", @"tcp:8081"]
            stdoutFile:nil
                  done:^(int status, NSString *out, NSString *err) {
            [self flash:status == 0
                ? @"Metro reversed (device tcp:8081 → host tcp:8081)"
                : @"adb reverse failed"];
        }];
    } else if ([key isEqualToString:@"cache"]) {
        [self clearAppCache];
    } else if ([key isEqualToString:@"url"]) {
        [self openURLOnDevice];
    } else if ([key isEqualToString:@"logcat"]) {
        [self openLogcat];
    } else if ([key isEqualToString:@"animations"]) {
        [self runShell:@"case \"$(settings get global animator_duration_scale)\""
                       @" in 0*) v=1;; *) v=0;; esac;"
                       @" for k in window_animation_scale"
                       @" transition_animation_scale animator_duration_scale;"
                       @" do settings put global $k $v; done"
               success:@"Animations toggled"
            completion:nil];
    } else if ([key isEqualToString:@"pointer"]) {
        [self runShell:@"[ \"$(settings get system pointer_location)\" = 1 ]"
                       @" && settings put system pointer_location 0"
                       @" || settings put system pointer_location 1"
               success:@"Pointer location toggled"
            completion:nil];
    } else if ([key isEqualToString:@"deviceinfo"]) {
        [self runShell:@"echo \"Device: $(getprop ro.product.manufacturer)"
                       @" $(getprop ro.product.model)\";"
                       @" echo \"Android: $(getprop ro.build.version.release)"
                       @" (API $(getprop ro.build.version.sdk))\";"
                       @" wm size | head -1; wm density | head -1"
               success:@"Device info copied"
            completion:^(int status, NSString *out, NSString *err) {
            if (status == 0) {
                NSPasteboard *pb = [NSPasteboard generalPasteboard];
                [pb clearContents];
                [pb setString:trimmed(out) forType:NSPasteboardTypeString];
            }
        }];
    } else if ([key isEqualToString:@"dark"]) {
        [self runShell:@"cmd uimode night | grep -q yes"
                       @" && cmd uimode night no || cmd uimode night yes"
               success:@"Dark mode toggled"
            completion:nil];
    } else if ([key isEqualToString:@"touches"]) {
        [self runShell:@"[ \"$(settings get system show_touches)\" = 1 ]"
                       @" && settings put system show_touches 0"
                       @" || settings put system show_touches 1"
               success:@"Show touches toggled"
            completion:nil];
    } else if ([key isEqualToString:@"layout"]) {
        [self runShell:@"[ \"$(getprop debug.layout)\" = true ]"
                       @" && setprop debug.layout false"
                       @" || setprop debug.layout true;"
                       @" service call activity 1599295570"
               success:@"Layout bounds toggled (may need an app refresh)"
            completion:nil];
    } else if ([key isEqualToString:@"devsettings"]) {
        [self runShell:@"am start -a"
                       @" android.settings.APPLICATION_DEVELOPMENT_SETTINGS"
               success:@"Opened Developer options"
            completion:nil];
    } else if ([key isEqualToString:@"activity"]) {
        [self runShell:@"dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'"
               success:@"Foreground activity copied"
            completion:^(int status, NSString *out, NSString *err) {
            if (status != 0) {
                return;
            }
            NSRegularExpression *re = [NSRegularExpression
                regularExpressionWithPattern:
                    @"([A-Za-z0-9_.]+)/([A-Za-z0-9_.$]+)"
                                     options:0
                                       error:nil];
            NSTextCheckingResult *m =
                [re firstMatchInString:out
                               options:0
                                 range:NSMakeRange(0, out.length)];
            if (!m) {
                [self flash:@"No foreground activity found"];
                return;
            }
            NSString *activity = [out substringWithRange:m.range];
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            [pb setString:activity forType:NSPasteboardTypeString];
            [self flash:[NSString stringWithFormat:@"Copied: %@", activity]];
        }];
    }
}

// Menu of the "tools" button of the window: the developer tools and the
// options that the menu bar also has
- (NSMenu *)buildPopupMenu {
    NSMenu *menu = [self buildToolsMenu];
    [menu insertItem:[self itemWithTitle:@"App Manager…"
                                  symbol:@"square.grid.2x2"
                                  action:@selector(showAppManager:)
                                     tag:0]
             atIndex:0];
    [menu insertItem:[self itemWithTitle:@"Device Info…"
                                  symbol:@"gauge"
                                  action:@selector(showDeviceInfo:)
                                     tag:0]
             atIndex:1];
    [menu insertItem:[NSMenuItem separatorItem] atIndex:2];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addSimulationItemsTo:menu];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self itemWithTitle:@"Keep Device Awake"
                               symbol:@"sun.max"
                               action:@selector(toggleKeepAwake:)
                                  tag:0]];
    [menu addItem:[self qualityMenuItem]];
    [menu addItem:[self frameRateMenuItem]];
    [menu addItem:[self audioMenuItem]];
    [self addCopyIdItemsTo:menu];
    [menu addItem:[self deviceInfoMenuItem]];
    [self addFileItemsTo:menu];
    [menu addItem:[self itemWithTitle:@"Turn Device Screen Off"
                               symbol:@"moon.fill"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_SCREEN_OFF]];
    [menu addItem:[self itemWithTitle:@"Turn Device Screen On"
                               symbol:@"sun.max"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_SCREEN_ON]];
    [menu addItem:[self itemWithTitle:@"Start With Device Screen Off"
                               symbol:@"moon.zzz"
                               action:@selector(toggleScreenOffOnStart:)
                                  tag:0]];
    [menu addItem:[self itemWithTitle:@"Toggle Auto-Rotate"
                               symbol:@"lock.rotation"
                               action:@selector(toggleAutoRotate:)
                                  tag:0]];
    [menu addItem:[self itemWithTitle:@"Keep Window on Top"
                               symbol:@"pin"
                               action:@selector(toggleKeepOnTop:)
                                  tag:0]];
    [menu addItem:[self scaleMenuItem]];

    NSMenuItem *frame = [self itemWithTitle:@"Device Frame"
                                     symbol:@"iphone.gen3"
                                     action:nil
                                        tag:0];
    frame.submenu = [self buildFrameMenu];
    [menu addItem:frame];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self itemWithTitle:@"Paste to Device"
                               symbol:@"doc.on.clipboard"
                               action:@selector(pasteToDevice:)
                                  tag:0]];
    [menu addItem:[self itemWithTitle:@"Type Clipboard as Keystrokes"
                               symbol:@"keyboard"
                               action:@selector(typeClipboard:)
                                  tag:0]];
    [menu addItem:[self itemWithTitle:@"Copy from Device"
                               symbol:@"doc.on.doc"
                               action:@selector(copyFromDevice:)
                                  tag:0]];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addWifiItemsTo:menu];
    [self applyShortcutsToMenu:menu];
    return menu;
}

// Menu of the "…" button, used when the bar is too narrow to show the React
// Native buttons and the tools button
- (NSMenu *)buildOverflowMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Debug"];
    [menu addItem:[self itemWithTitle:@"React Native developer menu"
                               symbol:@"ladybug"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_DEV_MENU]];
    [menu addItem:[self itemWithTitle:@"Reload React Native"
                               symbol:@"arrow.clockwise"
                               action:@selector(buttonClicked:)
                                  tag:SC_TOOLBAR_BUTTON_DEV_RELOAD]];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenu *popup = [self buildPopupMenu];
    NSArray *items = popup.itemArray;
    [popup removeAllItems];
    for (NSMenuItem *item in items) {
        [menu addItem:item];
    }
    return menu;
}

- (NSMenu *)buildToolsMenu {
    struct {
        __unsafe_unretained NSString *title;
        __unsafe_unretained NSString *key;
        __unsafe_unretained NSString *symbol;
    } defs[] = {
        {@"Reverse Metro port (tcp:8081)", @"metro",
            @"arrow.left.arrow.right"},
        {@"Open URL / deep link…", @"url", @"link"},
        {@"Clear app cache…", @"cache", @"trash"},
        {@"Open logcat in Terminal", @"logcat", @"terminal"},
        {@"Toggle animations", @"animations", @"film"},
        {@"Toggle pointer location", @"pointer", @"scope"},
        {@"Toggle dark mode", @"dark", @"moon.circle"},
        {@"Toggle show touches", @"touches", @"hand.tap"},
        {@"Toggle layout bounds", @"layout", @"rectangle.dashed"},
        {@"Open Developer options", @"devsettings", @"gearshape.2"},
        {@"Copy foreground activity", @"activity", @"doc.on.clipboard"},
    };

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Developer tools"];
    for (size_t i = 0; i < sizeof(defs) / sizeof(defs[0]); ++i) {
        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:defs[i].title
                                       action:@selector(toolsMenuItem:)
                                keyEquivalent:@""];
        item.target = self;
        item.representedObject = defs[i].key;
        item.image = menu_image(defs[i].symbol, defs[i].title);
        [menu addItem:item];
    }
    return menu;
}

@end

#pragma mark - Drop target

// Highlight shown while a file is dragged over the window. It ignores the mouse
// (hitTest returns nil), the events reach the SDL view.
@interface SCDropOverlay : NSView
@end

@implementation SCDropOverlay

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect r = NSInsetRect(self.bounds, 14, 14);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r
                                                         xRadius:28
                                                         yRadius:28];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.16] setFill];
    [path fill];
    [NSColor.controlAccentColor setStroke];
    path.lineWidth = 3;
    const CGFloat dash[] = {10, 7};
    [path setLineDash:dash count:2 phase:0];
    [path stroke];
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
