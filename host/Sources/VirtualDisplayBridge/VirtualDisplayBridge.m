#import "VirtualDisplayBridge.h"

#import <dlfcn.h>

// CoreGraphics' virtual display classes (private; the same ones BetterDisplay, Chromium's display
// tests and others use). Weakly imported: if a future macOS drops them the app still launches and
// `isSupported` is NO.

__attribute__((weak_import))
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

__attribute__((weak_import))
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) NSUInteger hiDPI;
@end

__attribute__((weak_import))
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNumber;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic, strong) dispatch_queue_t dispatchQueue;
@property (nonatomic, copy) void (^terminationHandler)(void);
@end

__attribute__((weak_import))
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// The window server's own list of a display's modes, the only place a virtual display's Retina
// mode shows up (CGDisplayCopyAllDisplayModes returns nothing for it). Private too, so looked up
// by name at run time: missing symbols mean "no Retina mode", never a failure to launch.
typedef struct {
    uint32_t modeNumber;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint8_t unknown[170];
    uint16_t frequency;
    uint8_t more[16];
    float density;
} JumpDisplayModeDescription;

typedef void (*CountModes)(CGDirectDisplayID, int *);
typedef void (*DescribeMode)(CGDirectDisplayID, int, JumpDisplayModeDescription *, int);
typedef CGError (*ConfigureMode)(CGDisplayConfigRef, CGDirectDisplayID, int);

@implementation JumpVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != Nil && NSClassFromString(@"CGVirtualDisplayDescriptor") != Nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != Nil && NSClassFromString(@"CGVirtualDisplayMode") != Nil;
}

+ (uint32_t)vendorID { return 0x4A50; }
+ (NSUInteger)maxPixelsWide { return 5120; }
+ (NSUInteger)maxPixelsHigh { return 3200; }

+ (instancetype)displayNamed:(NSString *)name
                  pixelsWide:(NSUInteger)pixelsWide
                  pixelsHigh:(NSUInteger)pixelsHigh
                       hiDPI:(BOOL)hiDPI
                  terminated:(void (^)(void))terminated {
    if (!self.isSupported) return nil;
    @try {
        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.name = name;
        // The same identity every time, so macOS recognises "this monitor" and puts windows
        // back where they were with it.
        descriptor.vendorID = self.vendorID;
        descriptor.productID = 0x0001;
        descriptor.serialNumber = 1;
        descriptor.sizeInMillimeters = CGSizeMake(520, 325);
        descriptor.maxPixelsWide = self.maxPixelsWide;
        descriptor.maxPixelsHigh = self.maxPixelsHigh;
        descriptor.dispatchQueue = dispatch_get_main_queue();
        descriptor.terminationHandler = terminated;

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!display || display.displayID == 0) return nil;
        JumpVirtualDisplay *wrapper = [[JumpVirtualDisplay alloc] init];
        wrapper->_display = display;
        if (![wrapper setPixelsWide:pixelsWide pixelsHigh:pixelsHigh hiDPI:hiDPI]) return nil;
        return wrapper;
    } @catch (NSException *exception) {
        NSLog(@"JumpVirtualDisplay: %@", exception.reason);
        return nil;
    }
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

- (BOOL)setPixelsWide:(NSUInteger)pixelsWide pixelsHigh:(NSUInteger)pixelsHigh hiDPI:(BOOL)hiDPI {
    if (pixelsWide > JumpVirtualDisplay.maxPixelsWide || pixelsHigh > JumpVirtualDisplay.maxPixelsHigh) return NO;
    @try {
        // A mode is given in points; with hiDPI the frame buffer is twice that.
        NSUInteger scale = hiDPI ? 2 : 1;
        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:pixelsWide / scale
                                                                         height:pixelsHigh / scale
                                                                    refreshRate:60];
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.modes = @[mode];
        settings.hiDPI = hiDPI ? 1 : 0;
        return [_display applySettings:settings];
    } @catch (NSException *exception) {
        NSLog(@"JumpVirtualDisplay: %@", exception.reason);
        return NO;
    }
}

- (NSInteger)modeNumberForPointsWide:(NSUInteger)pointsWide scale:(NSUInteger)scale {
    CountModes countModes = (CountModes)dlsym(RTLD_DEFAULT, "CGSGetNumberOfDisplayModes");
    DescribeMode describeMode = (DescribeMode)dlsym(RTLD_DEFAULT, "CGSGetDisplayModeDescriptionOfLength");
    if (!countModes || !describeMode || !_display) return -1;
    int count = 0;
    countModes(_display.displayID, &count);
    for (int index = 0; index < count && index < 512; index++) {
        JumpDisplayModeDescription mode;
        memset(&mode, 0, sizeof mode);
        describeMode(_display.displayID, index, &mode, (int)sizeof mode);
        if (mode.width == pointsWide && (NSUInteger)lroundf(mode.density) == scale) return mode.modeNumber;
    }
    return -1;
}

- (BOOL)applyModeNumber:(NSInteger)modeNumber mirroring:(NSArray<NSNumber *> *)displays {
    if (!_display) return NO;
    ConfigureMode configureMode = (ConfigureMode)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayMode");
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return NO;
    BOOL ok = YES;
    if (modeNumber >= 0 && configureMode) ok = configureMode(config, _display.displayID, (int)modeNumber) == kCGErrorSuccess;
    for (NSNumber *display in displays) {
        if (display.unsignedIntValue == _display.displayID) continue;
        ok = CGConfigureDisplayMirrorOfDisplay(config, display.unsignedIntValue, _display.displayID) == kCGErrorSuccess && ok;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess && ok;
}

+ (BOOL)stopMirroring:(NSArray<NSNumber *> *)displays {
    if (displays.count == 0) return YES;
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return NO;
    for (NSNumber *display in displays) {
        CGConfigureDisplayMirrorOfDisplay(config, display.unsignedIntValue, kCGNullDirectDisplay);
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
}

@end
