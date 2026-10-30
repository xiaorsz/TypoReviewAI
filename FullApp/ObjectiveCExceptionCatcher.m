#import "ObjectiveCExceptionCatcher.h"

@implementation ObjectiveCExceptionCatcher

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
              error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"Objective-C exception",
                @"exceptionName": exception.name,
                @"callStackSymbols": exception.callStackSymbols ?: @[]
            };
            *error = [NSError errorWithDomain:@"cc.xiaorsz.typo-review.objc-exception"
                                         code:1
                                     userInfo:userInfo];
        }
        return NO;
    }
}

@end
