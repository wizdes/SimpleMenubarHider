#import <AppKit/AppKit.h>

@interface FixtureDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@end

@implementation FixtureDelegate
- (NSImage *)fixtureImage {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor colorWithSRGBRed:0 green:1 blue:0 alpha:1] setFill];
        NSRectFill(rect);
        return YES;
    }];
    image.template = NO;
    return image;
}

- (void)installItem {
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.image = [self fixtureImage];
}

- (void)flicker:(NSTimer *)timer {
    (void)timer;
    [[NSStatusBar systemStatusBar] removeStatusItem:self.item];
    self.item = nil;
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.image = [self fixtureImage];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self installItem];
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(flicker:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
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
