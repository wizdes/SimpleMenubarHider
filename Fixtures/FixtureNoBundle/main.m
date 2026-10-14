#import <AppKit/AppKit.h>

@interface FixtureDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@end

@implementation FixtureDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *image = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1] setFill];
        NSRectFill(rect);
        return YES;
    }];
    image.template = NO;
    self.item.button.image = image;
}
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        FixtureDelegate *delegate = [FixtureDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
