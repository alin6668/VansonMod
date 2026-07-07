//
// VMHTTPServer.mm
// 基于 ios-mcp (witchan/ios-mcp) 的 dispatch_source 模式重写
// 事件驱动 accept，永不阻塞，线程安全
//

#import "VMHTTPServer.h"

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <unistd.h>

#pragma mark - VMHTTPRequest

@implementation VMHTTPRequest
@end

#pragma mark - Route Entry

@interface VMRouteEntry : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) VMHTTPHandler handler;
@end
@implementation VMRouteEntry
@end

#pragma mark - VMHTTPServer

@interface VMHTTPServer ()
@property (nonatomic, assign) int serverSocket;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableArray<VMRouteEntry *> *routes;
@property (nonatomic, copy)   NSString *serverURL;
@property (nonatomic, assign) dispatch_source_t acceptSource;
@property (nonatomic, strong) dispatch_queue_t clientQueue;
@end

@implementation VMHTTPServer

+ (instancetype)shared {
    static VMHTTPServer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VMHTTPServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _port = 0;
        _running = NO;
        _routes = [NSMutableArray array];
        // ios-mcp 风格: 专用并发队列处理客户端请求
        _clientQueue = dispatch_queue_create("com.vanson.httpd.client",
                                             DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (nullable NSString *)startOnPort:(uint16_t)port {
    if (self.running) return self.serverURL;

    // 1. 创建 TCP socket
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        NSLog(@"[VansonMod API] 创建 socket 失败: %s", strerror(errno));
        return nil;
    }

    // 2. SO_REUSEADDR — 允许快速重启
    int optval = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    // 3. TCP KeepAlive — 防止 NAT 映射超时
    int keepalive = 1;
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &keepalive, sizeof(keepalive));
    int keepidle = 30;
    int keepintvl = 5;
    int keepcnt  = 3;
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPALIVE, &keepidle, sizeof(keepidle));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPINTVL, &keepintvl, sizeof(keepintvl));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPCNT,  &keepcnt,  sizeof(keepcnt));

    // 4. bind
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[VansonMod API] 绑定端口 %d 失败: %s", port, strerror(errno));
        close(sock);
        return nil;
    }

    // 5. listen
    if (listen(sock, 8) < 0) {
        NSLog(@"[VansonMod API] 监听失败: %s", strerror(errno));
        close(sock);
        return nil;
    }

    _serverSocket = sock;
    _port = port;
    _running = YES;

    // 获取本机 WiFi IP
    NSString *localIP = [self getWiFiIP];
    self.serverURL = [NSString stringWithFormat:@"http://%@:%d", localIP ?: @"127.0.0.1", port];

    // ================================================================
    // ios-mcp 风格的 dispatch_source accept 事件监听
    //
    // 与 ios-mcp (witchan/ios-mcp) 完全一致的实现模式:
    //   - 专用并发队列承载 dispatch_source (非主队列)
    //   - 每次事件只 accept() 一次，不做 while 循环
    //   - 新连接派发到独立 _clientQueue 处理
    //   - cancel_handler 中关闭 socket
    //
    // 为什么这样写?
    //   dispatch_source 是事件驱动的，当 socket 可读时内核通知 GCD，
    //   GCD 调度 event handler block 到指定队列。单个事件中只需 accept
    //   一次，如果有积压连接，内核会再次触发 READ 事件。
    //
    //   ios-mcp 项目线上稳定运行已证明此模式在 iOS 越狱环境下完全可靠。
    // ================================================================

    // 专用并发队列 (ios-mcp 风格)
    dispatch_queue_t acceptQueue = dispatch_queue_create(
        "com.vanson.httpd.accept", DISPATCH_QUEUE_CONCURRENT);

    _acceptSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ,
        (uintptr_t)sock, 0,
        acceptQueue);

    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self) return;

        // ios-mcp: 每次事件只 accept 一次
        int client = accept(sock, NULL, NULL);
        if (client >= 0) {
            // 设置客户端 socket 超时
            struct timeval tv;
            tv.tv_sec = 10;
            tv.tv_usec = 0;
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

            // 派发到 clientQueue 并发处理 (ios-mcp 风格)
            dispatch_async(self->_clientQueue, ^{
                [self handleClient:client];
            });
        }
        // accept 失败时不处理，dispatch_source 会在 socket 再次可读时重试
    });

    // ios-mcp: cancel_handler 只负责关 socket
    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(sock);
        NSLog(@"[VansonMod API] accept source 已取消, socket 已关闭");
    });

    dispatch_resume(_acceptSource);

    NSLog(@"[VansonMod API] ✅ HTTP 服务器已启动 (ios-mcp dispatch_source 模式) → %@:%d",
          localIP ?: @"0.0.0.0", port);

    return self.serverURL;
}

