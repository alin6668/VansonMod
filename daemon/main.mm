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
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <pthread/qos.h>

// 常量
static const uint16_t kHTTPPort = 8848;

// ---------------------------------------------------------------------------
// memorystatus_control — iOS 私有 API (需要 com.apple.private.memorystatus)
// 设置 Jetsam 优先级，降低被系统杀死的概率
// ---------------------------------------------------------------------------
#ifndef MEMORYSTATUS_CMD_SET_PRIORITY
#define MEMORYSTATUS_CMD_SET_PRIORITY  1
#define MEMORYSTATUS_CMD_GET_PRIORITY  2
#endif

// Jetsam 优先级常量 (数值越大越不容易被杀)
#define JETSAM_PRIORITY_CRITICAL       40
#define JETSAM_PRIORITY_HIGH           30
#define JETSAM_PRIORITY_DEFAULT        15
#define JETSAM_PRIORITY_BACKGROUND     10

// memorystatus_control 声明 (libsystem_kernel.dylib, C 符号)
extern "C" int memorystatus_control(uint32_t command, int32_t pid,
                                    uint32_t flags, void *buffer, size_t buffersize);

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
// set_jetsam_priority — 将当前进程设为最高 Jetsam 优先级
// ---------------------------------------------------------------------------
static void set_jetsam_priority(void) {
    int result = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY,
                                      getpid(),
                                      JETSAM_PRIORITY_CRITICAL,
                                      NULL, 0);
    if (result == 0) {
        // 回读验证
        int32_t current = 0;
        if (memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY,
                                 getpid(), 0,
                                 &current, sizeof(current)) == 0) {
            NSLog(@"[vansonmodd] 🛡️ Jetsam 优先级: %d (CRITICAL=%d)",
                  current, JETSAM_PRIORITY_CRITICAL);
        } else {
            NSLog(@"[vansonmodd] 🛡️ Jetsam 优先级已设置 (验证失败, 可能需 entitlement)");
        }
    } else {
        NSLog(@"[vansonmodd] ⚠️ Jetsam 优先级设置失败 (errno=%d:%s). "
              "需要在 entitlements 中添加 com.apple.private.memorystatus",
              errno, strerror(errno));
    }
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
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    BOOL ok = (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    close(fd);
    return ok;
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

        // ---- Jetsam 防护 ----
        setpriority(PRIO_PROCESS, 0, -10);       // UNIX nice 值
        set_jetsam_priority();                     // iOS Jetsam 优先级
        // 线程 QoS: 使主线程被调度为 User Interactive 级别
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

        // ---- 未捕获异常处理 ----
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);

        NSLog(@"[vansonmodd] === VansonMod HTTP Daemon v3.3.0 启动 (PID=%d) ===", getpid());
        NSLog(@"[vansonmodd] HTTP 引擎: ios-mcp dispatch_source 模式");

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
        // 每 30 秒执行系统调用保持进程"活跃"状态
        __block uint32_t tickCount = 0;
        [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *t) {
            tickCount++;

            // 系统调用刷新进程活跃标记 (Jetsam 跟踪 process activity timeline)
            struct rusage ru;
            getrusage(RUSAGE_SELF, &ru);

            // 触发 kernel 交互，刷新 Jetsam idle tracking
            pid_t selfPid = getpid();
            kill(selfPid, 0);

            VMMemoryEngine *eng = [VMMemoryEngine shared];
            BOOL serverRunning = [[VMHTTPServer shared] isRunning];
            BOOL portReachable = tcp_port_reachable(kHTTPPort);

            if (tickCount % 2 == 0) {  // 每 60s 打印详细日志
                // ru_maxrss 在 iOS 上单位是 bytes, /1024 得 KB
                NSLog(@"[vansonmodd] 💓 #%u | running=%d port=%d | attached=%d pid=%d | "
                      "results=%lu | mem=%ldKB",
                      tickCount, serverRunning, portReachable,
                      eng.targetPid != 0, eng.targetPid,
                      (unsigned long)eng.resultCount,
                      ru.ru_maxrss / 1024);
            }

            // ---- 自愈逻辑 ----
            // isRunning=YES 但端口不可达 → dispatch_source 可能静默失效
            if (serverRunning && !portReachable) {
                NSLog(@"[vansonmodd] ⚠️ isRunning=YES 但端口 %d 不可达! "
                      "dispatch_source 可能失效，重启 HTTP 服务器...", kHTTPPort);
                [[VMHTTPServer shared] stop];
                sleep(1);
                NSString *newURL = [VMAPIRouter startServerOnPort:kHTTPPort];
                if (newURL) {
                    NSLog(@"[vansonmodd] ✅ HTTP 服务器已重启: %@", newURL);
                } else {
                    NSLog(@"[vansonmodd] ❌ HTTP 服务器重启失败!");
                }
            }
            // isRunning=NO → 服务器完全停止
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

        // 持续运行
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
