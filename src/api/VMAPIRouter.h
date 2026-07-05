//
// VMAPIRouter.h
// 注册所有 HTTP API 路由，桥接 VMMemoryEngine 与 HTTP 请求
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VMAPIRouter : NSObject

/// 注册所有 /api/* 路由到 VMHTTPServer
+ (void)registerAllRoutes;

/// 启动 API 服务器
/// @param port 监听端口 (默认 8848)
/// @return 访问 URL，失败返回 nil
+ (nullable NSString *)startServerOnPort:(uint16_t)port;

/// 停止服务器
+ (void)stopServer;

/// 当前服务器 URL
+ (nullable NSString *)serverURL;

@end

NS_ASSUME_NONNULL_END
