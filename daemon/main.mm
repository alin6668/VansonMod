//
//  main.mm
//  vansonmodd — VansonMod HTTP API 守护进程
//
//  独立于 UI App 运行，开机自启，永不挂起。
//  承载 HTTP API 服务器 + 内存修改引擎。
//

#import "src/api/VMAPIRouter.h"
#import "include/VMMemoryEngine.h"
#import <Foundation/Foundation.h>
#import <signal.h>
#import <unistd.h>

static void handle_signal(int sig) {
    NSLog(@"[vansonmodd] 收到信号 %d，正在退出...", sig);
    [VMAPIRouter stopServer];
    [[VMMemoryEngine shared] clearSession];
    exit(0);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 信号处理：LaunchDaemon 停止时优雅退出
        signal(SIGTERM, handle_signal);
        signal(SIGINT,  handle_signal);

        NSLog(@"[vansonmodd] === VansonMod HTTP Daemon v3.1.2 启动 ===");

        // 注册所有 /api/* 路由
        [VMAPIRouter registerAllRoutes];

        // 启动 HTTP 服务器 (端口 8848)
        NSString *url = [VMAPIRouter startServerOnPort:8848];
        if (url) {
            NSLog(@"[vansonmodd] ✅ HTTP API 已启动: %@", url);
        } else {
            NSLog(@"[vansonmodd] ❌ HTTP 服务器启动失败！");
            return 1;
        }

        // 持续运行
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
