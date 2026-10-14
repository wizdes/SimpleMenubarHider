#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <math.h>

// menubar-probe: screenshot oracle for the menu bar.
//
//   menubar-probe visible --color RRGGBB [--min-pixels 40]
//       exit 0 "VISIBLE n", exit 1 "HIDDEN n", exit 7 capture error
//   menubar-probe wait --color RRGGBB --want visible|hidden [--timeout-ms 3000] [--min-pixels 40]
//       polls every 100 ms, prints "OK <elapsed_ms>" (exit 0)
//       or "TIMEOUT <last state>" (exit 1)
//
// The capture logic is copied from spike/smh-spike.m `visible`, including
// both fixes: pixels are compared in the image's own color space (falling
// back to device RGB only when the image has no RGB space), and the temp
// file is decoded before it is deleted. A blank capture is an error.

static BOOL parseColor(NSString *value, unsigned char target[3]) {
    if (value.length != 6) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    if ([value rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) return NO;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return NO;
    target[0] = (rgb >> 16) & 255;
    target[1] = (rgb >> 8) & 255;
    target[2] = rgb & 255;
    return YES;
}

static BOOL parseMinPixels(NSString *value, NSUInteger *out) {
    if (value.length == 0) return NO;
    if ([value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
    unsigned long long parsed = strtoull(value.UTF8String, NULL, 10);
    if (parsed == 0 || parsed > NSUIntegerMax) return NO;
    *out = (NSUInteger)parsed;
    return YES;
}

static BOOL parseTimeoutMs(NSString *value, long long *out) {
    if (value.length == 0) return NO;
    if ([value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
    long long parsed = strtoll(value.UTF8String, NULL, 10);
    if (parsed <= 0 || parsed > 3600000) return NO;
    *out = parsed;
    return YES;
}

// Captures the menu bar strip of every screen and counts pixels within
// tolerance 12 of the target color. Returns 0 and sets *matching on
// success, 7 on any capture error (also on a blank capture or when no
// menu bar strip is found).
static int captureCount(unsigned char target[3], NSUInteger *matching) {
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSUInteger found = 0;
    NSUInteger captures = 0;
    CGFloat mainTop = NSMaxY(NSScreen.mainScreen.frame);
    for (NSScreen *screen in NSScreen.screens) {
        NSRect frame = screen.frame, visibleFrame = screen.visibleFrame;
        NSInteger x = (NSInteger)llround(NSMinX(frame) - NSMinX(NSScreen.mainScreen.frame));
        NSInteger y = (NSInteger)llround(mainTop - NSMaxY(frame));
        NSInteger w = (NSInteger)llround(NSWidth(frame));
        NSInteger h = (NSInteger)llround(NSMaxY(frame) - NSMaxY(visibleFrame));
        if (w <= 0 || h <= 0) continue;
        captures++;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"smh-visible-%@.png", NSUUID.UUID.UUIDString]];
        NSTask *task = [NSTask new];
        task.launchPath = @"/usr/sbin/screencapture";
        task.arguments = @[@"-x", @"-R", [NSString stringWithFormat:@"%ld,%ld,%ld,%ld", (long)x, (long)y, (long)w, (long)h], path];
        @try { [task launch]; } @catch (NSException *e) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            fprintf(stderr, "capture launch failed: %s\n", e.reason.UTF8String);
            fprintf(stderr, "capture_ms %.1f\n", (CFAbsoluteTimeGetCurrent() - started) * 1000);
            return 7;
        }
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            fprintf(stderr, "capture failed for screen at %ld,%ld (exit %d)\n", (long)x, (long)y, task.terminationStatus);
            fprintf(stderr, "capture_ms %.1f\n", (CFAbsoluteTimeGetCurrent() - started) * 1000);
            return 7;
        }
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCacheImmediately: @YES}) : NULL;
        if (source) CFRelease(source);
        if (!image) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            fprintf(stderr, "capture image could not be loaded\n");
            fprintf(stderr, "capture_ms %.1f\n", (CFAbsoluteTimeGetCurrent() - started) * 1000);
            return 7;
        }
        size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
        size_t stride = width * 4;
        unsigned char *pixels = calloc(height, stride);
        CGColorSpaceRef imageSpace = CGImageGetColorSpace(image);
        CGColorSpaceRef ownedSpace = NULL;
        CGColorSpaceRef colorSpace = imageSpace;
        if (!colorSpace || CGColorSpaceGetModel(colorSpace) != kCGColorSpaceModelRGB) {
            ownedSpace = CGColorSpaceCreateDeviceRGB();
            colorSpace = ownedSpace;
        }
        CGContextRef context = pixels ? CGBitmapContextCreate(pixels, width, height, 8, stride, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
        if (ownedSpace) CGColorSpaceRelease(ownedSpace);
        if (!context) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            free(pixels); CGImageRelease(image);
            fprintf(stderr, "capture image conversion failed\n");
            fprintf(stderr, "capture_ms %.1f\n", (CFAbsoluteTimeGetCurrent() - started) * 1000);
            return 7;
        }
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        BOOL hasDecodedPixel = NO;
        for (size_t p = 0; p < width * height; p++) {
            unsigned char *rgb = pixels + p * 4;
            if (rgb[0] || rgb[1] || rgb[2] || rgb[3]) hasDecodedPixel = YES;
            if (abs((int)rgb[0] - target[0]) <= 12 && abs((int)rgb[1] - target[1]) <= 12 && abs((int)rgb[2] - target[2]) <= 12) found++;
        }
        CGContextRelease(context); CGImageRelease(image); free(pixels);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (!hasDecodedPixel) {
            fprintf(stderr, "capture image decoded empty\n");
            fprintf(stderr, "capture_ms %.1f\n", (CFAbsoluteTimeGetCurrent() - started) * 1000);
            return 7;
        }
    }
    if (captures == 0) {
        fprintf(stderr, "capture failed: no menu bar strip found\n");
        fprintf(stderr, "capture_ms %.1f\n", (CFAbsoluteTimeGetCurrent() - started) * 1000);
        return 7;
    }
    fprintf(stderr, "capture_ms %.1f\n", (CFAbsoluteTimeGetCurrent() - started) * 1000);
    *matching = found;
    return 0;
}

