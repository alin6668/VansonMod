//
// VMHTTPServer.mm
// 直接移植自 ios-mcp (witchan/ios-mcp) MCPServer.m 的 HTTP 服务器实现
// 保持与 ios-mcp 完全一致的生命周期管理，只替换路由/解析/响应层
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
@property (nonatomic, strong) dispatch_source_t acceptSource;
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
        _clientQueue = dispatch_queue_create("com.vanson.httpd.client",
                                             DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

// ============================================================================
// startOnPort — 完全匹配 ios-mcp MCPServer.m startOnPort:
//   1. 阻塞 socket (不设 O_NONBLOCK)
//   2. 仅 SO_REUSEADDR
//   3. 不设 TCP KeepAlive 在监听 socket
//   4. accept 错误直接忽略，永不 cancel source
//   5. cancel_handler 仅 close socket
// ============================================================================
- (nullable NSString *)startOnPort:(uint16_t)port {
    if (_running) return self.serverURL;

    // 1. 创建 TCP socket (ios-mcp: 阻塞模式)
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        NSLog(@"[VansonMod API] 创建 socket 失败: %s", strerror(errno));
        return nil;
    }

    // 2. SO_REUSEADDR (ios-mcp: 仅此一项)
    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    // 3. bind
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

    // 4. listen (ios-mcp: backlog=8)
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
    // ios-mcp dispatch_source accept 事件监听 (完全一致)
    // ================================================================
    dispatch_queue_t acceptQueue = dispatch_queue_create(
        "com.vanson.httpd.accept", DISPATCH_QUEUE_CONCURRENT);

    _acceptSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)sock, 0, acceptQueue);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        // ios-mcp: 每次事件 accept 一次, 错误直接忽略
        int client = accept(sock, NULL, NULL);
        if (client >= 0) {
            // 设置客户端超时 (ios-mcp: 10s)
            struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

            dispatch_async(self->_clientQueue, ^{
                @autoreleasepool {
                    [self handleClient:client];
                }
            });
        }
        // ios-mcp 风格: 任何 accept 错误直接忽略, 等待下次事件
        // 不 cancel source, 不设置 _running=NO
    });

    // ios-mcp: cancel_handler 仅关闭 socket
    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(sock);
        NSLog(@"[VansonMod API] accept source 已取消, socket 已关闭");
    });

    dispatch_resume(_acceptSource);

    NSLog(@"[VansonMod API] ✅ HTTP 服务器已启动 (ios-mcp dispatch_source 模式) → %@:%d",
          localIP ?: @"0.0.0.0", port);

    return self.serverURL;
}

// ============================================================================
// stop — 完全匹配 ios-mcp MCPServer.m stop:
//   不等待 cancel_handler, 直接置 nil
// ============================================================================
- (void)stop {
    if (!_running) return;
    _running = NO;

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
        #define HTTP_RECV_BUF_SIZE 65536
        char *buffer = (char *)malloc(HTTP_RECV_BUF_SIZE);
        if (!buffer) {
            close(clientFd);
            return;
        }

        memset(buffer, 0, HTTP_RECV_BUF_SIZE);
        ssize_t bytesRead = recv(clientFd, buffer, HTTP_RECV_BUF_SIZE - 1, 0);
        if (bytesRead <= 0) {
            free(buffer);
            close(clientFd);
            return;
        }

        NSString *rawRequest = [[NSString alloc] initWithBytes:buffer
                                                        length:bytesRead
                                                      encoding:NSUTF8StringEncoding];
        free(buffer);

        if (!rawRequest) {
            [self sendResponse:clientFd code:400 json:@{@"error": @"Invalid UTF-8"}];
            close(clientFd);
            return;
        }

        VMHTTPRequest *req = [self parseRequest:rawRequest];
        if (!req) {
            [self sendResponse:clientFd code:400 json:@{@"error": @"Bad request"}];
            close(clientFd);
            return;
        }

        VMRouteEntry *matched = [self findRouteForMethod:req.method path:req.path];

        if (matched) {
            req.query = [self parseQuery:req.path];

            __block BOOL responded = NO;
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);

            matched.handler(req, ^(int code, NSDictionary *json) {
                [self sendResponse:clientFd code:code json:json];
                responded = YES;
                dispatch_semaphore_signal(sema);
            });

            dispatch_semaphore_wait(sema,
                                    dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

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

    NSArray *reqLine = [lines[0] componentsSeparatedByString:@" "];
    if (reqLine.count < 2) return nil;

    VMHTTPRequest *req = [[VMHTTPRequest alloc] init];
    req.method = [reqLine[0] uppercaseString];
    req.path = reqLine[1];

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSUInteger i = 1;
    for (; i < lines.count; i++) {
        NSString *line = lines[i];
        if (line.length == 0) break;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *key = [[line substringToIndex:colon.location]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *val = [[line substringFromIndex:colon.location + 1]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            headers[key] = val;
        }
    }
    req.headers = headers;

    if (i + 1 < lines.count) {
        req.body = [[lines subarrayWithRange:NSMakeRange(i + 1, lines.count - i - 1)]
                    componentsJoinedByString:@"\r\n"];
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
    NSString *cleanPath = path;
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        cleanPath = [path substringToIndex:q.location];
    }

    for (VMRouteEntry *entry in self.routes) {
        if ([entry.method isEqualToString:method] &&
            [entry.path isEqualToString:cleanPath]) {
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
            NSString *errStr = [NSString stringWithFormat:@"{\"error\":\"%@\"}",
                                err.localizedDescription];
            bodyData = [errStr dataUsingEncoding:NSUTF8StringEncoding];
        }

        NSString *statusText = [self statusText:code];
        NSMutableString *response = [NSMutableString string];
        [response appendFormat:@"HTTP/1.1 %d %@\r\n", code, statusText];
        [response appendString:@"Content-Type: application/json; charset=utf-8\r\n"];
        [response appendString:@"Access-Control-Allow-Origin: *\r\n"];
        [response appendString:@"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"];
        [response appendString:@"Access-Control-Allow-Headers: Content-Type\r\n"];
        [response appendFormat:@"Content-Length: %lu\r\n",
         (unsigned long)bodyData.length];
        [response appendString:@"Connection: close\r\n"];
        [response appendString:@"Server: VansonMod/3.1\r\n"];
        [response appendString:@"\r\n"];

        NSData *headerData = [response dataUsingEncoding:NSUTF8StringEncoding];
        send(clientFd, headerData.bytes, headerData.length, 0);
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
        if ([name hasPrefix:@"en"]) {
            char addrBuf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET,
                      &((struct sockaddr_in *)iface->ifa_addr)->sin_addr,
                      addrBuf, sizeof(addrBuf));
            ip = [NSString stringWithUTF8String:addrBuf];
            if (![ip hasPrefix:@"127."]) break;
        }
    }
    freeifaddrs(interfaces);
    return ip;
}

@end
