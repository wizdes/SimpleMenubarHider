#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SMHMenuBarShim : NSObject
+ (BOOL)isAvailable;
- (void)applyAllowedBundleIDs:(NSArray<NSString *> *)ids
                  systemItems:(NSArray<NSNumber *> *)items
                   completion:(void (^)(NSError * _Nullable error))completion;
- (void)releaseAll;
@end

NS_ASSUME_NONNULL_END
