#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LCProxyConfig.h"
#import "LCProxyStats.h"
#import "LCProxyServer.h"
#import "LCProxyPaths.h"
#import "lcproxy_bridge.h"

__attribute__((constructor))
static void LCProxyControlConstructor(void) {
    @autoreleasepool {
        // Apply persisted settings immediately. The proxychains C core is already
        // initialized by its own constructor; these calls update runtime flags.
        [[LCProxyConfig shared] applyToRuntime];

        // Persist this process's cellular traffic in 10-minute buckets.
        [[LCProxyStats shared] start];
        [[LCProxyStats shared] flushNow];

        // Start the loopback web console. If another guest app already owns the
        // port, this instance stays headless but still records stats.
        BOOL web = [[LCProxyServer shared] start];
        NSLog(@"[LCProxy] control loaded, data=%@ web=%d", LCProxyDataDirectory(), web);
    }
}
