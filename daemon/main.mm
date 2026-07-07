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
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import <sys/time.h>
#import <sys/resource.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <pthread/qos.h>

// 常量
static const uint16_t kHTTPPort = 8848;

// ============================================================================
// XPC Transaction — 防止 Jetsam 因"进程空闲"而杀掉 daemon
//
// iOS launchd 通过 XPC transaction 跟踪进程是否"活跃"。
// 没有 transaction → launchd 认为进程空闲 → Jetsam SIGKILL。
// EnableTransactions=true (plist) 只是启用了 tracking 机制，
// 进程仍需主动调用 xpc_transaction_begin() 来持有一个 transaction。
//
// 注意: xpc_transaction_begin 在 iOS SDK 被标记 unavailable，
// 但实际存在于 libxpc.dylib 中，通过 dlsym 动态加载。
// ============================================================================
static void begin_xpc_transaction(void) {
    void *xpcLib = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY);
    if (!xpcLib) {
        NSLog(@"[vansonmodd] ⚠️ 无法加载 libxpc.dylib: %s", dlerror());
        return;
    }
    typedef void (*xpc_txn_fn)(void);
    xpc_txn_fn txn_begin = (xpc_txn_fn)dlsym(xpcLib, "xpc_transaction_begin");
    if (txn_begin) {
        txn_begin();
        NSLog(@"[vansonmodd] 🛡️ XPC transaction 已持有");
    } else {
        NSLog(@"[vansonmodd] ⚠️ xpc_transaction_begin 符号不存在 (%s)", dlerror());
    }
    dlclose(xpcLib);
}

// ---------------------------------------------------------------------------
// crash 信号处理 — 记录 crash 日志后用非零退出码退出
// 非零退出码会触发 launchd KeepAlive 重启
// ---------------------------------------------------------------------------
static const int kCrashSignals[] = {
    SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP
};
static const int kCrashSignalCount = sizeof(kCrashSignals) / sizeof(kCrashSignals[0]);

static void crash_handler(int sig) {
    // 写入 stderr (launchd 会记录到 StandardErrorPath)
    const char *name = "UNKNOWN";
    switch (sig) {
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGBUS:  name = "SIGBUS";  break;
        case SIGABRT: name = "SIGABRT"; break;
        case SIGILL:  name = "SIGILL";  break;
        case SIGFPE:  name = "SIGFPE";  break;
        case SIGTRAP: name = "SIGTRAP"; break;
    }
    fprintf(stderr, "[vansonmodd] 💥 CRASH: 收到信号 %d (%s), PID=%d\n",
            sig, name, getpid());

    // 尝试清理
    [VMAPIRouter stopServer];
    [[VMMemoryEngine shared] clearSession];

    // 用非零退出码触发 launchd 重启
    _exit(128 + sig);
}

static void handle_signal(int sig) {
    NSLog(@"[vansonmodd] 收到信号 %d (%s)，退出并等待 launchd 重启...",
          sig, strsignal(sig));
    [VMAPIRouter stopServer];
    [[VMMemoryEngine shared] clearSession];
    // 非零退出码确保 launchd KeepAlive 触发重启
    _exit(EXIT_FAILURE);
}

static void uncaughtExceptionHandler(NSException *exception) {
    NSLog(@"[vansonmodd] ❌ 未捕获异常: %@\n%@", exception.name, exception.reason);
    NSLog(@"[vansonmodd] 调用栈:\n%@", exception.callStackSymbols);
    exit(EXIT_FAILURE);
}

// ---------------------------------------------------------------------------
// ios-mcp 风格: 多轮延迟重试启动 HTTP 服务器
// ---------------------------------------------------------------------------
static void schedule_bootstrap_retries(void) {
    static const NSTimeInterval delays[] = {0.2, 1.0, 2.0, 5.0, 10.0, 20.0};
    for (int i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if ([[VMHTTPServer shared] isRunning]) return;
            NSLog(@"[vansonmodd] 🔄 启动重试 #%d (延迟 %.1fs)...", i + 1, delays[i]);
            NSString *url = [VMAPIRouter startServerOnPort:kHTTPPort];
            if (url) {
                NSLog(@"[vansonmodd] ✅ 重试成功: %@", url);
            }
        });
    }
}

