#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations for private CoreGraphics classes
@class CGVirtualDisplay;
@class CGVirtualDisplayDescriptor;
@class CGVirtualDisplaySettings;
@class CGVirtualDisplayMode;

/// Bridge class to access private CGVirtualDisplay APIs
/// These APIs are undocumented but stable since macOS 11
@interface VirtualDisplayBridge : NSObject

/// The underlying CGVirtualDisplay instance
@property (nonatomic, strong, readonly, nullable) id virtualDisplay;

/// The display ID assigned by the system
@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// Whether the virtual display is currently active
@property (nonatomic, readonly) BOOL isActive;

/// Creates a new virtual display with the specified parameters
/// @param width Display width in pixels
/// @param height Display height in pixels
/// @param ppi Pixels per inch (affects physical size calculation)
/// @param refreshRate Refresh rate in Hz
/// @param name Display name shown in System Settings
/// @param hiDPI Whether to enable HiDPI (Retina) mode
/// @return YES if creation succeeded, NO otherwise
- (BOOL)createDisplayWithWidth:(NSUInteger)width
                        height:(NSUInteger)height
                           ppi:(NSUInteger)ppi
                   refreshRate:(double)refreshRate
                          name:(NSString *)name
                         hiDPI:(BOOL)hiDPI;

/// Destroys the virtual display
- (void)destroyDisplay;

/// Updates the display settings (resolution, refresh rate)
/// @param width New width in pixels
/// @param height New height in pixels
/// @param refreshRate New refresh rate in Hz
/// @return YES if update succeeded, NO otherwise
- (BOOL)updateDisplayWithWidth:(NSUInteger)width
                        height:(NSUInteger)height
                   refreshRate:(double)refreshRate;

@end

NS_ASSUME_NONNULL_END
