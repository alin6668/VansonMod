#import "VMAppDelegate.h"
#import "VMRootViewController.h"
#import "include/VMDataSession.h"
#import "include/VMLocalization.h"
#import "include/VMLockManager.h"
#import "include/VMMemoryEngine.h"
#import "include/VMPointerManager.h"
#import "src/utils/helpers/VMUIHelper.h"
#import "src/utils/managers/VMImportHandler.h"
#import "src/api/VMAPIRouter.h"
#import <UIKit/UIKit.h>

#define TR(key) ([[VMLocalization shared] localizedString:key])

@interface VMAppDelegate ()
@property(nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
- (void)checkAppReinstallOrUpdate;
- (void)setupDefaultSettingsIfNeeded;
- (void)renewBackgroundTask;
@end

@implementation VMAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

  [[NSUserDefaults standardUserDefaults] registerDefaults:@{
    @"app_theme" : @1,
    @"resultLimit" : @100,
    @"groupRange" : @"0x100",
    @"floatTolerance" : @0.001,
    @"lockInterval" : @0.5,
    @"preventSleep" : @NO
  }];

  [self checkAppReinstallOrUpdate];

  [self setupDefaultSettingsIfNeeded];

  if (@available(iOS 13.0, *)) {
    self.window.backgroundColor = [UIColor systemBackgroundColor];
  } else {
    self.window.backgroundColor = [UIColor systemBackgroundColor];
  }

  NSInteger themeIdx =
      [[NSUserDefaults standardUserDefaults] integerForKey:@"app_theme"];
  if (@available(iOS 13.0, *)) {
    if (themeIdx == 1) {
      self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    } else if (themeIdx == 2) {
      self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    } else {
      self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    }
  }

  self.window.rootViewController = [[VMRootViewController alloc] init];
  [self.window makeKeyAndVisible];

  if (@available(iOS 15.0, *)) {
    UINavigationBarAppearance *appearance =
        [[UINavigationBarAppearance alloc] init];
    [appearance configureWithDefaultBackground];

    [UINavigationBar appearance].standardAppearance = appearance;
    [UINavigationBar appearance].scrollEdgeAppearance = appearance;
    [UINavigationBar appearance].compactAppearance = appearance;

    UITabBarAppearance *tabAppearance = [[UITabBarAppearance alloc] init];
    [tabAppearance configureWithDefaultBackground];
    [UITabBar appearance].standardAppearance = tabAppearance;
    [UITabBar appearance].scrollEdgeAppearance = tabAppearance;
  }

  // ---- 启动 HTTP API 服务器 (供 AUTOGO 远程调用) ----
  [VMAPIRouter registerAllRoutes];
  NSString *apiURL = [VMAPIRouter startServerOnPort:8848];
  if (apiURL) {
      NSLog(@"[VansonMod] ✅ API 服务器已启动: %@", apiURL);
  } else {
      NSLog(@"[VansonMod] ⚠️ API 服务器启动失败，请检查端口 8848 是否被占用");
  }

  // ---- 注册后台 App 刷新 (进入 iOS 设置 > 后台 App 刷新) ----
  // setMinimumBackgroundFetchInterval 在 iOS 13+ 废弃，但仍可正常使用
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [[UIApplication sharedApplication] setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];
#pragma clang diagnostic pop
  NSLog(@"[VansonMod] ✅ 后台 App 刷新已注册");

  return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
  // 启动自续约后台任务，确保关键操作（如内存锁定写入）不被中断
  self.bgTask = UIBackgroundTaskInvalid;
  [self renewBackgroundTask];
  NSLog(@"[VansonMod] 🌙 进入后台，启动后台任务...");
}

// 后台任务自续约 — 到期前重新申请，保持 App 不被挂起
- (void)renewBackgroundTask {
  if (self.bgTask != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
  }
  self.bgTask = [[UIApplication sharedApplication]
      beginBackgroundTaskWithExpirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
      }];
  // 每 150 秒续约 (系统通常给 180 秒)
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_SEC),
      dispatch_get_main_queue(), ^{
        if (self.bgTask != UIBackgroundTaskInvalid) {
          [self renewBackgroundTask];
        }
      });
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
  if (self.bgTask != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
    self.bgTask = UIBackgroundTaskInvalid;
  }
}

