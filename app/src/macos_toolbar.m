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