// ---------------------------------------------------------------------------
// tcp_port_reachable — 真实 TCP 连通性检查
// 比 isRunning 更可靠，能检测 dispatch_source 静默失效
// ---------------------------------------------------------------------------
static BOOL tcp_port_reachable(uint16_t port) {
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    // 重试 2 次, 每次 1.5s 超时 (共 3s), 容忍系统抖动
    for (int attempt = 0; attempt < 2; attempt++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return NO;

        struct timeval tv = {.tv_sec = 1, .tv_usec = 500000};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            close(fd);
            return YES;
        }
        close(fd);
        // 首次失败短暂等待后重试
        if (attempt == 0) usleep(200000);
    }
    return NO;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // ---- 信号处理 ----
        signal(SIGTERM, handle_signal);
        signal(SIGINT,  handle_signal);
        signal(SIGPIPE, SIG_IGN);
        signal(SIGHUP,  SIG_IGN);
        // crash 信号 → crash_handler → 记录日志 → _exit(非零) → launchd 重启
        for (int i = 0; i < kCrashSignalCount; i++) {
            signal(kCrashSignals[i], crash_handler);
        }

        // ---- Jetsam 防护 (分层策略) ----
        setpriority(PRIO_PROCESS, 0, -10);         // 1. UNIX nice (兼容)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0); // 2. QoS
        begin_xpc_transaction();                   // 3. XPC transaction 防空闲 Jetsam kill (关键!)

        // ---- 未捕获异常处理 ----
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);

        NSLog(@"[vansonmodd] === VansonMod HTTP Daemon v3.5.0 启动 (PID=%d) ===", getpid());
        NSLog(@"[vansonmodd] HTTP 引擎: ios-mcp dispatch_source 模式");
        NSLog(@"[vansonmodd] Nice=%d, QoS=USER_INTERACTIVE",
              getpriority(PRIO_PROCESS, 0));

        // ---- 注册路由 & 启动 HTTP ----
        [VMAPIRouter registerAllRoutes];

        NSString *url = [VMAPIRouter startServerOnPort:kHTTPPort];
        if (url) {
            NSLog(@"[vansonmodd] ✅ HTTP API 已启动: %@", url);
        } else {
            NSLog(@"[vansonmodd] ⚠️ 首次启动失败，将自动重试...");
        }

        // ios-mcp 风格: 多轮延迟重试
        schedule_bootstrap_retries();

        // ---- Jetsam 防杀心跳 + 健康日志 + TCP 自检 ----
        // 每 15 秒执行一次 (比 30s 更频繁, 更快发现异常)
        __block uint32_t tickCount = 0;
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) {
            tickCount++;

            // 系统调用刷新进程活跃标记
            struct rusage ru;
            getrusage(RUSAGE_SELF, &ru);
            pid_t selfPid = getpid();
            kill(selfPid, 0);

            VMMemoryEngine *eng = [VMMemoryEngine shared];
            BOOL serverRunning = [[VMHTTPServer shared] isRunning];
            BOOL portReachable = tcp_port_reachable(kHTTPPort);

            // 每次心跳都打印简要状态
            NSLog(@"[vansonmodd] 💓 #%u | alive | running=%d port=%d | "
                  "attached=%d pid=%d | results=%lu | mem=%ldKB",
                  tickCount, serverRunning, portReachable,
                  eng.targetPid != 0, eng.targetPid,
                  (unsigned long)eng.resultCount,
                  ru.ru_maxrss / 1024);

            // ---- 自愈逻辑 (安全网) ----
            // ios-mcp 的实现中 accept 错误被忽略, source 永不 cancel,
            // 理论上不需要自愈。但保留此逻辑作为最后保障。
            if (serverRunning && !portReachable) {
                NSLog(@"[vansonmodd] ⚠️ isRunning=YES 但端口 %d 不可达! 重启 HTTP...",
                      kHTTPPort);
                [[VMHTTPServer shared] stop];
                NSString *newURL = [VMAPIRouter startServerOnPort:kHTTPPort];
                if (newURL) {
                    NSLog(@"[vansonmodd] ✅ HTTP 服务器已重启: %@", newURL);
                } else {
                    NSLog(@"[vansonmodd] ❌ HTTP 服务器重启失败!");
                }
            }
            else if (!serverRunning) {
                NSLog(@"[vansonmodd] ⚠️ HTTP 服务器已停止，尝试恢复...");
                NSString *newURL = [VMAPIRouter startServerOnPort:kHTTPPort];
                if (newURL) {
                    NSLog(@"[vansonmodd] ✅ 服务器已恢复: %@", newURL);
                }
            }
        }];

        // 持续运行
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
