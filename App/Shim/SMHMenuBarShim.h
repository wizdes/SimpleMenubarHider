#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SMHMenuBarShim : NSObject
+ (BOOL)isAvailable;
- (void)applyAllowedBundleIDs:(NSArray<NSString *> *)ids
                  systemItems:(NSArray<NSNumber *> *)items
                   completion:(void (^)(NSError * _Nullable error))completion;
- (void)releaseAll;
#ifdef SMH_SHIM_TESTS
/// Tests only (App/Shim/SMHMenuBarShimTests.swift): use these classes instead of
/// MenuBarClientCore's, skip dlopen, and time out activations after `timeout` seconds.
+ (void)useTestConfigurationClass:(NSString *)configuration
                   assertionClass:(NSString *)assertion
                activationTimeout:(NSTimeInterval)timeout;
#endif
@end

NS_ASSUME_NONNULL_END
