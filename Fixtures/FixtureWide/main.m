#import <AppKit/AppKit.h>

@interface FixtureDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@end

@implementation FixtureDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:200];
    NSImage *image = [NSImage imageWithSize:NSMakeSize(200, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1] setFill];
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
        FixtureDelegate *delegate = [FixtureDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