- (void)stop {
    if (!_running) return;
    _running = NO;

    // ios-mcp 风格: cancel source → cancel_handler 自动 close socket
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    _serverSocket = -1;
    self.serverURL = nil;

    NSLog(@"[VansonMod API] HTTP 服务器已停止");
}

- (BOOL)isRunning {
    return _running && _acceptSource != nil && _serverSocket >= 0;
}

- (void)on:(NSString *)method path:(NSString *)path handler:(VMHTTPHandler)handler {
    VMRouteEntry *entry = [[VMRouteEntry alloc] init];
    entry.method = [method uppercaseString];
    entry.path = path;
    entry.handler = handler;
    [self.routes addObject:entry];
}

#pragma mark - Client Handler

- (void)handleClient:(int)clientFd {
    @autoreleasepool {
        // 读取请求
        char buffer[65536];
        memset(buffer, 0, sizeof(buffer));
        ssize_t bytesRead = recv(clientFd, buffer, sizeof(buffer) - 1, 0);
        if (bytesRead <= 0) {
            close(clientFd);
            return;
        }

        NSString *rawRequest = [[NSString alloc] initWithBytes:buffer length:bytesRead encoding:NSUTF8StringEncoding];
        if (!rawRequest) {
            [self sendResponse:clientFd code:400 json:@{@"error": @"Invalid UTF-8"}];
            close(clientFd);
            return;
        }

        // 解析 HTTP 请求
        VMHTTPRequest *req = [self parseRequest:rawRequest];
        if (!req) {
            [self sendResponse:clientFd code:400 json:@{@"error": @"Bad request"}];
            close(clientFd);
            return;
        }

        // 路由匹配
        VMRouteEntry *matched = [self findRouteForMethod:req.method path:req.path];

        if (matched) {
            // 提取 query 参数
            req.query = [self parseQuery:req.path];

            // 使用 __block + dispatch_semaphore 支持异步 handler
            __block BOOL responded = NO;
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);

            matched.handler(req, ^(int code, NSDictionary *json) {
                [self sendResponse:clientFd code:code json:json];
                responded = YES;
                dispatch_semaphore_signal(sema);
            });

            // 等待异步 handler 完成（最长 30 秒）
            dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            // 如果 handler 超时未响应，发送 500
            if (!responded) {
                [self sendResponse:clientFd code:500 json:@{@"error": @"Handler timeout"}];
            }
        } else {
            [self sendResponse:clientFd code:404 json:@{@"error": @"Not found", @"path": req.path}];
        }

        close(clientFd);
    }
}

#pragma mark - HTTP Parser

- (nullable VMHTTPRequest *)parseRequest:(NSString *)raw {
    NSArray *lines = [raw componentsSeparatedByString:@"\r\n"];
    if (lines.count < 1) return nil;

    // 请求行: METHOD /path HTTP/1.1
    NSArray *reqLine = [lines[0] componentsSeparatedByString:@" "];
    if (reqLine.count < 2) return nil;

    VMHTTPRequest *req = [[VMHTTPRequest alloc] init];
    req.method = [reqLine[0] uppercaseString];
    req.path = reqLine[1];

    // 解析 headers
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSUInteger i = 1;
    for (; i < lines.count; i++) {
        NSString *line = lines[i];
        if (line.length == 0) break; // 空行 = header 结束
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *val = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            headers[key] = val;
        }
    }
    req.headers = headers;

    // 解析 body (header 后的内容)
    if (i + 1 < lines.count) {
        req.body = [[lines subarrayWithRange:NSMakeRange(i + 1, lines.count - i - 1)] componentsJoinedByString:@"\r\n"];
    }

    return req;
}

