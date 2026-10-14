#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <signal.h>

static NSString *stamp(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    return [f stringFromDate:[NSDate date]];
}

static void dumpMethods(Class cls, BOOL meta) {
    Class target = meta ? object_getClass(cls) : cls;
    unsigned int n = 0;
    Method *methods = class_copyMethodList(target, &n);
    printf("%s %s methods (%u):\n", class_getName(cls), meta ? "class" : "instance", n);
    for (unsigned int i = 0; i < n; i++) printf("  %s\n", sel_getName(method_getName(methods[i])));
    free(methods);
}

static BOOL loadAPI(Class *config, Class *assertion) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW);
    printf("framework: %s\n", handle ? "found" : "missing");
    if (!handle) fprintf(stderr, "dlopen: %s\n", dlerror());
    *config = objc_getClass("MBAssessmentModeConfiguration");
    *assertion = objc_getClass("MBAssessmentModeAssertion");
    Class classes[] = {*config, *assertion};
    const char *names[] = {"MBAssessmentModeConfiguration", "MBAssessmentModeAssertion"};
    BOOL ok = handle != NULL;
    for (int i = 0; i < 2; i++) {
        printf("class %s: %s\n", names[i], classes[i] ? "found" : "missing");
        if (classes[i]) { dumpMethods(classes[i], NO); dumpMethods(classes[i], YES); }
        else ok = NO;
    }
    struct { Class cls; const char *name; } checks[] = {
        {*config, "initWithAllowedSystemItems:allowedBundleIdentifiers:"},
        {*assertion, "init"},
        {*assertion, "activateWithConfiguration:completionHandler:"},
        {*assertion, "invalidate"}
    };
    for (NSUInteger i = 0; i < sizeof(checks)/sizeof(checks[0]); i++) {
        SEL sel = sel_registerName(checks[i].name);
        BOOL found = checks[i].cls && [checks[i].cls instancesRespondToSelector:sel];
        printf("selector %s: %s\n", checks[i].name, found ? "found" : "missing");
        if (!found) ok = NO;
    }
    return ok;
}

static NSString *axString(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return @"";
    NSString *result = [(__bridge id)value description];
    CFRelease(value);
    return result ?: @"";
}

static void dumpAX(AXUIElementRef element, NSUInteger depth) {
    if (depth > 8) return;
    AXUIElementSetMessagingTimeout(element, 0.25);
    NSString *role = axString(element, kAXRoleAttribute);
    NSString *title = axString(element, kAXTitleAttribute);
    NSString *desc = axString(element, kAXDescriptionAttribute);
    NSString *ident = axString(element, CFSTR("AXIdentifier"));
    NSString *frame = @"";
    CFTypeRef position = NULL, size = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &position) == kAXErrorSuccess &&
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &size) == kAXErrorSuccess &&
        CFGetTypeID(position) == AXValueGetTypeID() && CFGetTypeID(size) == AXValueGetTypeID()) {
        CGPoint p; CGSize s;
        if (AXValueGetValue(position, kAXValueCGPointType, &p) && AXValueGetValue(size, kAXValueCGSizeType, &s))
            frame = [NSString stringWithFormat:@"(%.0f,%.0f %.0fx%.0f)", p.x, p.y, s.width, s.height];
    }
    if (position) CFRelease(position);
    if (size) CFRelease(size);
    printf("%*srole=%s title=%s description=%s identifier=%s frame=%s\n", (int)(depth * 2), "", role.UTF8String, title.UTF8String, desc.UTF8String, ident.UTF8String, frame.UTF8String);
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) == kAXErrorSuccess && children) {
        if (CFGetTypeID(children) == CFArrayGetTypeID()) {
            for (id child in (__bridge NSArray *)children) dumpAX((__bridge AXUIElementRef)child, depth + 1);
        }
        CFRelease(children);
    }
}

static int owners(NSString *check) {
    if (!AXIsProcessTrusted()) { puts("AX: not trusted"); return 0; }
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (check && ![app.bundleIdentifier isEqualToString:check]) continue;
        AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(element, 0.25);
        CFTypeRef extras = NULL;
        if (AXUIElementCopyAttributeValue(element, CFSTR("AXExtrasMenuBar"), &extras) == kAXErrorSuccess && extras) {
            printf("OWNER %s pid=%d path=%s\n", (app.bundleIdentifier ?: @"(nil)").UTF8String, app.processIdentifier, (app.bundleURL.path ?: @"(nil)").UTF8String);
            CFRelease(extras);
        }
        CFRelease(element);
    }
    if (check) return 0;
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([app.bundleIdentifier isEqualToString:@"com.apple.menubaragent"] || [app.bundleURL.lastPathComponent isEqualToString:@"MenuBarAgent.app"]) {
            printf("MenuBarAgent AX pid=%d\n", app.processIdentifier);
            AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
            dumpAX(element, 0);
            CFRelease(element);
        }
    }
    return 0;
}

