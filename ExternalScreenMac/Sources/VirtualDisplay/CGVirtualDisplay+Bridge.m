#import "CGVirtualDisplay+Bridge.h"
#import <objc/runtime.h>

// Private API class declarations
// These classes exist in CoreGraphics but are not publicly documented

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) BOOL hiDPI;
@property (nonatomic, copy) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) NSUInteger productID;
@property (nonatomic) NSUInteger vendorID;
@property (nonatomic) UInt32 serialNum;
@property (nonatomic, copy) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id display, id error);
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation VirtualDisplayBridge {
    id _virtualDisplay;
    CGDirectDisplayID _displayID;
    BOOL _isActive;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _virtualDisplay = nil;
        _displayID = 0;
        _isActive = NO;
    }
    return self;
}

- (void)dealloc {
    [self destroyDisplay];
}

- (id)virtualDisplay {
    return _virtualDisplay;
}

- (CGDirectDisplayID)displayID {
    return _displayID;
}

- (BOOL)isActive {
    return _isActive;
}

- (BOOL)createDisplayWithWidth:(NSUInteger)width
                        height:(NSUInteger)height
                           ppi:(NSUInteger)ppi
                   refreshRate:(double)refreshRate
                          name:(NSString *)name
                         hiDPI:(BOOL)hiDPI {

    if (_isActive) {
        NSLog(@"VirtualDisplayBridge: Display already active, destroying first");
        [self destroyDisplay];
    }

    // Check if CGVirtualDisplay class exists
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");

    if (!descriptorClass || !settingsClass || !modeClass) {
        NSLog(@"VirtualDisplayBridge: Required private classes not found. Are you running macOS 11+?");
        return NO;
    }

    // Calculate physical size in millimeters based on PPI
    // Formula: size_mm = (pixels / ppi) * 25.4
    CGFloat widthMM = (CGFloat)width / (CGFloat)ppi * 25.4;
    CGFloat heightMM = (CGFloat)height / (CGFloat)ppi * 25.4;

    // Create descriptor
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(widthMM, heightMM);
    descriptor.productID = 0x1234;
    descriptor.vendorID = 0x5678;
    // Use a fixed serial number so macOS remembers display position
    // This allows the display arrangement to persist across restarts
    descriptor.serialNum = 0xE0190D01;
    descriptor.queue = dispatch_get_main_queue();

    __weak typeof(self) weakSelf = self;
    descriptor.terminationHandler = ^(id display, id error) {
        NSLog(@"VirtualDisplayBridge: Display terminated. Error: %@", error);
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_isActive = NO;
            strongSelf->_displayID = 0;
        }
    };

    // Create virtual display
    _virtualDisplay = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];

    if (!_virtualDisplay) {
        NSLog(@"VirtualDisplayBridge: Failed to create CGVirtualDisplay");
        return NO;
    }

    // Create display mode
    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                                   initWithWidth:width
                                   height:height
                                   refreshRate:refreshRate];

    // Create settings
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI;
    settings.modes = @[mode];

    // Apply settings
    BOOL success = [(CGVirtualDisplay *)_virtualDisplay applySettings:settings];

    if (!success) {
        NSLog(@"VirtualDisplayBridge: Failed to apply display settings");
        _virtualDisplay = nil;
        return NO;
    }

    // Get the display ID
    _displayID = [(CGVirtualDisplay *)_virtualDisplay displayID];
    _isActive = YES;

    NSLog(@"VirtualDisplayBridge: Created virtual display with ID %u (%lux%lu @ %.1fHz)",
          _displayID, (unsigned long)width, (unsigned long)height, refreshRate);

    return YES;
}

- (void)destroyDisplay {
    if (_virtualDisplay) {
        NSLog(@"VirtualDisplayBridge: Destroying virtual display with ID %u", _displayID);
        _virtualDisplay = nil;
        _displayID = 0;
        _isActive = NO;
    }
}

- (BOOL)updateDisplayWithWidth:(NSUInteger)width
                        height:(NSUInteger)height
                   refreshRate:(double)refreshRate {

    if (!_isActive || !_virtualDisplay) {
        NSLog(@"VirtualDisplayBridge: Cannot update - no active display");
        return NO;
    }

    // Create new mode
    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                                   initWithWidth:width
                                   height:height
                                   refreshRate:refreshRate];

    // Create settings
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = YES;  // Keep HiDPI enabled
    settings.modes = @[mode];

    // Apply settings
    BOOL success = [(CGVirtualDisplay *)_virtualDisplay applySettings:settings];

    if (success) {
        NSLog(@"VirtualDisplayBridge: Updated display to %lux%lu @ %.1fHz",
              (unsigned long)width, (unsigned long)height, refreshRate);
    } else {
        NSLog(@"VirtualDisplayBridge: Failed to update display settings");
    }

    return success;
}

@end
