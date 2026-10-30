#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjectiveCExceptionCatcher : NSObject

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
              error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