// iOS 后台 App 刷新回调 — 系统定期唤醒应用以执行此方法
- (void)application:(UIApplication *)application
    performFetchWithCompletionHandler:
        (void (^)(UIBackgroundFetchResult))completionHandler {
  NSLog(@"[VansonMod] 📡 后台刷新触发，HTTP 服务运行中...");
  completionHandler(UIBackgroundFetchResultNewData);
}

- (void)applicationWillTerminate:(UIApplication *)application {
  [[VMMemoryEngine shared] clearSession];
}

- (void)checkAppReinstallOrUpdate {
  NSUserDefaults *def = [NSUserDefaults standardUserDefaults];

  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];

  NSError *error = nil;
  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:bundlePath
                                                       error:&error];

  if (attrs) {
    
    NSDate *bundleDate = attrs[NSFileModificationDate];
    
    NSString *currentVer =
        [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];

    NSString *currentSignature =
        [NSString stringWithFormat:@"%@_%@", currentVer, bundleDate];

    NSString *savedSignature = [def objectForKey:@"last_install_signature"];

    if (!savedSignature || ![savedSignature isEqualToString:currentSignature]) {
      
      [def setBool:YES forKey:@"has_agreed_disclaimer"]; // 重新安装/更新后自动同意
      
      [def removeObjectForKey:@"fuzzySearchMode"];
      [def removeObjectForKey:@"fastScanEnabled"];

      [def setObject:currentSignature forKey:@"last_install_signature"];

      [def synchronize];
    }
  }
}
- (void)setupDefaultSettingsIfNeeded {
  NSUserDefaults *def = [NSUserDefaults standardUserDefaults];

  if (![def boolForKey:@"has_initialized_config_v2"]) {

    [def setObject:@"0x100000000" forKey:@"startAddr"];
    
    [def setObject:@"0x100" forKey:@"groupRange"];
    [def setObject:@"100" forKey:@"resultLimit"];
    [def setObject:@"0.001" forKey:@"floatTolerance"];

    [def setFloat:0.5f forKey:@"lockInterval"];
    [def setInteger:1 forKey:@"app_theme"];
    [def setObject:@"Auto" forKey:@"user_lang"];

    [def setBool:YES forKey:@"has_initialized_config_v2"];
    [def setBool:YES
          forKey:@"has_agreed_disclaimer"]; // 自动同意免责声明
    [def synchronize];
  }
}

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:
                (NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {

  if (url.isFileURL) {
    return [[VMImportHandler shared] handleImportWithData:nil url:url];
  }

  if ([url.scheme isEqualToString:@"vansonmod"]) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                             resolvingAgainstBaseURL:NO];
    NSArray<NSURLQueryItem *> *queryItems = components.queryItems;
    NSString *dataBase64 = nil;

    for (NSURLQueryItem *item in queryItems) {
      if ([item.name isEqualToString:@"data"])
        dataBase64 = item.value;
    }

    if (dataBase64) {
      NSData *decodedData =
          [[NSData alloc] initWithBase64EncodedString:dataBase64 options:0];
      if (decodedData) {
        
        return [[VMImportHandler shared] handleImportWithData:decodedData
                                                          url:nil];
      }
    }
  }
  return YES;
}

#pragma mark - [新增] 文件直接处理方法

#pragma mark - 过时方法清理

- (void)notifyJumpToTab:(NSInteger)targetTab {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"VM_JUMP_TO_TAB"
                                                        object:nil
                                                      userInfo:@{
                                                        @"tab" : @(targetTab)
                                                      }];
  });
}

- (void)showToast:(NSString *)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController *rootVC = self.window.rootViewController;
    if (@available(iOS 13.0, *)) {
      UIWindowScene *activeScene = nil;
      for (UIScene *scene in
           [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
          activeScene = (UIWindowScene *)scene;
          break;
        }
      }
      if (activeScene) {
        for (UIWindow *window in activeScene.windows) {
          if (window.isKeyWindow) {
            rootVC = window.rootViewController;
            break;
          }
        }
      }
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:nil
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];

    [rootVC presentViewController:alert
                         animated:YES
                       completion:^{
                         dispatch_after(
                             dispatch_time(DISPATCH_TIME_NOW,
                                           (int64_t)(1.5 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), ^{
                               [alert dismissViewControllerAnimated:YES
                                                         completion:nil];
                             });
                       }];
  });
}

@end
