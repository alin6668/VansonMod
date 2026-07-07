//
//  main.mm
//  vansonmodd — VansonMod HTTP API 守护进程
//
//  独立于 UI App 运行，开机自启，永不挂起。
//  承载 HTTP API 服务器 + 内存修改引擎。
//

#import "src/api/VMAPIRouter.h"
#import "src/api/VMHTTPServer.h"
#import "include/VMMemoryEngine.h"
#import <Foundation/Foundation.h>
#import <signal.h>
#import <unistd.h>
#import <sys/time.h>
#import <sys/resource.h>

static void handle_signal(int sig) {
    NSLog(@"[vansonmodd] 收到信号 %d (%s)，正在退出...", sig, strsignal(sig));
    [VMAPIRouter stopServer];
    [[VMMemoryEngine shared] clearSession];
    exit(0);
}

static void uncaughtExceptionHandler(NSException *exception) {
    NSLog(@"[vansonmodd] ❌ 未捕获异常: %@\n%@", exception.name, exception.reason);
    NSLog(@"[vansonmodd] 调用栈:\n%@", exception.callStackSymbols);
    exit(EXIT_FAILURE);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 信号处理
        signal(SIGTERM, handle_signal);
        signal(SIGINT,  handle_signal);
        signal(SIGPIPE, SIG_IGN);  // 忽略 SIGPIPE，防止写入关闭的 socket 时崩溃
        signal(SIGHUP,  SIG_IGN);  // 忽略终端挂断

        // 提高进程优先级，降低被 Jetsam 杀死的概率
        setpriority(PRIO_PROCESS, 0, -10);

        // 未捕获异常处理 → 崩溃时输出日志并退出，让 launchd 重启
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);

        NSLog(@"[vansonmodd] === VansonMod HTTP Daemon v3.1.3 启动 (PID=%d) ===", getpid());

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

        // ================================================================
        // 防 Jetsam 心跳: 每 10 秒执行实际系统调用
        // iOS Jetsam ~30 秒杀死"空闲"进程，但 accept() 阻塞不被视为活动。
        // 10 秒间隔确保在 Jetsam 超时前刷新进程活跃状态。
        // ================================================================
        __block uint32_t tickCount = 0;
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            tickCount++;

            // 执行系统调用刷新进程活跃状态 (Jetsam 跟踪这些)
            struct rusage ru;
            getrusage(RUSAGE_SELF, &ru);

            VMMemoryEngine *eng = [VMMemoryEngine shared];
            BOOL isRunning = [[VMHTTPServer shared] isRunning];

            if (tickCount % 6 == 0) {  // 每 60 秒打印一次详细日志
                NSLog(@"[vansonmodd] 💓 心跳 #%u | running=%d | attached=%d | pid=%d | "
                      "results=%lu | mem=%ldMB",
                      tickCount, isRunning,
                      eng.targetPid != 0, eng.targetPid,
                      (unsigned long)eng.resultCount,
                      ru.ru_maxrss / 1024);
            }

            // 如果服务器意外停止，尝试重启
            if (!isRunning) {
                NSLog(@"[vansonmodd] ⚠️ HTTP 服务器已停止！尝试重启...");
                NSString *newURL = [VMAPIRouter startServerOnPort:8848];
                if (newURL) {
                    NSLog(@"[vansonmodd] ✅ HTTP 服务器已重启: %@", newURL);
                } else {
                    NSLog(@"[vansonmodd] ❌ HTTP 服务器重启失败！");
                }
            }
        }];

        // 持续运行
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
