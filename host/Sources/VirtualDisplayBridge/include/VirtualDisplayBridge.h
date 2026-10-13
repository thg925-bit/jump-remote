#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A display that exists only in software: macOS treats it as a connected monitor, so it can be
/// made exactly as big as the viewer's screen. Built on CoreGraphics' CGVirtualDisplay, which
/// Apple does not document; every use is checked at run time, and callers must cope with nil.
@interface JumpVirtualDisplay : NSObject

/// Whether this macOS still has the classes this relies on.
@property (class, readonly) BOOL isSupported;

/// Largest size a display may be given later with `setPixelsWide:…` (fixed when it is created).
@property (class, readonly) NSUInteger maxPixelsWide;
@property (class, readonly) NSUInteger maxPixelsHigh;

/// `pixelsWide`/`pixelsHigh`: the frame buffer. `hiDPI`: a Retina (2x) display of half that size
/// in points. `terminated` runs on the main queue if macOS takes the display away.
+ (nullable instancetype)displayNamed:(NSString *)name
                           pixelsWide:(NSUInteger)pixelsWide
                           pixelsHigh:(NSUInteger)pixelsHigh
                                hiDPI:(BOOL)hiDPI
                           terminated:(void (^)(void))terminated;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// Resizes the display in place.
- (BOOL)setPixelsWide:(NSUInteger)pixelsWide pixelsHigh:(NSUInteger)pixelsHigh hiDPI:(BOOL)hiDPI;

/// The window server's number for the mode `pointsWide` points wide at `scale` (2 = Retina), or
/// -1 while it isn't offered (the list fills in a moment after the display appears or resizes).
/// A new HiDPI display starts in its 1x mode; the Retina one has to be picked.
- (NSInteger)modeNumberForPointsWide:(NSUInteger)pointsWide scale:(NSUInteger)scale;

/// In one display reconfiguration: switches to `modeNumber` and makes `displays` (display IDs
/// of the physical screens) mirror this display, so the whole desktop lives on it at its size.
/// Lasts until `stopMirroring:` or until this app quits.
- (BOOL)applyModeNumber:(NSInteger)modeNumber mirroring:(NSArray<NSNumber *> *)displays;

/// Gives `displays` their own picture back.
+ (BOOL)stopMirroring:(NSArray<NSNumber *> *)displays;

@end

NS_ASSUME_NONNULL_END