- (NSDictionary<NSString *, NSString *> *)parseQuery:(NSString *)path {
    NSRange q = [path rangeOfString:@"?"];
    if (q.location == NSNotFound) return @{};

    NSString *queryStr = [path substringFromIndex:q.location + 1];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    for (NSString *pair in [queryStr componentsSeparatedByString:@"&"]) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count == 2) {
            result[kv[0]] = [kv[1] stringByRemovingPercentEncoding] ?: kv[1];
        }
    }
    return result;
}

- (nullable VMRouteEntry *)findRouteForMethod:(NSString *)method path:(NSString *)path {
    // 去掉 query string
    NSString *cleanPath = path;
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        cleanPath = [path substringToIndex:q.location];
    }

    for (VMRouteEntry *entry in self.routes) {
        if ([entry.method isEqualToString:method] && [entry.path isEqualToString:cleanPath]) {
            return entry;
        }
    }
    return nil;
}

#pragma mark - Response

- (void)sendResponse:(int)clientFd code:(int)code json:(NSDictionary *)json {
    @autoreleasepool {
        NSError *err;
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:json ?: @{}
                                                           options:0
                                                             error:&err];
        if (err) {
            NSString *errStr = [NSString stringWithFormat:@"{\"error\":\"%@\"}", err.localizedDescription];
            bodyData = [errStr dataUsingEncoding:NSUTF8StringEncoding];
        }

        // 构建响应
        NSString *statusText = [self statusText:code];
        NSMutableString *response = [NSMutableString string];
        [response appendFormat:@"HTTP/1.1 %d %@\r\n", code, statusText];
        [response appendString:@"Content-Type: application/json; charset=utf-8\r\n"];
        [response appendString:@"Access-Control-Allow-Origin: *\r\n"];
        [response appendString:@"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"];
        [response appendString:@"Access-Control-Allow-Headers: Content-Type\r\n"];
        [response appendFormat:@"Content-Length: %lu\r\n", (unsigned long)bodyData.length];
        [response appendString:@"Connection: close\r\n"];
        [response appendString:@"Server: VansonMod/3.1\r\n"];
        [response appendString:@"\r\n"];

        // 发送 header
        NSData *headerData = [response dataUsingEncoding:NSUTF8StringEncoding];
        send(clientFd, headerData.bytes, headerData.length, 0);

        // 发送 body
        send(clientFd, bodyData.bytes, bodyData.length, 0);
    }
}

- (NSString *)statusText:(int)code {
    switch (code) {
        case 200: return @"OK";
        case 201: return @"Created";
        case 204: return @"No Content";
        case 400: return @"Bad Request";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 500: return @"Internal Server Error";
        default:  return @"Unknown";
    }
}

#pragma mark - Network

- (NSString *)getWiFiIP {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return nil;

    NSString *ip = nil;
    for (struct ifaddrs *iface = interfaces; iface; iface = iface->ifa_next) {
        if (!(iface->ifa_flags & IFF_UP)) continue;
        if (iface->ifa_addr->sa_family != AF_INET) continue;

        NSString *name = [NSString stringWithUTF8String:iface->ifa_name];
        // 优先 en0 (WiFi)
        if ([name hasPrefix:@"en"]) {
            char addrBuf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)iface->ifa_addr)->sin_addr, addrBuf, sizeof(addrBuf));
            ip = [NSString stringWithUTF8String:addrBuf];
            if (![ip hasPrefix:@"127."]) break; // 找到非回环地址即停止
        }
    }
    freeifaddrs(interfaces);
    return ip;
}

@end
