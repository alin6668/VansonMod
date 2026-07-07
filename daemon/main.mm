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
    NSLog(@"[vansonmodd] 收到信号 %d (%s)，正在退出...", sig, strsignal(sig));
    [VMAPIRouter stopServer];
    [[VMMemoryEngine shared] clearSession];
    exit(0);
}

static void uncaughtExceptionHandler(NSException *exception) {
    NSLog(@"[vansonmodd] ❌ 未捕获异常: %@\n%@", exception.name, exception.reason);
    NSLog(@"[vansonmodd] 调用栈:\n%@", exception.callStackSymbols);
    // 让 launchd 的 KeepAlive 重启我们
    exit(EXIT_FAILURE);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 信号处理
        signal(SIGTERM, handle_signal);
        signal(SIGINT,  handle_signal);
        signal(SIGPIPE, SIG_IGN);  // 忽略 SIGPIPE，防止写入关闭的 socket 时崩溃
        signal(SIGHUP,  SIG_IGN);  // 忽略终端挂断

        // 未捕获异常处理 → 崩溃时输出日志并退出，让 launchd 重启
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);

        NSLog(@"[vansonmodd] === VansonMod HTTP Daemon v3.1.2 启动 (PID=%d) ===", getpid());

        // 注册所有 /api/* 路由
        [VMAPIRouter registerAllRoutes];

        // 启动 HTTP 服务器 (端口 8848)
        NSString *url = [VMAPIRouter startServerOnPort:8848];
        if (url) {
            NSLog(@"[vansonmodd] ✅ HTTP API 已启动: %@", url);
        } else {
            NSLog(@"[vansonmodd] ❌ HTTP 服务器启动失败 (端口 8848 可能被占用)！");
            return 1;
        }

        // 每 60 秒打印心跳，方便排查守护进程是否存活
        [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES block:^(NSTimer *t) {
            VMMemoryEngine *eng = [VMMemoryEngine shared];
            NSLog(@"[vansonmodd] 💓 心跳 | attached=%d | pid=%d | results=%lu",
                  eng.targetPid != 0, eng.targetPid, (unsigned long)eng.resultCount);
        }];

        // 持续运行
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