static int runVisible(int argc, const char **argv) {
    unsigned char target[3] = {255, 0, 255};
    NSUInteger minimum = 40;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--color") == 0 && i + 1 < argc) {
            if (!parseColor(@(argv[++i]), target)) { fprintf(stderr, "invalid --color\n"); return 2; }
        } else if (strcmp(argv[i], "--min-pixels") == 0 && i + 1 < argc) {
            if (!parseMinPixels(@(argv[++i]), &minimum)) { fprintf(stderr, "invalid --min-pixels\n"); return 2; }
        } else { fprintf(stderr, "usage: menubar-probe visible [--color RRGGBB] [--min-pixels N]\n"); return 2; }
    }
    NSUInteger matching = 0;
    int rc = captureCount(target, &matching);
    if (rc != 0) return 7;
    printf("%s %lu\n", matching >= minimum ? "VISIBLE" : "HIDDEN", (unsigned long)matching);
    return matching >= minimum ? 0 : 1;
}

static int runWait(int argc, const char **argv) {
    unsigned char target[3] = {255, 0, 255};
    BOOL haveColor = NO;
    NSString *want = nil;
    long long timeoutMs = 3000;
    NSUInteger minimum = 40;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--color") == 0 && i + 1 < argc) {
            if (!parseColor(@(argv[++i]), target)) { fprintf(stderr, "invalid --color\n"); return 2; }
            haveColor = YES;
        } else if (strcmp(argv[i], "--want") == 0 && i + 1 < argc) {
            want = [@(argv[++i]) lowercaseString];
        } else if (strcmp(argv[i], "--timeout-ms") == 0 && i + 1 < argc) {
            if (!parseTimeoutMs(@(argv[++i]), &timeoutMs)) { fprintf(stderr, "invalid --timeout-ms\n"); return 2; }
        } else if (strcmp(argv[i], "--min-pixels") == 0 && i + 1 < argc) {
            if (!parseMinPixels(@(argv[++i]), &minimum)) { fprintf(stderr, "invalid --min-pixels\n"); return 2; }
        } else { fprintf(stderr, "usage: menubar-probe wait --color RRGGBB --want visible|hidden [--timeout-ms 3000]\n"); return 2; }
    }
    if (!haveColor) { fprintf(stderr, "wait requires --color\n"); return 2; }
    if (![want isEqualToString:@"visible"] && ![want isEqualToString:@"hidden"]) {
        fprintf(stderr, "wait requires --want visible|hidden\n");
        return 2;
    }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSString *last = @"UNKNOWN";
    for (;;) {
        NSUInteger matching = 0;
        int rc = captureCount(target, &matching);
        NSString *state = rc != 0 ? @"ERROR" : (matching >= minimum ? @"VISIBLE" : @"HIDDEN");
        last = state;
        if ([state isEqualToString:[want uppercaseString]]) {
            long long elapsed = llround((CFAbsoluteTimeGetCurrent() - start) * 1000);
            printf("OK %lld\n", elapsed);
            return 0;
        }
        long long elapsed = llround((CFAbsoluteTimeGetCurrent() - start) * 1000);
        if (elapsed >= timeoutMs) {
            printf("TIMEOUT %s\n", last.UTF8String);
            return 1;
        }
        usleep(100000);
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: menubar-probe visible|wait\n"); return 2; }
        if (strcmp(argv[1], "visible") == 0) return runVisible(argc, argv);
        if (strcmp(argv[1], "wait") == 0) return runWait(argc, argv);
        fprintf(stderr, "unknown subcommand: %s\n", argv[1]); return 2;
    }
}