static NSArray<NSNumber *> *systemItems(NSString *spec) {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    if (!spec) { [set addIndexesInRange:NSMakeRange(0, 256)]; }
    else {
        for (NSString *part in [spec componentsSeparatedByString:@","]) {
            NSArray *ends = [part componentsSeparatedByString:@"-"];
            if (ends.count < 1 || ends.count > 2) return nil;
            NSScanner *scanner = [NSScanner scannerWithString:ends[0]];
            NSInteger lo = -1, hi = -1;
            if (![scanner scanInteger:&lo] || !scanner.isAtEnd) return nil;
            if (ends.count == 2) {
                scanner = [NSScanner scannerWithString:ends[1]];
                if (![scanner scanInteger:&hi] || !scanner.isAtEnd) return nil;
            } else hi = lo;
            if (lo < 0 || hi < lo || hi > 255) return nil;
            [set addIndexesInRange:NSMakeRange((NSUInteger)lo, (NSUInteger)(hi - lo + 1))];
        }
    }
    NSMutableArray *result = [NSMutableArray array];
    [set enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) { (void)stop; [result addObject:@(index)]; }];
    return result;
}

static NSArray<NSString *> *ids(NSString *s) {
    if (s.length == 0) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *part in [s componentsSeparatedByString:@","]) {
        if (part.length == 0) return nil;
        [result addObject:part];
    }
    return result;
}

static int hold(int argc, const char **argv) {
    NSString *hide = nil, *only = nil, *sys = nil;
    double seconds = -1;
    for (int i = 2; i < argc; i++) {
        NSString *arg = @(argv[i]);
        if ([arg isEqualToString:@"--hide"] && i + 1 < argc) hide = @(argv[++i]);
        else if ([arg isEqualToString:@"--allow-only"] && i + 1 < argc) only = @(argv[++i]);
        else if ([arg isEqualToString:@"--system-items"] && i + 1 < argc) sys = @(argv[++i]);
        else if ([arg isEqualToString:@"--seconds"] && i + 1 < argc) {
            NSString *value = @(argv[++i]); NSScanner *scan = [NSScanner scannerWithString:value];
            if (![scan scanDouble:&seconds] || !scan.isAtEnd || seconds < 0) { fprintf(stderr, "invalid --seconds\n"); return 2; }
        } else { fprintf(stderr, "invalid hold argument: %s\n", arg.UTF8String); return 2; }
    }
    if (!hide) { fprintf(stderr, "hold requires --hide (empty is allowed)\n"); return 2; }
    NSArray *system = systemItems(sys);
    NSArray *hidden = ids(hide);
    NSArray *exclusive = only ? ids(only) : nil;
    if (!system || !hidden || (only && !exclusive)) { fprintf(stderr, "invalid list\n"); return 2; }
    Class configClass = Nil, assertionClass = Nil;
    if (!loadAPI(&configClass, &assertionClass)) return 3;
    NSMutableSet *allowed = [NSMutableSet set];
    if (only) [allowed addObjectsFromArray:exclusive];
    else {
        for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
            if (app.bundleIdentifier.length && ![hidden containsObject:app.bundleIdentifier]) [allowed addObject:app.bundleIdentifier];
        NSString *own = NSBundle.mainBundle.bundleIdentifier;
        if (own.length) [allowed addObject:own];
    }
    SEL initSel = sel_registerName("initWithAllowedSystemItems:allowedBundleIdentifiers:");
    id config = ((id (*)(id, SEL, id, id))objc_msgSend)([configClass alloc], initSel, system, allowed.allObjects);
    id assertion = ((id (*)(id, SEL))objc_msgSend)([assertionClass alloc], @selector(init));
    __block BOOL finished = NO;
    __block NSError *activationError = nil;
    SEL activate = sel_registerName("activateWithConfiguration:completionHandler:");
    ((void (*)(id, SEL, id, id))objc_msgSend)(assertion, activate, config, ^(NSError *error) {
        activationError = error; finished = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (!finished) { fprintf(stderr, "activation timed out after 5 seconds\n"); ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate)); return 4; }
    if (activationError) { fprintf(stderr, "activation error: %s\n", activationError.description.UTF8String); ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate)); return 5; }
    printf("ACTIVE %s allowed=%lu\n", stamp().UTF8String, (unsigned long)allowed.count); fflush(stdout);
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN);
    __block BOOL stop = NO;
    dispatch_source_t intSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_t termSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(intSource, ^{ stop = YES; });
    dispatch_source_set_event_handler(termSource, ^{ stop = YES; });
    dispatch_resume(intSource); dispatch_resume(termSource);
    NSDate *end = seconds >= 0 ? [NSDate dateWithTimeIntervalSinceNow:seconds] : nil;
    while (!stop && (!end || end.timeIntervalSinceNow > 0))
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
    printf("RELEASED %s\n", stamp().UTF8String); fflush(stdout);
    dispatch_source_cancel(intSource); dispatch_source_cancel(termSource);
    return 0;
}

