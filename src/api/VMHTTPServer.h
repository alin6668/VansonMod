//
// VMHTTPServer.h
// VansonMod HTTP API 服务器
//
// 轻量级 POSIX socket HTTP 服务器，零外部依赖
// 启动后监听指定端口，AUTOGO 通过 http://设备IP:端口/ 调用
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// HTTP 请求结构
@interface VMHTTPRequest : NSObject
@property (nonatomic, copy)   NSString *method;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, copy)   NSString *body;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *query;
@end

/// 路由处理器 Block
typedef void (^VMHTTPHandler)(VMHTTPRequest *req,
                              void (^respond)(int code, NSDictionary *json));

/// HTTP 服务器
@interface VMHTTPServer : NSObject

/// 单例
+ (instancetype)shared;

/// 启动服务器
/// @param port 监听端口 (默认 8848)
/// @return 访问 URL，如 "http://192.168.1.100:8848"
- (nullable NSString *)startOnPort:(uint16_t)port;

/// 停止服务器
- (void)stop;

/// 注册路由
/// @param method HTTP 方法 (GET/POST)
/// @param path 路径 (如 /api/status)
/// @param handler 处理回调
- (void)on:(NSString *)method path:(NSString *)path handler:(VMHTTPHandler)handler;

/// 当前服务器 URL (未启动时返回 nil)
@property (nonatomic, copy, readonly, nullable) NSString *serverURL;

/// 服务器是否运行中
@property (nonatomic, assign, readonly) BOOL isRunning;

/// 诊断用: socket fd (-1 表示未启动)
@property (nonatomic, assign, readonly) int serverSocket;

/// 诊断用: accept dispatch source
@property (nonatomic, strong, readonly, nullable) dispatch_source_t acceptSource;

@end

NS_ASSUME_NONNULL_END
