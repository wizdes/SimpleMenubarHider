#import "SMHMenuBarShim.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const SMHShimDomain = @"SMHShim";
#define configSelector @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)
#define activateSelector @selector(activateWithConfiguration:completionHandler:)
#define invalidateSelector @selector(invalidate)

static NSError *SMHError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:SMHShimDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface SMHMenuBarShim ()
@property (nonatomic, strong, nullable) id activeAssertion;
@property (nonatomic, strong, nullable) id pendingAssertion;
@property (nonatomic, copy, nullable) void (^pendingCompletion)(NSError * _Nullable);
@property (nonatomic) NSUInteger generation;
@end

@implementation SMHMenuBarShim

+ (BOOL)isAvailable {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW);
        Class configuration = objc_getClass("MBAssessmentModeConfiguration");
        Class assertion = objc_getClass("MBAssessmentModeAssertion");
        available = handle && configuration && assertion
            && [configuration instancesRespondToSelector:configSelector]
            && [assertion instancesRespondToSelector:@selector(init)]
            && [assertion instancesRespondToSelector:activateSelector]
            && [assertion instancesRespondToSelector:invalidateSelector];
    });
    return available;
}

- (void)invalidate:(id _Nullable)assertion {
    if (!assertion) return;
    @try {
        if ([assertion respondsToSelector:invalidateSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, invalidateSelector);
        }
    } @catch (NSException *exception) {
        NSLog(@"SMHShim invalidate exception: %@", exception);
    }
}

- (void)finishGeneration:(NSUInteger)generation assertion:(id _Nullable)finished error:(NSError * _Nullable)error {
    if (generation != self.generation || !self.pendingCompletion || finished != self.pendingAssertion) {
        // This activation was superseded, released or timed out, and its completion already ran.
        // If it still succeeded, nothing owns the assertion, so end it now.
        if (!error && finished && finished != self.activeAssertion) {
            NSLog(@"SMHShim late activation success for old generation %lu (current %lu); invalidating it",
                  (unsigned long)generation, (unsigned long)self.generation);
            [self invalidate:finished];
        }
        return;
    }
    id assertion = self.pendingAssertion;
    void (^completion)(NSError * _Nullable) = self.pendingCompletion;
    self.pendingAssertion = nil;
    self.pendingCompletion = nil;
    if (error) {
        [self invalidate:assertion];
    } else {
        id previous = self.activeAssertion;
        self.activeAssertion = assertion;
        [self invalidate:previous];
    }
    completion(error);
}

- (void)supersedePending {
    if (!self.pendingCompletion) return;
    void (^completion)(NSError * _Nullable) = self.pendingCompletion;
    id assertion = self.pendingAssertion;
    self.pendingCompletion = nil;
    self.pendingAssertion = nil;
    [self invalidate:assertion];
    completion(SMHError(2, @"superseded"));
}

- (void)applyAllowedBundleIDs:(NSArray<NSString *> *)ids
                  systemItems:(NSArray<NSNumber *> *)items
                   completion:(void (^)(NSError * _Nullable))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyAllowedBundleIDs:ids systemItems:items completion:completion]; });
        return;
    }
    self.generation++;
    [self supersedePending];
    if (![SMHMenuBarShim isAvailable]) {
        completion(SMHError(1, @"MenuBarClientCore class or selector missing"));
        return;
    }
    id assertion = nil;
    @try {
        Class configClass = objc_getClass("MBAssessmentModeConfiguration");
        Class assertionClass = objc_getClass("MBAssessmentModeAssertion");
        if (!configClass || !assertionClass ||
            ![configClass instancesRespondToSelector:configSelector] ||
            ![assertionClass instancesRespondToSelector:activateSelector] ||
            ![assertionClass instancesRespondToSelector:invalidateSelector]) {
            completion(SMHError(1, @"MenuBarClientCore class or selector missing"));
            return;
        }
        id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)([configClass alloc], configSelector, items, ids);
        assertion = ((id (*)(id, SEL))objc_msgSend)([assertionClass alloc], @selector(init));
        if (!configuration || !assertion) {
            [self invalidate:assertion];
            completion(SMHError(1, @"MenuBarClientCore initialization failed"));
            return;
        }
        self.pendingAssertion = assertion;
        self.pendingCompletion = [completion copy];
        NSUInteger generation = self.generation;
        ((void (*)(id, SEL, id, id))objc_msgSend)(assertion, activateSelector, configuration, ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishGeneration:generation assertion:assertion error:error]; });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self finishGeneration:generation assertion:assertion error:SMHError(3, @"activation timed out after 5 seconds")];
        });
    } @catch (NSException *exception) {
        if (self.pendingCompletion) {
            [self finishGeneration:self.generation assertion:self.pendingAssertion
                             error:SMHError(1, exception.reason ?: @"MenuBarClientCore exception")];
        } else {
            [self invalidate:assertion];
            completion(SMHError(1, exception.reason ?: @"MenuBarClientCore exception"));
        }
    }
}

- (void)releaseAll {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self releaseAll]; });
        return;
    }
    self.generation++;
    id pending = self.pendingAssertion;
    void (^completion)(NSError * _Nullable) = self.pendingCompletion;
    self.pendingAssertion = nil;
    self.pendingCompletion = nil;
    id active = self.activeAssertion;
    self.activeAssertion = nil;
    [self invalidate:pending];
    [self invalidate:active];
    if (completion) completion(SMHError(2, @"superseded"));
}

@end