static NSDate *parseISO(NSString *s) {
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [f dateFromString:s];
    if (!date) { f.formatOptions = NSISO8601DateFormatWithInternetDateTime; date = [f dateFromString:s]; }
    return date;
}

static BOOL logFailed = NO;
static NSNumber *newestCount(NSDate *since) {
    NSTask *task = [NSTask new];
    task.launchPath = @"/usr/bin/log";
    task.arguments = @[@"show", @"--last", @"30s", @"--info", @"--debug", @"--style", @"compact", @"--predicate", @"subsystem == \"com.apple.menubar\" AND category == \"analytics\""];
    NSPipe *pipe = [NSPipe pipe]; NSPipe *errorPipe = [NSPipe pipe];
    task.standardOutput = pipe; task.standardError = errorPipe;
    @try { [task launch]; } @catch (NSException *e) { fprintf(stderr, "log launch: %s\n", e.reason.UTF8String); return nil; }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        NSString *message = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"log show failed";
        fprintf(stderr, "log show: %s", message.UTF8String);
        if (![message hasSuffix:@"\n"]) fputc('\n', stderr);
        logFailed = YES; return nil;
    }
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSRegularExpression *countRE = [NSRegularExpression regularExpressionWithPattern:@"MenuBar\\.trailingItems\\.count.*?\\\"count\\\"\\s*:\\s*([0-9]+)" options:0 error:nil];
    NSDateFormatter *dateFormat = [NSDateFormatter new];
    dateFormat.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormat.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSNumber *latest = nil; NSDate *latestDate = nil;
    for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length < 23) continue;
        NSDate *date = [dateFormat dateFromString:[line substringToIndex:23]];
        if (!date || [date compare:since] == NSOrderedAscending) continue;
        NSTextCheckingResult *match = [countRE firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (match && (!latestDate || [date compare:latestDate] != NSOrderedAscending)) {
            latest = @([[line substringWithRange:[match rangeAtIndex:1]] integerValue]); latestDate = date;
        }
    }
    return latest;
}

static int count(int argc, const char **argv) {
    NSDate *since = [NSDate dateWithTimeIntervalSinceNow:-10];
    if (argc == 4 && strcmp(argv[2], "--since") == 0) {
        since = parseISO(@(argv[3]));
        if (!since) { fprintf(stderr, "invalid --since ISO timestamp\n"); return 2; }
    } else if (argc != 2) { fprintf(stderr, "usage: count [--since ISO]\n"); return 2; }
    for (int i = 0; i < 50; i++) {
        NSNumber *value = newestCount(since);
        if (logFailed) break;
        if (value) { printf("COUNT %ld\n", (long)value.integerValue); return 0; }
        usleep(100000);
    }
    puts("COUNT unknown"); return 6;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: smh-spike probe|owners|hold|count\n"); return 2; }
        if (strcmp(argv[1], "probe") == 0) { Class a = Nil, b = Nil; return loadAPI(&a, &b) ? 0 : 3; }
        if (strcmp(argv[1], "owners") == 0) {
            if (argc == 2) return owners(nil);
            if (argc == 4 && strcmp(argv[2], "--check") == 0) return owners(@(argv[3]));
            fprintf(stderr, "usage: owners [--check bundle-id]\n"); return 2;
        }
        if (strcmp(argv[1], "hold") == 0) return hold(argc, argv);
        if (strcmp(argv[1], "count") == 0) return count(argc, argv);
        fprintf(stderr, "unknown subcommand: %s\n", argv[1]); return 2;
    }
}
