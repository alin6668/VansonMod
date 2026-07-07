#import "VMAppDelegate.h"
#import "VMRootViewController.h"
#import "include/VMDataSession.h"
#import "include/VMLocalization.h"
#import "include/VMLockManager.h"
#import "include/VMMemoryEngine.h"
#import "include/VMPointerManager.h"
#import "src/utils/helpers/VMUIHelper.h"
#import "src/utils/managers/VMImportHandler.h"
#import <UIKit/UIKit.h>

#define TR(key) ([[VMLocalization shared] localizedString:key])

@interface VMAppDelegate ()
- (void)checkAppReinstallOrUpdate;
- (void)setupDefaultSettingsIfNeeded;
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

  // HTTP API 由守护进程 vansonmodd 独立提供
  // App 作为 UI 客户端，直接调用 VMMemoryEngine (同进程)，无需启动 HTTP 服务器
  NSLog(@"[VansonMod] ✅ App 已启动 (HTTP API 由守护进程 vansonmodd 提供)");

  return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
  // 守护进程 vansonmodd 负责后台 HTTP 保活，App 本身无需额外处理
  NSLog(@"[VansonMod] 🌙 进入后台 (HTTP 服务由守护进程 vansonmodd 提供)");
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
  // 无需清理音频资源
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
