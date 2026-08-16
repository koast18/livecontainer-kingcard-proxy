//
//  main.m
//  LCProxyConsole
//
//  控制台 App：LiveContainer 内的 WebView guest app，全屏加载
//  http://127.0.0.1:19092（LCProxyTweak 的 Web 控制台）。
//  使用方式：点开本 App 时 LiveContainer 在前台，控制服务器必然存活。
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
