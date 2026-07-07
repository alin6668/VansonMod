//
//  main.mm
//  vansonmodd — VansonMod HTTP API 守护进程
//
//  独立于 UI App 运行，开机自启。
//  承载 HTTP API 服务器 + 内存修改引擎。
//  HTTP 服务器采用 ios-mcp (witchan/ios-mcp) 的 dispatch_source 模式。
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

// ================================================================
// ios-mcp 风格: 多轮延迟重试启动
// 参考 Tweak.x 中 schedule_bootstrap_autostart 的做法:
// 在 daemon 启动后 0.2s/1s/2s/5s/10s/20s 依次尝试启动服务器，
// 确保 launchd 完全拉起进程后再绑定端口。
// ================================================================
static void schedule_bootstrap_retries(void) {
    static const NSTimeInterval delays[] = {0.2, 1.0, 2.0, 5.0, 10.0, 20.0};
    for (int i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if ([[VMHTTPServer shared] isRunning]) return;
            NSLog(@"[vansonmodd] 🔄 启动重试 #%d (延迟 %.1fs)...", i + 1, delays[i]);
            NSString *url = [VMAPIRouter startServerOnPort:8848];
            if (url) {
                NSLog(@"[vansonmodd] ✅ 重试成功: %@", url);
            }
        });
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 信号处理
        signal(SIGTERM, handle_signal);
        signal(SIGINT,  handle_signal);
        signal(SIGPIPE, SIG_IGN);
        signal(SIGHUP,  SIG_IGN);

        // 提高进程优先级，降低被 Jetsam 杀死的概率
        setpriority(PRIO_PROCESS, 0, -10);

        // 未捕获异常处理
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);

        NSLog(@"[vansonmodd] === VansonMod HTTP Daemon v3.2.0 启动 (PID=%d) ===", getpid());
        NSLog(@"[vansonmodd] HTTP 引擎: ios-mcp dispatch_source 模式");

        // 注册所有 /api/* 路由
        [VMAPIRouter registerAllRoutes];

        // 首次启动
        NSString *url = [VMAPIRouter startServerOnPort:8848];
        if (url) {
            NSLog(@"[vansonmodd] ✅ HTTP API 已启动: %@", url);
        } else {
            NSLog(@"[vansonmodd] ⚠️ 首次启动失败，将自动重试...");
        }

        // ios-mcp 风格: 安排多轮延迟重试 (0.2s ~ 20s)
        schedule_bootstrap_retries();

        // 每 60 秒打印健康日志
        __block uint32_t tickCount = 0;
        [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES block:^(NSTimer *t) {
            tickCount++;
            struct rusage ru;
            getrusage(RUSAGE_SELF, &ru);
            VMMemoryEngine *eng = [VMMemoryEngine shared];
            NSLog(@"[vansonmodd] 💓 #%u | running=%d | attached=%d | pid=%d | "
                  "results=%lu | mem=%ldMB",
                  tickCount,
                  [[VMHTTPServer shared] isRunning],
                  eng.targetPid != 0, eng.targetPid,
                  (unsigned long)eng.resultCount,
                  ru.ru_maxrss / 1024);
        }];

        // 持续运行
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
