#import <AppKit/AppKit.h>

@interface FixtureDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *itemCyan;
@property(nonatomic, strong) NSStatusItem *itemYellow;
@property(nonatomic, strong) NSStatusItem *itemOrange;
@end

@implementation FixtureDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.itemCyan = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *cyan = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor colorWithSRGBRed:0 green:1 blue:1 alpha:1] setFill];
        NSRectFill(rect);
        return YES;
    }];
    cyan.template = NO;
    self.itemCyan.button.image = cyan;

    self.itemYellow = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *yellow = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor colorWithSRGBRed:1 green:1 blue:0 alpha:1] setFill];
        NSRectFill(rect);
        return YES;
    }];
    yellow.template = NO;
    self.itemYellow.button.image = yellow;

    self.itemOrange = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *orange = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor colorWithSRGBRed:255.0/255.0 green:128.0/255.0 blue:0.0/255.0 alpha:1] setFill];
        NSRectFill(rect);
        return YES;
    }];
    orange.template = NO;
    self.itemOrange.button.image = orange;
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
