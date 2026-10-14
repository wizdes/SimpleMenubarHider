#import <AppKit/AppKit.h>

@interface FixtureDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@end

@implementation FixtureDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title = @"F1";
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
