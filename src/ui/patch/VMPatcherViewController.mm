#import "VMPatcherViewController.h"
#import "../../utils/helpers/VMShareHelper.h"
#import "../../utils/helpers/VMUIHelper.h"
#import "../main/VMLockListViewController.h"
#import "../memory/VMHexEditorViewController.h"
#import "../memory/VMModuleListViewController.h"
#import "../patch/VMRVAManagerCell.h"
#import "include/VMDataSession.h"
#import "include/VMLocalization.h"
#import "include/VMMemoryEngine.h"
#import "include/VMPointerChain.h"
#import "include/VMRVAPatch.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach/mach.h>
#import <objc/runtime.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
extern "C" kern_return_t mach_vm_protect(vm_map_t, mach_vm_address_t,
                                         mach_vm_size_t, boolean_t, vm_prot_t);
extern "C" kern_return_t mach_vm_write(vm_map_t, mach_vm_address_t, vm_offset_t,
                                       mach_msg_type_number_t);
extern "C" int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#define TR(key) ([[VMLocalization shared] localizedString:key])
@interface VMPatcherViewController () <
    UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate,
    UIDocumentPickerDelegate, VMRVAManagerCellDelegate>
@property(nonatomic, assign) BOOL isShowingManager;
@property(nonatomic, assign) BOOL showAllPatches;
@property(nonatomic, strong) UIView *containerPatcher;
@property(nonatomic, strong) UIView *containerManager;
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *mainStack;
@property(nonatomic, strong) VMModuleInfo *selectedModule;
@property(nonatomic, strong) UITextField *moduleField;
@property(nonatomic, strong) UITextField *offsetField;
@property(nonatomic, strong) UILabel *finalAddrLabel;
@property(nonatomic, strong) UILabel *previewInstructionLabel;
@property(nonatomic, strong) UITextField *hexField;
@property(nonatomic, strong) UIButton *patchBtn;
@property(nonatomic, strong) UIButton *saveBtn;
@property(nonatomic, strong) UILabel *procNameLabel;
@property(nonatomic, strong) UILabel *procDetailLabel;
@property(nonatomic, strong) UILabel *moduleDetailLabel;
@property(nonatomic, strong) UITableView *managerTableView;
@property(nonatomic, strong) NSMutableArray<VMRVAPatch *> *filteredPatches;
@property(nonatomic, assign) BOOL isShowingAppFolders;
@property(nonatomic, strong) NSMutableArray<NSString *> *appFolders;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableDictionary *> *bundleIDInfo;
@property(nonatomic, assign) BOOL isFolderMode;
@property(nonatomic, copy) NSString *viewingBundleID;
@property(nonatomic, strong) NSMutableArray *folderList;
@property(nonatomic, strong) NSMutableDictionary *folderMetadata;
@property(nonatomic, copy) NSString *lastAutoNavBundleID;
@property(nonatomic, assign) BOOL manuallyShowFolder;
@property(nonatomic, strong)
    UITextField *activeField; 
@end
@implementation VMPatcherViewController
- (NSString *)rvaFolderNameForBundleID:(NSString *)bundleID {
  if (bundleID.length == 0)
    return @"";
  return [bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
}

- (NSString *)rvaFolderPathForBundleID:(NSString *)bundleID
                                create:(BOOL)create {
  NSString *root = [[VMMemoryEngine shared] rvaRootFolder];
  NSString *folderName = [self rvaFolderNameForBundleID:bundleID];
  NSString *path = [root stringByAppendingPathComponent:folderName];
  if (create) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }
  return path;
}

- (void)migrateLegacyRootRVAFilesIfNeeded {
  NSString *root = [[VMMemoryEngine shared] rvaRootFolder];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *contents = [fm contentsOfDirectoryAtPath:root error:nil];
  for (NSString *fileName in contents) {
    if (![fileName hasSuffix:@".vmrva"])
      continue;

    NSString *filePath = [root stringByAppendingPathComponent:fileName];
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data || data.length < 4)
      continue;

    NSString *bundleID = nil;
    VMDataSession *session = [VMDataSession fromJSONData:data];
    if (session.bundleID.length > 0 &&
        ![session.bundleID isEqualToString:@"com.unknown.app"]) {
      bundleID = session.bundleID;
    }

    if (bundleID.length == 0) {
      for (id item in session.dataItems) {
        if ([item isKindOfClass:[VMRVAPatch class]]) {
          VMRVAPatch *patch = (VMRVAPatch *)item;
          if (patch.bundleID.length > 0 &&
              ![patch.bundleID isEqualToString:@"com.unknown.app"]) {
            bundleID = patch.bundleID;
            break;
          }
        }
      }
    }

    if (bundleID.length == 0) {
      NSDictionary *dict =
          [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([dict isKindOfClass:[NSDictionary class]]) {
        bundleID = dict[@"bundleID"];
      }
    }

    if (bundleID.length == 0)
      continue;

    NSString *appDir = [self rvaFolderPathForBundleID:bundleID create:YES];
    NSString *target = [appDir stringByAppendingPathComponent:fileName];
    if ([fm fileExistsAtPath:target]) {
      NSString *base = [fileName stringByDeletingPathExtension];
      NSString *ext = [fileName pathExtension];
      NSUInteger index = 1;
      do {
        target = [appDir
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@-%lu.%@", base,
                                           (unsigned long)index, ext]];
        index++;
      } while ([fm fileExistsAtPath:target]);
    }
    [fm moveItemAtPath:filePath toPath:target error:nil];
  }
}

- (void)checkAndCleanupFolderForBundleID:(NSString *)bid {
  if (!bid || bid.length == 0)
    return;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *appDir = [self rvaFolderPathForBundleID:bid create:NO];
  BOOL isDir = NO;
  if (![fm fileExistsAtPath:appDir isDirectory:&isDir] || !isDir)
    return;
  NSArray *contents = [fm contentsOfDirectoryAtPath:appDir error:nil];
  NSArray *vmrvaFiles = [contents
      filteredArrayUsingPredicate:
          [NSPredicate predicateWithFormat:@"self ENDSWITH '.vmrva'"]];
  if (vmrvaFiles.count == 0) {
    NSError *err;
    if ([fm removeItemAtPath:appDir error:&err]) {
    }
    if (!self.isFolderMode && [self.viewingBundleID isEqualToString:bid]) {
      [self backToFolderList];
    }
  }
}

- (void)refreshVisibleRVAStates {
  if (!self.isShowingManager)
    return;

  VMMemoryEngine *engine = [VMMemoryEngine shared];
  if (engine.targetTask == MACH_PORT_NULL)
    return;

  NSArray *visiblePaths = [self.managerTableView indexPathsForVisibleRows];

  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableDictionary *updates = [NSMutableDictionary dictionary];

        for (NSIndexPath *indexPath in visiblePaths) {
          if (indexPath.row >= self.filteredPatches.count)
            continue;
          VMRVAPatch *patch = self.filteredPatches[indexPath.row];

          uint64_t base = [engine findModuleBaseAddress:patch.moduleName];
          if (base > 0) {
            uint64_t addr = base + patch.offset;

            NSString *targetHex = [self normalizeHex:patch.patchHex];
            if (targetHex.length == 0)
              continue;

            NSUInteger byteLen = targetHex.length / 2;
            NSData *currentData = [engine readRawMemory:addr length:byteLen];

            NSString *currHex =
                [self normalizeHex:[engine hexStringFromData:currentData]];

            BOOL isRealOn = NO;
            if (currHex && targetHex && [currHex isEqualToString:targetHex]) {
              isRealOn = YES;
            }

            if (patch.isOn != isRealOn) {
              updates[indexPath] = @(isRealOn);
            }
          }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          BOOL needsSave = NO;
          for (NSIndexPath *ip in updates) {
            BOOL realState = [updates[ip] boolValue];

            if (ip.row < self.filteredPatches.count) {
              VMRVAPatch *p = self.filteredPatches[ip.row];
              p.isOn = realState;
              needsSave = YES;

              VMRVAManagerCell *cell =
                  (VMRVAManagerCell *)[self.managerTableView
                      cellForRowAtIndexPath:ip];
              if (cell)
                [cell updateStateVisuals:realState animated:YES];
            }
          }
          if (needsSave)
            [[VMMemoryEngine shared] saveRVAPatches];
        });
      });
}

- (void)viewDidLoad {
  [super viewDidLoad];
  if (@available(iOS 11.0, *)) {
    self.navigationItem.largeTitleDisplayMode =
        UINavigationItemLargeTitleDisplayModeNever;
  }
  self.title = TR(@"Patch_Title");
  self.tabBarItem.title = TR(@"Tab_Patch");
  self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
  self.containerPatcher = [[UIView alloc] init];
  self.containerPatcher.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.containerPatcher];
  self.containerManager = [[UIView alloc] init];
  self.containerManager.translatesAutoresizingMaskIntoConstraints = NO;
  self.containerManager.hidden = YES;
  [self.view addSubview:self.containerManager];
  [NSLayoutConstraint activateConstraints:@[
    [self.containerPatcher.topAnchor
        constraintEqualToAnchor:self.view.topAnchor],
    [self.containerPatcher.bottomAnchor
        constraintEqualToAnchor:self.view.bottomAnchor],
    [self.containerPatcher.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor],
    [self.containerPatcher.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    [self.containerManager.topAnchor
        constraintEqualToAnchor:self.view.topAnchor],
    [self.containerManager.bottomAnchor
        constraintEqualToAnchor:self.view.bottomAnchor],
    [self.containerManager.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor],
    [self.containerManager.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor]
  ]];
  [self setupPatcherUI];
  [self setupManagerUI];

  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(dismissKeyboard)];
  tap.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:tap];

  UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(handleManagerLongPress:)];
  [self.managerTableView addGestureRecognizer:lp];

  if ([VMMemoryEngine shared].targetTask != MACH_PORT_NULL) {
    [self loadModules];
  }

  self.isShowingManager = NO;
  self.showAllPatches = YES;
  self.isShowingAppFolders = YES;
  self.folderList = [NSMutableArray array];
  self.folderMetadata = [NSMutableDictionary dictionary];
  self.isFolderMode = YES;
  [self updateNavBarButtons];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(resetState)
             name:@"VMProcessChangedNotification"
           object:nil];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(onImportNotification)
             name:@"VM_LockItemAdded"
           object:nil];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(keyboardWillShow:)
             name:UIKeyboardWillShowNotification
           object:nil];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(keyboardWillHide:)
             name:UIKeyboardWillHideNotification
           object:nil];

  [self.view setNeedsLayout];
  [self.view layoutIfNeeded];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateNavBarButtons {
  self.navigationItem.leftBarButtonItems = nil;
  self.navigationItem.rightBarButtonItems = nil;
  self.navigationItem.titleView = nil;
  if (!self.isShowingManager) {
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(loadModules)];
    self.navigationItem.title = TR(@"Patch_Title");
  } else {
    if (self.managerTableView.isEditing) {
      UIBarButtonItem *cancelBtn =
          [[UIBarButtonItem alloc] initWithTitle:TR(@"Btn_Cancel")
                                           style:UIBarButtonItemStylePlain
                                          target:self
                                          action:@selector(exitBatchMode)];
      UIBarButtonItem *selAllBtn =
          [[UIBarButtonItem alloc] initWithTitle:TR(@"Batch_Sel_All")
                                           style:UIBarButtonItemStylePlain
                                          target:self
                                          action:@selector(batchSelectAll)];
      self.navigationItem.leftBarButtonItems = @[ cancelBtn, selAllBtn ];
      self.navigationItem.rightBarButtonItem =
          [[UIBarButtonItem alloc] initWithTitle:TR(@"Act_Export")
                                           style:UIBarButtonItemStyleDone
                                          target:self
                                          action:@selector(performBatchShare)];
      UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
      [delBtn setTitle:TR(@"Act_Delete") forState:UIControlStateNormal];
      [delBtn setTitleColor:[UIColor systemRedColor]
                   forState:UIControlStateNormal];
      [delBtn addTarget:self
                    action:@selector(batchDelete)
          forControlEvents:UIControlEventTouchUpInside];
      self.navigationItem.titleView = delBtn;
    } else {
      if (self.isFolderMode) {
        UIBarButtonItem *backBtn = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(toggleViewMode)];
        self.navigationItem.leftBarButtonItem = backBtn;
        UIBarButtonItem *importBtn = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(importPatches)];
        self.navigationItem.rightBarButtonItem = importBtn;
        self.navigationItem.title = TR(@"Patch_Seg_Manager");
      } else {
        UIBarButtonItem *listBtn = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"list.bullet"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(backToFolderList)];
        self.navigationItem.leftBarButtonItem = listBtn;
        UIBarButtonItem *importBtn = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(importPatches)];
        self.navigationItem.rightBarButtonItem = importBtn;
        NSString *name = self.folderMetadata[self.viewingBundleID][@"name"];
        self.navigationItem.title = name ?: self.viewingBundleID;
      }
    }
  }
}

- (void)importPatches {
  NSMutableArray *types = [NSMutableArray array];
  if (@available(iOS 14.0, *)) {
    UTType *t1 = [UTType typeWithFilenameExtension:@"vmrva"];
    if (t1)
      [types addObject:t1];

    [types addObject:UTTypeData];

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                    asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray *typeStrs = @[ @"com.vanson.vmrva", @"vmrva", @"public.data" ];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initWithDocumentTypes:typeStrs
                           inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
#pragma clang diagnostic pop
  }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (urls.count == 0)
    return;
  NSURL *url = urls.firstObject;

  BOOL accessing = [url startAccessingSecurityScopedResource];

  NSError *readErr;
  NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readErr];

  if (!data) {
    if (accessing)
      [url stopAccessingSecurityScopedResource];
    [self showToast:[NSString stringWithFormat:@"%@: %@", TR(@"Err_File_Read"),
                                               readErr.localizedDescription]];
    return;
  }

  VMDataSession *session = [VMDataSession fromJSONData:data];

  if (accessing)
    [url stopAccessingSecurityScopedResource];
  BOOL hasRVAPatch = NO;
  for (id item in session.dataItems) {
    if ([item isKindOfClass:[VMRVAPatch class]]) {
      hasRVAPatch = YES;
      break;
    }
  }
  if (!session || !session.dataItems || !hasRVAPatch) {
    [self showToast:TR(@"Err_File_Format")];
    return;
  }
  NSMutableArray *importedItems =
      [NSMutableArray arrayWithArray:session.dataItems];
  NSString *importedBundleID = session.bundleID;
  if ([importedBundleID isEqualToString:@"com.unknown.app"]) {
    importedBundleID = nil;
  }
  if (importedBundleID.length == 0) {
    for (id item in importedItems) {
      if ([item isKindOfClass:[VMRVAPatch class]]) {
        VMRVAPatch *patch = (VMRVAPatch *)item;
        if (patch.bundleID.length > 0 &&
            ![patch.bundleID isEqualToString:@"com.unknown.app"]) {
          importedBundleID = patch.bundleID;
          break;
        }
      }
    }
  }
  if (importedItems.count > 0 && importedBundleID) {
    int rvaCount = 0;
    for (id item in importedItems) {
      if ([item isKindOfClass:[VMRVAPatch class]]) {
        VMRVAPatch *p = (VMRVAPatch *)item;
        p.isOn = NO;
        p.isImported = YES;
        p.bundleID = importedBundleID;
        NSString *appDir = [self rvaFolderPathForBundleID:importedBundleID
                                                   create:YES];

        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"yyMMdd_HHmmss_SSS"];
        NSString *timestamp = [fmt stringFromDate:[NSDate date]];
        NSString *fileName = [NSString stringWithFormat:@"%@.vmrva", timestamp];
        NSString *filePath = [appDir stringByAppendingPathComponent:fileName];

        p.fileName = fileName;

        VMDataSession *singleSession =
            [VMDataSession sessionWithData:@[ p ]
                                  bundleID:importedBundleID
                                  dataType:@"rva"];
        NSData *patchData = [singleSession toJSONData];
        if (patchData) {
          [patchData writeToFile:filePath atomically:YES];
        }

        rvaCount++;
      }
    }
    if (rvaCount > 0) {
      [[VMMemoryEngine shared] loadRVAPatches];

      if (self.isShowingManager)
        [self reloadPatchData];
      [self showToast:[NSString stringWithFormat:TR(@"Patch_Import_Success"),
                                                 rvaCount]];
    } else {
      [self showToast:TR(@"Msg_Saved")];
    }
  } else {
    [self showToast:TR(@"Err_File_Format")];
  }
}

- (void)checkSmartNavigation {
  NSString *currBid = [VMMemoryEngine shared].currentBundleID;
  if (currBid && ![currBid isEqualToString:self.lastAutoNavBundleID]) {
    self.manuallyShowFolder = NO;
    self.lastAutoNavBundleID = currBid;
  }
  if (currBid && currBid.length > 0 && !self.manuallyShowFolder) {
    self.viewingBundleID = currBid;
    self.isFolderMode = NO;
  } else {
  }
  [self reloadPatchData];
  [self updateNavBarButtons];
}

- (void)reloadPatchData {
  [self migrateLegacyRootRVAFilesIfNeeded];
  if (!self.filteredPatches) {
    self.filteredPatches = [NSMutableArray array];
  }
  [self.filteredPatches removeAllObjects];
  if (self.isFolderMode) {
    NSString *root = [VMMemoryEngine shared].rvaRootFolder;
    NSArray *contents =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root
                                                            error:nil];
    [self.folderList removeAllObjects];
    [self.folderMetadata removeAllObjects];
    for (NSString *name in contents) {
      if ([name hasPrefix:@"."])
        continue;
      NSString *fullPath = [root stringByAppendingPathComponent:name];
      BOOL isDir = NO;
      [[NSFileManager defaultManager] fileExistsAtPath:fullPath
                                           isDirectory:&isDir];
      if (isDir) {
        [self.folderList addObject:name];
        NSArray *files =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fullPath
                                                                error:nil];
        NSUInteger count = 0;
        NSString *appName = name;
        NSString *ver = @"";
        for (NSString *f in files) {
          if ([f hasSuffix:@".vmrva"]) {
            NSData *d = [NSData
                dataWithContentsOfFile:[fullPath
                                           stringByAppendingPathComponent:f]];
            if (!d || d.length < 4) continue;
            VMDataSession *s = [VMDataSession fromJSONData:d];
            if (s && s.dataItems.count > 0) {
              count += s.dataItems.count;
              if (s.appName)
                appName = s.appName;
              if (s.appVersion)
                ver = s.appVersion;
            } else {
              
              count++;
            }
          }
        }
        self.folderMetadata[name] =
            @{@"name" : appName, @"ver" : ver, @"count" : @(count)};
      }
    }
    [self.folderList
        sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  } else {
    if (!self.filteredPatches)
      self.filteredPatches = [NSMutableArray array];
    [self.filteredPatches removeAllObjects];
    NSString *path = [self rvaFolderPathForBundleID:self.viewingBundleID
                                             create:NO];
    NSArray *files =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path
                                                            error:nil];
    for (NSString *f in files) {
      if ([f hasSuffix:@".vmrva"]) {
        NSData *d = [NSData
            dataWithContentsOfFile:[path stringByAppendingPathComponent:f]];
        if (!d || d.length < 4) continue;

        VMDataSession *s = [VMDataSession fromJSONData:d];
        if (s && s.dataItems.count > 0) {
          for (VMRVAPatch *p in s.dataItems) {
            p.fileName = f;
            p.bundleID = self.viewingBundleID;
            [self.filteredPatches addObject:p];
          }
          continue;
        }

        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (!dict) continue;
        VMRVAPatch *p = [VMRVAPatch fromDictionary:dict];
        if (p) {
          p.fileName = f;
          p.bundleID = self.viewingBundleID;
          [self.filteredPatches addObject:p];
        }
      }
    }
    [VMMemoryEngine shared].rvaPatches = [self.filteredPatches mutableCopy];
  }
  [self.managerTableView reloadData];
}

- (void)toggleViewMode {
  self.isShowingManager = !self.isShowingManager;
  [UIView transitionWithView:self.view
                    duration:0.3
                     options:UIViewAnimationOptionTransitionCrossDissolve
                  animations:^{
                    self.containerPatcher.hidden = self.isShowingManager;
                    self.containerManager.hidden = !self.isShowingManager;
                  }
                  completion:nil];

  [self updateNavBarButtons];
  if (self.isShowingManager)
    [self reloadPatchData];
}

- (void)toggleShowAll {
  self.showAllPatches = !self.showAllPatches;
  [self updateNavBarButtons];
  [self reloadPatchData];
}

- (void)backToFolderList {
  self.isFolderMode = YES;
  self.viewingBundleID = nil;
  self.manuallyShowFolder = YES;
  [self reloadPatchData];
  [self updateNavBarButtons];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (self.isShowingManager) {
    [self checkSmartNavigation];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [self refreshVisibleRVAStates];
        });
  }
  if (!self.selectedModule &&
      [VMMemoryEngine shared].targetTask != MACH_PORT_NULL) {
    [self loadModules];
  }
}

- (void)setupPatcherUI {
  
  self.scrollView = [[UIScrollView alloc] init];
  self.scrollView.translatesAutoresizingMaskIntoConstraints =
      NO; 
  self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
  self.scrollView.alwaysBounceVertical =
      YES; 
  [self.containerPatcher addSubview:self.scrollView];

  [NSLayoutConstraint activateConstraints:@[
    [self.scrollView.topAnchor
        constraintEqualToAnchor:self.containerPatcher.topAnchor],
    [self.scrollView.leadingAnchor
        constraintEqualToAnchor:self.containerPatcher.leadingAnchor],
    [self.scrollView.trailingAnchor
        constraintEqualToAnchor:self.containerPatcher.trailingAnchor],
    [self.scrollView.bottomAnchor
        constraintEqualToAnchor:self.containerPatcher.bottomAnchor]
  ]];

  self.mainStack = [[UIStackView alloc] init];
  self.mainStack.axis = UILayoutConstraintAxisVertical;
  self.mainStack.spacing = 20;
  self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.scrollView addSubview:self.mainStack];

  UILayoutGuide *contentGuide = self.scrollView.contentLayoutGuide;
  UILayoutGuide *frameGuide = self.scrollView.frameLayoutGuide;

  [NSLayoutConstraint activateConstraints:@[
    
    [self.mainStack.topAnchor constraintEqualToAnchor:contentGuide.topAnchor
                                             constant:15],
    [self.mainStack.leadingAnchor
        constraintEqualToAnchor:contentGuide.leadingAnchor
                       constant:16],
    [self.mainStack.trailingAnchor
        constraintEqualToAnchor:contentGuide.trailingAnchor
                       constant:-16],
    [self.mainStack.bottomAnchor
        constraintEqualToAnchor:contentGuide.bottomAnchor
                       constant:-40],

    [self.mainStack.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor
                                               constant:-32]
  ]];

  [self setupBinaryInfoSection];
  [self setupTargetSection];
  [self setupValueSection];
  [self setupActionButtons];
  [self setupPresetsSection];
}

- (void)setupBinaryInfoSection {
  UIView *card = [self createCardView];
  UIStackView *stack = [self createCardStack];
  [card addSubview:stack];
  [self pinStackToCard:stack card:card];
  [stack
      addArrangedSubview:[self createSectionTitle:TR(@"RVA_Section_Process")]];
  self.procNameLabel =
      [self createLabel:TR(@"Patch_Wait_Attach")
                   font:[UIFont systemFontOfSize:16 weight:UIFontWeightBold]
                  color:[UIColor labelColor]];
  [stack addArrangedSubview:self.procNameLabel];
  self.procDetailLabel =
      [self createLabel:@"Base: - | Size: -"
                   font:[UIFont monospacedSystemFontOfSize:12
                                                    weight:UIFontWeightRegular]
                  color:[UIColor secondaryLabelColor]];
  [stack addArrangedSubview:self.procDetailLabel];
  [self.mainStack addArrangedSubview:card];
}

- (void)setupTargetSection {
  UIView *card = [self createCardView];
  UIStackView *stack = [self createCardStack];
  [card addSubview:stack];
  [self pinStackToCard:stack card:card];
  [stack
      addArrangedSubview:[self createSectionTitle:TR(@"RVA_Section_Target")]];
  self.moduleField = [self createTextField:TR(@"RVA_Select_Hint")];
  self.moduleField.text = TR(@"RVA_Select_Hint");
  self.moduleField.textColor = [UIColor systemOrangeColor];
  UITapGestureRecognizer *copyTap =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(copyModuleName)];
  [self.moduleField addGestureRecognizer:copyTap];
  [self addSelectButtonToField:self.moduleField
                        action:@selector(openModuleSelector)];
  self.moduleField.delegate = self;
  [stack addArrangedSubview:self.moduleField];
  self.moduleDetailLabel =
      [self createLabel:@"Select a framework to see details"
                   font:[UIFont systemFontOfSize:11 weight:UIFontWeightRegular]
                  color:[UIColor systemGrayColor]];
  self.moduleDetailLabel.numberOfLines = 2;
  [stack addArrangedSubview:self.moduleDetailLabel];
  self.offsetField = [self createTextField:@"Offset (e.g. 0x1002A)"];
  UILabel *prefix = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
  prefix.text = @" 0x";
  prefix.textColor = [UIColor secondaryLabelColor];
  prefix.font = [UIFont monospacedSystemFontOfSize:14
                                            weight:UIFontWeightRegular];
  self.offsetField.leftView = prefix;
  self.offsetField.leftViewMode = UITextFieldViewModeAlways;
  self.offsetField.delegate = self;
  [self.offsetField addTarget:self
                       action:@selector(calculateFinalAddress)
             forControlEvents:UIControlEventEditingChanged];
  [stack addArrangedSubview:self.offsetField];
  [self.mainStack addArrangedSubview:card];
}

- (void)setupValueSection {
  UIView *card = [self createCardView];
  UIStackView *stack = [self createCardStack];
  [card addSubview:stack];
  [self pinStackToCard:stack card:card];
  [stack addArrangedSubview:[self createSectionTitle:TR(@"RVA_Section_Value")]];
  self.finalAddrLabel = [[UILabel alloc] init];
  self.finalAddrLabel.text = @"---";
  self.finalAddrLabel.font =
      [UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightBold];
  self.finalAddrLabel.textColor = [UIColor systemBlueColor];
  self.finalAddrLabel.textAlignment = NSTextAlignmentCenter;
  self.finalAddrLabel.userInteractionEnabled = YES;
  [self.finalAddrLabel
      addGestureRecognizer:[[UITapGestureRecognizer alloc]
                               initWithTarget:self
                                       action:@selector
                                       (showFinalAddressOptions)]];
  UIView *bgResult = [[UIView alloc] init];
  bgResult.backgroundColor = [UIColor systemFillColor];
  bgResult.layer.cornerRadius = 8;
  [bgResult addSubview:self.finalAddrLabel];
  self.finalAddrLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[
    [self.finalAddrLabel.centerXAnchor
        constraintEqualToAnchor:bgResult.centerXAnchor],
    [self.finalAddrLabel.centerYAnchor
        constraintEqualToAnchor:bgResult.centerYAnchor],
    [bgResult.heightAnchor constraintEqualToConstant:44]
  ]];
  [stack addArrangedSubview:bgResult];
  self.hexField = [self createTextField:@"E0 03 1F 2A"];
  self.hexField.autocapitalizationType =
      UITextAutocapitalizationTypeAllCharacters;
  self.hexField.delegate = self;
  [self addDoneToolBar:self.hexField];
  [stack addArrangedSubview:self.hexField];
  self.previewInstructionLabel =
      [self createLabel:TR(@"RVA_Waiting_Input")
                   font:[UIFont italicSystemFontOfSize:12]
                  color:[UIColor systemGrayColor]];
  self.previewInstructionLabel.textAlignment = NSTextAlignmentRight;
  [stack addArrangedSubview:self.previewInstructionLabel];
  [self.mainStack addArrangedSubview:card];
}

- (void)setupPresetsSection {
  UIView *card = [self createCardView];
  UIStackView *stack = [self createCardStack];
  [card addSubview:stack];
  [self pinStackToCard:stack card:card];
  [stack
      addArrangedSubview:[self createSectionTitle:TR(@"RVA_Section_Presets")]];
  UIScrollView *hScroll = [[UIScrollView alloc] init];
  hScroll.showsHorizontalScrollIndicator = NO;
  hScroll.translatesAutoresizingMaskIntoConstraints = NO;
  [hScroll.heightAnchor constraintEqualToConstant:50].active = YES;
  UIStackView *hStack = [[UIStackView alloc] init];
  hStack.axis = UILayoutConstraintAxisHorizontal;
  hStack.spacing = 10;
  hStack.translatesAutoresizingMaskIntoConstraints = NO;
  [hScroll addSubview:hStack];
  [NSLayoutConstraint activateConstraints:@[
    [hStack.topAnchor constraintEqualToAnchor:hScroll.topAnchor],
    [hStack.bottomAnchor constraintEqualToAnchor:hScroll.bottomAnchor],
    [hStack.leadingAnchor constraintEqualToAnchor:hScroll.leadingAnchor],
    [hStack.trailingAnchor constraintEqualToAnchor:hScroll.trailingAnchor],
    [hStack.heightAnchor constraintEqualToAnchor:hScroll.heightAnchor]
  ]];
  NSArray *presets = @[
    @{@"t" : @"RET (Void)", @"h" : @"C0035FD6", @"d" : @"RET (Void)"},
    @{@"t" : @"RET True", @"h" : @"20008052C0035FD6", @"d" : @"MOV W0,#1; RET"},
    @{
      @"t" : @"RET False",
      @"h" : @"00008052C0035FD6",
      @"d" : @"MOV W0,#0; RET"
    },
    @{
      @"t" : @"RET 100",
      @"h" : @"80328052C0035FD6",
      @"d" : @"MOV W0,#100; RET"
    },
    @{
      @"t" : @"RET 9999",
      @"h" : @"E0E18452C0035FD6",
      @"d" : @"MOV W0,#9999; RET"
    },
    @{@"t" : @"RET -1", @"h" : @"00008012C0035FD6", @"d" : @"MOV W0,#-1; RET"},
    @{@"t" : @"NOP", @"h" : @"1F2003D5", @"d" : @"NOP"},
    @{@"t" : @"ZERO", @"h" : @"00008052", @"d" : @"MOV W0,#0 (No RET)"}
  ];
  for (NSDictionary *data in presets) {
    UIButton *btn = [self createPresetPill:data[@"t"]
                                       hex:data[@"h"]
                                      desc:data[@"d"]];
    [hStack addArrangedSubview:btn];
  }
  [stack addArrangedSubview:hScroll];
  [self.mainStack addArrangedSubview:card];
}

- (void)setupActionButtons {
  UIStackView *btnStack = [[UIStackView alloc] init];
  btnStack.axis = UILayoutConstraintAxisHorizontal;
  btnStack.spacing = 15;
  btnStack.distribution = UIStackViewDistributionFillEqually;
  self.saveBtn = [self createStandardButton:TR(@"Btn_Save")
                                      color:[UIColor systemOrangeColor]
                                     action:@selector(savePatchAction)];
  self.patchBtn = [self createStandardButton:TR(@"Patch_Btn")
                                       color:[UIColor systemRedColor]
                                      action:@selector(doPatch)];
  [btnStack addArrangedSubview:self.saveBtn];
  [btnStack addArrangedSubview:self.patchBtn];
  [btnStack.heightAnchor constraintEqualToConstant:44].active = YES;
  [self.mainStack addArrangedSubview:btnStack];
}

- (UILabel *)createLabel:(NSString *)text
                    font:(UIFont *)font
                   color:(UIColor *)color {
  UILabel *l = [UILabel new];
  l.text = text;
  l.font = font;
  l.textColor = color;
  l.translatesAutoresizingMaskIntoConstraints = NO;
  return l;
}

- (UIView *)createCardView {
  UIView *v = [[UIView alloc] init];
  v.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
  v.layer.cornerRadius = 12;
  return v;
}

- (UIStackView *)createCardStack {
  UIStackView *s = [[UIStackView alloc] init];
  s.axis = UILayoutConstraintAxisVertical;
  s.spacing = 12;
  s.translatesAutoresizingMaskIntoConstraints = NO;
  return s;
}

- (void)pinStackToCard:(UIStackView *)stack card:(UIView *)card {
  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:15],
    [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-15],
    [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                        constant:15],
    [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor
                                         constant:-15]
  ]];
}

- (UILabel *)createSectionTitle:(NSString *)text {
  UILabel *l = [[UILabel alloc] init];
  l.text = text;
  l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
  l.textColor = [UIColor systemGrayColor];
  return l;
}

- (UIButton *)createPresetPill:(NSString *)title
                           hex:(NSString *)hex
                          desc:(NSString *)desc {
  UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
  [btn setTitle:title forState:UIControlStateNormal];
  [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
  btn.backgroundColor = [UIColor systemFillColor];
  btn.layer.cornerRadius = 8;
  btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
  btn.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
  btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
  btn.accessibilityValue = hex;
  btn.accessibilityHint = desc;
  [btn addTarget:self
                action:@selector(presetTapped:)
      forControlEvents:UIControlEventTouchUpInside];
  return btn;
}

- (UIButton *)createStandardButton:(NSString *)title
                             color:(UIColor *)color
                            action:(SEL)sel {
  UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
  [btn setTitle:title forState:UIControlStateNormal];
  [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  btn.backgroundColor = color;
  btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
  btn.layer.cornerRadius = 8;
  [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
  return btn;
}

- (void)dismissKeyboard {
  [self.view endEditing:YES];
}

- (void)addDoneToolBar:(UITextField *)tf {
  UIToolbar *tb = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
  UIBarButtonItem *space = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                           target:nil
                           action:nil];
  UIBarButtonItem *done = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(dismissKeyboard)];
  tb.items = @[ space, done ];
  tf.inputAccessoryView = tb;
}

- (UITextField *)createTextField:(NSString *)ph {
  UITextField *tf = [UITextField new];
  tf.borderStyle = UITextBorderStyleRoundedRect;
  tf.placeholder = ph;
  tf.font = [UIFont fontWithName:@"Menlo" size:14];
  tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
  tf.keyboardType = UIKeyboardTypeASCIICapable;
  [tf.heightAnchor constraintEqualToConstant:40].active = YES;
  return tf;
}

- (void)addSelectButtonToField:(UITextField *)tf action:(SEL)sel {
  UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
  [btn setTitle:TR(@"Btn_Select_Fwk") forState:UIControlStateNormal];
  [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  btn.backgroundColor = [UIColor systemBlueColor];
  btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
  btn.layer.cornerRadius = 6;

  btn.frame = CGRectMake(0, 0, 60, 28);

  UIView *rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 68, 28)];
  [rightView addSubview:btn];
  btn.frame = CGRectMake(4, 0, 60, 28);

  [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];

  tf.rightView = rightView;
  tf.rightViewMode = UITextFieldViewModeAlways;
}

- (void)copyModuleName {
  if (self.selectedModule) {
    [[UIPasteboard generalPasteboard] setString:self.selectedModule.name];
    [self showToast:TR(@"Msg_Copy_Success")];
    self.moduleField.alpha = 0.5;
    [UIView animateWithDuration:0.2
                     animations:^{
                       self.moduleField.alpha = 1.0;
                     }];
  }
}

- (void)openModuleSelector {
  VMModuleListViewController *vc = [[VMModuleListViewController alloc] init];
  __weak VMPatcherViewController *weakSelf = self;
  vc.selectionHandler = ^(VMModuleInfo *_Nullable selected) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf handleModuleSelection:selected];
    });
  };
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)handleModuleSelection:(VMModuleInfo *)module {
  self.selectedModule = module;
  if (module) {
    self.moduleField.text = module.name;
    self.moduleField.textColor = [UIColor labelColor];
    NSString *sizeStr = [NSByteCountFormatter
        stringFromByteCount:module.size
                 countStyle:NSByteCountFormatterCountStyleMemory];
    self.moduleDetailLabel.text =
        [NSString stringWithFormat:@"Base: 0x%llX\nSize: %@",
                                   module.loadAddress, sizeStr];
    self.moduleDetailLabel.textColor = [UIColor secondaryLabelColor];
    [self calculateFinalAddress];
  } else {
    self.moduleField.text = TR(@"RVA_Select_Hint");
    self.moduleField.textColor = [UIColor systemOrangeColor];
    self.moduleDetailLabel.text = @"-";
    self.finalAddrLabel.text = @"---";
  }
}

- (void)loadModules {
  if ([VMMemoryEngine shared].targetTask == MACH_PORT_NULL)
    return;
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint64_t mainAddr = [VMMemoryEngine shared].mainModuleAddress;
        NSString *procName = [VMMemoryEngine shared].currentProcessName;
        NSString *binaryName = procName;
        uint64_t size = 0;
        NSArray *mods = [[VMMemoryEngine shared] loadRemoteModules];
        for (VMModuleInfo *m in mods) {
          if (m.loadAddress == mainAddr) {
            size = m.size;
            binaryName = m.name;
            break;
          }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          self.procNameLabel.text = binaryName ?: @"Unknown Process";
          NSString *sizeStr = [NSByteCountFormatter
              stringFromByteCount:size
                       countStyle:NSByteCountFormatterCountStyleMemory];
          self.procDetailLabel.text = [NSString
              stringWithFormat:@"%@: 0x%llX  |  Size: %@",
                               TR(@"RVA_Label_Main_Base"), mainAddr, sizeStr];
          if (mainAddr > 0 && binaryName && !self.selectedModule) {
            VMModuleInfo *mainMod = [[VMModuleInfo alloc] init];
            mainMod.name = binaryName;
            mainMod.loadAddress = mainAddr;
            mainMod.size = size;
            [self handleModuleSelection:mainMod];
          }
        });
      });
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
  if (textField == self.moduleField) {
    [self copyModuleName];
    return NO;
  }
  self.activeField = textField;
  return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
  self.activeField = nil;
}

- (void)calculateFinalAddress {
  if (!self.selectedModule)
    return;
  NSString *s =
      [self.offsetField.text stringByReplacingOccurrencesOfString:@"0x"
                                                       withString:@""];
  uint64_t o = strtoull(s.UTF8String, NULL, 16);
  self.finalAddrLabel.text = [NSString
      stringWithFormat:@"= 0x%llX", self.selectedModule.loadAddress + o];
}

- (void)setupManagerUI {
  self.managerTableView =
      [[UITableView alloc] initWithFrame:CGRectZero
                                   style:UITableViewStyleInsetGrouped];
  self.managerTableView.translatesAutoresizingMaskIntoConstraints = NO;
  self.managerTableView.delegate = self;
  self.managerTableView.dataSource = self;
  self.managerTableView.allowsMultipleSelectionDuringEditing = YES;
  UIRefreshControl *ref = [[UIRefreshControl alloc] init];
  ref.attributedTitle =
      [[NSAttributedString alloc] initWithString:TR(@"Pull_Idle")];
  [ref addTarget:self
                action:@selector(handleManagerRefresh:)
      forControlEvents:UIControlEventValueChanged];
  self.managerTableView.refreshControl = ref;
  [self.containerManager addSubview:self.managerTableView];
  [NSLayoutConstraint activateConstraints:@[
    [self.managerTableView.topAnchor
        constraintEqualToAnchor:self.containerManager.topAnchor],
    [self.managerTableView.leadingAnchor
        constraintEqualToAnchor:self.containerManager.leadingAnchor],
    [self.managerTableView.trailingAnchor
        constraintEqualToAnchor:self.containerManager.trailingAnchor],
    [self.managerTableView.bottomAnchor
        constraintEqualToAnchor:self.containerManager.bottomAnchor]
  ]];
  [VMUIHelper addFixedFooterTo:self forTableView:self.managerTableView];
}

- (void)showFinalAddressOptions {
  if ([self.finalAddrLabel.text isEqualToString:@"---"])
    return;
  NSString *addrStr =
      [self.finalAddrLabel.text stringByReplacingOccurrencesOfString:@"= "
                                                          withString:@""];
  uint64_t address = strtoull([addrStr UTF8String], NULL, 16);
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TR(@"Pop_Options")
                       message:addrStr
                preferredStyle:UIAlertControllerStyleActionSheet];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Action_Copy_Addr")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [[UIPasteboard generalPasteboard]
                                     setString:addrStr];
                                 [self showToast:TR(@"Msg_Copy_Success")];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Action_Copy_Offset")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [[UIPasteboard generalPasteboard]
                                     setString:self.offsetField.text];
                                 [self showToast:TR(@"Msg_Copy_Success")];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Action_Goto_Hex")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 VMHexEditorViewController *vc =
                                     [VMHexEditorViewController new];
                                 vc.address = address;
                                 [self.navigationController
                                     pushViewController:vc
                                               animated:YES];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Mod_Menu_Fav")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self addToFavorites:address];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Mod_Menu_Lock")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self addToLock:address];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Mod_Menu_Value")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self browseMemoryAsValue:address];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Mod_Menu_Hex")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self browseMemoryAsHex:address];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Act_Search_Ptr")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self searchPointerForAddress:address];
                               }]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:TR(@"Tab_Sig_Search")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self scanSignatureFromAddress:address];
                               }]];
  [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
    alert.popoverPresentationController.sourceView = self.finalAddrLabel;
    alert.popoverPresentationController.sourceRect = self.finalAddrLabel.bounds;
  }
  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Action Handlers
- (void)addToFavorites:(uint64_t)address {
  [self showToast:@"Added to Favorites"];
}

- (void)addToLock:(uint64_t)address {
  [self showToast:@"Added to Lock List"];
}

- (void)browseMemoryAsValue:(uint64_t)address {
  [self showToast:@"Browse Memory (Value)"];
}

- (void)browseMemoryAsHex:(uint64_t)address {
  [self showToast:@"Browse Memory (Hex)"];
}

- (void)searchPointerForAddress:(uint64_t)address {
  [self showToast:@"Search Pointer"];
}

- (void)scanSignatureFromAddress:(uint64_t)address {
  [self showToast:@"Scan Signature"];
}

- (void)showToast:(NSString *)msg {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:nil
                                          message:msg
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:alert animated:YES completion:nil];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
      });
}

- (void)presetTapped:(UIButton *)sender {
  NSString *hex = sender.accessibilityValue;
  NSString *desc = sender.accessibilityHint;
  if (hex) {
    NSMutableString *formatted = [NSMutableString string];
    for (int i = 0; i < hex.length; i += 2) {
      [formatted appendString:[hex substringWithRange:NSMakeRange(i, 2)]];
      if (i < hex.length - 2)
        [formatted appendString:@" "];
    }
    self.hexField.text = formatted;
    self.previewInstructionLabel.text =
        [NSString stringWithFormat:@"Set: %@", desc];
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
  }
}

- (void)doPatch {
  if (!self.selectedModule) {
    [self showToast:TR(@"Patch_Select_Msg")];
    return;
  }
  BOOL isJailbroken = NO;
  NSArray *jbPaths = @[
    @"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
    @"/var/binpack"
  ];
  for (NSString *p in jbPaths)
    if ([[NSFileManager defaultManager] fileExistsAtPath:p])
      isJailbroken = YES;

  static BOOL alertShown = NO;
  if (!isJailbroken && !alertShown) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:TR(@"Patch_JB_Title")
                         message:TR(@"Patch_JB_Msg")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert
        addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Risk")
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
                                           alertShown = YES;
                                           [self performPatchLogic];
                                         }]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }
  [self performPatchLogic];
}

- (void)performPatchLogic {
  if (!self.selectedModule) {
    [self showToast:TR(@"Patch_Select_Msg")];
    return;
  }
  NSString *offsetStr =
      [self.offsetField.text stringByReplacingOccurrencesOfString:@"0x"
                                                       withString:@""];
  uint64_t offset = strtoull([offsetStr UTF8String], NULL, 16);
  uint64_t addr = self.selectedModule.loadAddress + offset;

  NSData *data = [[VMMemoryEngine shared] dataFromHexString:self.hexField.text];
  if (!data || data.length == 0) {
    [self showToast:TR(@"Patch_Hex_Err")];
    return;
  }

  mach_msg_type_number_t len = (mach_msg_type_number_t)data.length;

  if (!self.tempOriginalHex) {
    NSData *orig = [[VMMemoryEngine shared] readRawMemory:addr length:len];
    if (orig && orig.length == len) {
      self.tempOriginalHex = [[VMMemoryEngine shared] hexStringFromData:orig];
    }
  }

  BOOL success = [[VMMemoryEngine shared] writeRawData:data toAddress:addr];

  if (success) {
    [self showToast:TR(@"Alert_Success")];
  } else {
    [self showToast:TR(@"Alert_Fail")];
  }
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  if (self.isFolderMode)
    return self.folderList.count;
  return self.filteredPatches.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (self.isFolderMode) {
    static NSString *cid = @"folder";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
      cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                    reuseIdentifier:cid];
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSString *bid = self.folderList[indexPath.row];
    NSDictionary *meta = self.folderMetadata[bid];
    NSString *name = meta[@"name"];
    NSString *ver = meta[@"ver"];
    NSUInteger cnt = [meta[@"count"] unsignedIntegerValue];
    if (ver.length > 0)
      cell.textLabel.text = [NSString stringWithFormat:@"%@ - v%@", name, ver];
    else
      cell.textLabel.text = name;
    cell.detailTextLabel.text = [NSString
        stringWithFormat:@"%@ (%lu Patches)", bid, (unsigned long)cnt];
    cell.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
    cell.imageView.tintColor = [UIColor systemBlueColor];
    cell.selectionStyle = tableView.isEditing
                              ? UITableViewCellSelectionStyleDefault
                              : UITableViewCellSelectionStyleNone;
    return cell;
  } else {
    static NSString *rvaCellID = @"VMRVAManagerCell";
    VMRVAManagerCell *cell =
        [tableView dequeueReusableCellWithIdentifier:rvaCellID];
    if (!cell) {
      cell = [[VMRVAManagerCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:rvaCellID];
      cell.delegate = self;
    }
    if (indexPath.row < self.filteredPatches.count) {
      VMRVAPatch *patch = self.filteredPatches[indexPath.row];
      [cell configureWithPatch:patch];
    }
    return cell;
  }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
  [self.view endEditing:YES];
}
- (BOOL)ensureConnectionAndRefreshModule {
  VMMemoryEngine *engine = [VMMemoryEngine shared];
  BOOL isAlive = (engine.targetTask != MACH_PORT_NULL && engine.targetPid > 0 &&
                  kill(engine.targetPid, 0) == 0);
  if (isAlive)
    return YES;

  NSString *targetBid = engine.currentBundleID;
  if (!targetBid) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:TR(@"Err_Not_Connected")
                         message:TR(@"Err_Not_Connected_Msg")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return NO;
  }

  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) == -1)
    return NO;
  struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
  if (sysctl(mib, 4, procs, &size, NULL, 0) == -1) {
    free(procs);
    return NO;
  }

  int count = size / sizeof(struct kinfo_proc);
  pid_t foundPid = 0;

  for (int i = 0; i < count; i++) {
    pid_t pid = procs[i].kp_proc.p_pid;
    if (pid <= 0)
      continue;
    char pathBuffer[4096];
    memset(pathBuffer, 0, sizeof(pathBuffer));
    proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    NSString *fullPath = [NSString stringWithUTF8String:pathBuffer];
    if ([fullPath containsString:@".app"]) {
      NSString *appDir = [fullPath stringByDeletingLastPathComponent];
      while (![appDir.pathExtension isEqualToString:@"app"] &&
             ![appDir isEqualToString:@"/"]) {
        appDir = [appDir stringByDeletingLastPathComponent];
      }
      NSString *plistPath =
          [appDir stringByAppendingPathComponent:@"Info.plist"];
      NSDictionary *info =
          [NSDictionary dictionaryWithContentsOfFile:plistPath];
      if ([info[@"CFBundleIdentifier"] caseInsensitiveCompare:targetBid] ==
          NSOrderedSame) {
        foundPid = pid;
        break;
      }
    }
  }
  free(procs);

  if (foundPid > 0) {
    if ([engine attachToPid:foundPid]) {
      [self showToast:[NSString stringWithFormat:TR(@"Sig_Auto_Reconnected"),
                                                 foundPid]];
      if (self.selectedModule) {
        NSString *modName = self.selectedModule.name;
        NSArray *newModules = [engine loadRemoteModules];
        VMModuleInfo *newMod = nil;
        for (VMModuleInfo *m in newModules) {
          if ([m.name isEqualToString:modName]) {
            newMod = m;
            break;
          }
        }
        if (newMod) {
          self.selectedModule = newMod;
          self.moduleField.text = newMod.name;
          [self calculateFinalAddress];
          return YES;
        }
      }
      return YES;
    }
  }
  return NO;
}

#pragma mark - Save Patch Action
- (void)savePatchAction {
  if (!self.selectedModule) {
    [self showToast:TR(@"Patch_Select_Msg")];
    return;
  }
  NSString *rawPatchHex = self.hexField.text;
  if (rawPatchHex.length == 0) {
    [self showToast:TR(@"Patch_Hex_Err")];
    return;
  }

  NSString *cleanPatchHex = [self normalizeHex:rawPatchHex];
  if (cleanPatchHex.length % 2 != 0) {
    [self showToast:TR(@"Hex_Err_Len_Title")];
    return;
  }
  NSUInteger byteLength = cleanPatchHex.length / 2;
  if (byteLength == 0)
    return;

  NSString *offsetStr =
      [self.offsetField.text stringByReplacingOccurrencesOfString:@"0x"
                                                       withString:@""];
  uint64_t offset = strtoull([offsetStr UTF8String], NULL, 16);
  uint64_t absAddr = self.selectedModule.loadAddress + offset;

  NSString *detectedOrigHex = nil;
  if (self.tempOriginalHex && self.tempOriginalHex.length > 0) {
    detectedOrigHex = self.tempOriginalHex;
  } else {
    if ([VMMemoryEngine shared].targetTask == MACH_PORT_NULL) {
      [self ensureConnectionAndRefreshModule];
    }
    if (self.selectedModule) {
      absAddr = self.selectedModule.loadAddress + offset;
    }
    NSData *memData = [[VMMemoryEngine shared] readRawMemory:absAddr
                                                      length:byteLength];
    if (memData && memData.length == byteLength) {
      detectedOrigHex = [[VMMemoryEngine shared] hexStringFromData:memData];
    }
  }

  VMRVAPatch *existingPatch = nil;
  NSString *currentBid = [VMMemoryEngine shared].currentBundleID;

  for (VMRVAPatch *p in [VMMemoryEngine shared].rvaPatches) {
    BOOL bidMatch = (!p.bundleID || [p.bundleID isEqualToString:currentBid]);
    if (bidMatch && [p.moduleName isEqualToString:self.selectedModule.name] &&
        p.offset == offset) {
      existingPatch = p;
      break;
    }
  }

  if (existingPatch && existingPatch.isOn) {
    detectedOrigHex = existingPatch.originalHex;
  }


  UIAlertController *alert =

      [UIAlertController alertControllerWithTitle:TR(@"Title_Save_Patch")
                                          message:nil
                                   preferredStyle:UIAlertControllerStyleAlert];
  NSString *defaultNote =
      existingPatch
          ? existingPatch.note
          : [NSString stringWithFormat:@"%@ + 0x%llX", self.selectedModule.name,
                                       offset];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = defaultNote;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
    l.text = TR(@"Lock_Label_Note");
    l.font = [UIFont systemFontOfSize:12];
    tf.leftView = l;
    tf.leftViewMode = UITextFieldViewModeAlways;
  }];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.text = cleanPatchHex;
    tf.placeholder = TR(@"RVA_Patch_Hex_Placeholder");
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
    l.text = TR(@"RVA_Modify_Label");
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = [UIColor systemGreenColor];
    tf.leftView = l;
    tf.leftViewMode = UITextFieldViewModeAlways;
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.text = detectedOrigHex ?: @"";
    tf.placeholder = TR(@"RVA_Original_Hex_Placeholder");
    if (!detectedOrigHex)
      tf.text = @"???";
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
    l.text = TR(@"RVA_Origin_Label");
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = [UIColor systemRedColor];
    tf.leftView = l;
    tf.leftViewMode = UITextFieldViewModeAlways;
  }];
  
  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.text = existingPatch ? existingPatch.author : @"";
    tf.placeholder = TR(@"Placeholder_Author");
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
    l.text = TR(@"Lock_Label_Author");
    l.font = [UIFont systemFontOfSize:12];
    tf.leftView = l;
    tf.leftViewMode = UITextFieldViewModeAlways;

  }];

  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:TR(@"Btn_Confirm")
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction *a) {
                        UITextField *tfNote = alert.textFields[0];
                        UITextField *tfPatch = alert.textFields[1];
                        UITextField *tfOrig = alert.textFields[2];
                        UITextField *tfAuth = alert.textFields[3];

                        NSString *note = (tfNote.text.length > 0)
                                             ? tfNote.text
                                             : tfNote.placeholder;
                        NSString *finalPatchHex = tfPatch.text;
                        NSString *finalOrigHex = tfOrig.text;
                        NSString *author = (tfAuth.text.length > 0)
                                               ? tfAuth.text
                                               : tfAuth.placeholder;

                        if (finalPatchHex.length == 0 ||
                            finalOrigHex.length == 0)
                          return;

                        VMRVAPatch *targetPatch = existingPatch;

                        if (!targetPatch) {
                          for (VMRVAPatch *p in [VMMemoryEngine shared]
                                   .rvaPatches) {
                            BOOL bidMatch =
                                (!p.bundleID ||
                                 [p.bundleID isEqualToString:currentBid]);
                            if (bidMatch &&
                                [p.moduleName
                                    isEqualToString:self.selectedModule.name] &&
                                p.offset == offset) {
                              targetPatch = p;
                              break;
                            }
                          }
                        }

                        if (targetPatch) {
                          VMRVAPatch *patch = [[VMRVAPatch alloc] init];
                          patch.moduleName = self.selectedModule.name;
                          patch.offset = offset;
                          patch.patchHex = finalPatchHex;
                          patch.originalHex = finalOrigHex;
                          patch.note = note;
                          patch.author = author;
                          patch.isImported = targetPatch.isImported;
                          patch.bundleID = currentBid;
                          patch.isOn = targetPatch.isOn;
                          patch.createdAt = targetPatch.createdAt;
                          if (currentBid && currentBid.length > 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            id proxy = [NSClassFromString(@"LSApplicationProxy")
                                performSelector:
                                    NSSelectorFromString(
                                        @"applicationProxyForIdentifier:")
                                     withObject:currentBid];
                            if (proxy) {
                              patch.appName =
                                  [proxy performSelector:NSSelectorFromString(
                                                             @"localizedName")];
                              patch.appVersion = [proxy
                                  performSelector:NSSelectorFromString(
                                                      @"shortVersionString")];
                            }
#pragma clang diagnostic pop
                          }
                          NSInteger index = [[VMMemoryEngine shared].rvaPatches
                              indexOfObject:targetPatch];
                          if (index != NSNotFound) {
                            [[VMMemoryEngine shared].rvaPatches
                                replaceObjectAtIndex:index
                                          withObject:patch];
                          } else {
                            [[VMMemoryEngine shared].rvaPatches
                                addObject:patch];
                          }
                        } else {
                          VMRVAPatch *patch = [[VMRVAPatch alloc] init];
                          patch.moduleName = self.selectedModule.name;
                          patch.offset = offset;
                          patch.patchHex = finalPatchHex;
                          patch.originalHex = finalOrigHex;
                          patch.isOn = NO;
                          patch.note = note;
                          patch.author = author;
                          patch.isImported = NO;
                          patch.bundleID = currentBid;
                          patch.createdAt =
                              [[NSDate date] timeIntervalSince1970] + 0.001;
                          if (currentBid && currentBid.length > 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            id proxy = [NSClassFromString(@"LSApplicationProxy")
                                performSelector:
                                    NSSelectorFromString(
                                        @"applicationProxyForIdentifier:")
                                     withObject:currentBid];
                            if (proxy) {
                              patch.appName =
                                  [proxy performSelector:NSSelectorFromString(
                                                             @"localizedName")];
                              patch.appVersion = [proxy
                                  performSelector:NSSelectorFromString(
                                                      @"shortVersionString")];
                            }
#pragma clang diagnostic pop
                          }
                          [[VMMemoryEngine shared].rvaPatches addObject:patch];
                        }

                        [[VMMemoryEngine shared] saveRVAPatches];

                        if (self.isShowingManager)
                          [self reloadPatchData];

                        UIAlertController *shareAlert = [UIAlertController
                            alertControllerWithTitle:TR(@"Share_Title")
                                             message:TR(@"Share_Msg")
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];

                        [shareAlert
                            addAction:
                                [UIAlertAction
                                    actionWithTitle:TR(@"Btn_Go_RVA")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
      UITabBarController *tabBar = self.tabBarController;
      if (tabBar && tabBar.viewControllers.count > 3) {
        tabBar.selectedIndex = 3;
        UINavigationController *nav = (UINavigationController *)tabBar.selectedViewController;
        [nav popToRootViewControllerAnimated:NO];
        if ([nav.topViewController isKindOfClass:NSClassFromString(@"VMLockListViewController")]) {
          id lockVC = nav.topViewController;
          NSDictionary *pending = @{@"targetTab": @(3), @"bundleID": currentBid ?: @"", @"fileName": (tfNote.text.length > 0) ? tfNote.text : @"Patch", @"toast": TR(@"Msg_Saved")};
          [lockVC setValue:pending forKey:@"pendingJumpInfo"];
          if ([lockVC respondsToSelector:@selector(processPendingJump)]) [lockVC performSelector:@selector(processPendingJump)];
        }
      }
                                            }]];

  [shareAlert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Cancel")
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
  [self presentViewController:shareAlert animated:YES completion:nil];
}]];

[alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Cancel")
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
[self presentViewController:alert animated:YES completion:nil];
}

- (void)rvaSwitchChanged:(UISwitch *)sender {
  VMRVAPatch *patch = [VMMemoryEngine shared].rvaPatches[sender.tag];
  BOOL newState = sender.isOn;
  uint64_t modBase =
      [[VMMemoryEngine shared] findModuleBaseAddress:patch.moduleName];
  if (modBase == 0) {
    [self showToast:TR(@"Patch_Err_Module_Not_Found")];
    [sender setOn:!newState animated:YES];
    return;
  }
  uint64_t absAddr = modBase + patch.offset;
  NSString *hexToWrite = newState ? patch.patchHex : patch.originalHex;

  [self performWritePatch:patch
                targetHex:hexToWrite
                  address:absAddr
                 newState:newState];
}

- (NSString *)normalizeHex:(NSString *)hex {
  NSString *clean =
      [[hex stringByReplacingOccurrencesOfString:@" "
                                      withString:@""] uppercaseString];
  clean = [clean stringByReplacingOccurrencesOfString:@"0X" withString:@""];
  return clean;
}

- (void)rvaToggleBtnClicked:(UIButton *)sender {
  VMRVAPatch *patch = objc_getAssociatedObject(sender, "patchObj");
  if (!patch)
    return;
  NSString *targetBid = patch.bundleID;
  if (!targetBid) {
    [self showToast:TR(@"Err_No_BundleID")];
    return;
  }
  if (![self isConnectedToBundle:targetBid]) {
    if ([self tryReconnectForBundleID:targetBid]) {
      UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
          initWithStyle:UIImpactFeedbackStyleLight];
      [gen impactOccurred];
      [self reloadPatchData];
      [self showToast:TR(@"Msg_Attached")];
    } else {
      [self showToast:[NSString
                          stringWithFormat:@"%@\n(%@)",
                                           TR(@"Err_Not_Connected_Msg"),
                                           targetBid ?: TR(@"App_Unknown")]];
      return;
    }
  }
  uint64_t modBase =
      [[VMMemoryEngine shared] findModuleBaseAddress:patch.moduleName];
  if (modBase == 0) {
    [self showToast:TR(@"Patch_Err_Module_Not_Found")];
    return;
  }
  uint64_t absAddr = modBase + patch.offset;
  NSString *patchHex = [self normalizeHex:patch.patchHex];
  NSString *origHex = [self normalizeHex:patch.originalHex];
  NSData *pData = [[VMMemoryEngine shared] dataFromHexString:patchHex];
  NSData *currentData = [[VMMemoryEngine shared] readRawMemory:absAddr
                                                        length:pData.length];
  NSString *currentHex = [self
      normalizeHex:[[VMMemoryEngine shared] hexStringFromData:currentData]];
  if (!currentHex) {
    [self showToast:TR(@"Err_Read_Fail")];
    return;
  }

  BOOL targetState = !patch.isOn;
  NSString *targetHex = targetState ? patchHex : origHex;

  if (targetState) {
    if ([currentHex isEqualToString:patchHex]) {
      [self updatePatchState:patch isOn:YES];
      return;
    }
    if (![currentHex isEqualToString:origHex]) {
      [self showIntegrityAlert:patch
                       current:currentHex
                        target:targetHex
                          addr:absAddr
                         state:YES];
      return;
    }
  } else {
    if ([currentHex isEqualToString:origHex]) {
      [self updatePatchState:patch isOn:NO];
      return;
    }
    if (![currentHex isEqualToString:patchHex]) {
      [self showIntegrityAlert:patch
                       current:currentHex
                        target:targetHex
                          addr:absAddr
                         state:NO];
      return;
    }
  }
  [self performWritePatch:patch
                targetHex:targetHex
                  address:absAddr
                 newState:targetState];
}

- (void)updatePatchState:(VMRVAPatch *)patch isOn:(BOOL)isOn {
  patch.isOn = isOn;
  [[VMMemoryEngine shared] saveRVAPatches];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.managerTableView reloadData];
  });
}

- (void)showIntegrityAlert:(VMRVAPatch *)patch
                   current:(NSString *)curr
                    target:(NSString *)tgt
                      addr:(uint64_t)addr
                     state:(BOOL)newState {

  BOOL shouldMask = NO;

  NSString *msg;
  if (shouldMask) {
    
    msg = TR(@"RVA_Warn_Mismatch_Msg_Hidden");
    if ([msg isEqualToString:@"RVA_Warn_Mismatch_Msg_Hidden"]) {
      msg = @"Data mismatch detected.";
    }
  } else {
    msg = [NSString
        stringWithFormat:TR(@"RVA_Warn_Mismatch_Msg"), curr, patch.originalHex];
  }

  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:TR(@"RVA_Warn_Mismatch_Title")
                                          message:msg
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Force_Cont")
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) {
                                            [self performWritePatch:patch
                                                          targetHex:tgt
                                                            address:addr
                                                           newState:newState];
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)performWritePatch:(VMRVAPatch *)patch
                targetHex:(NSString *)hex
                  address:(uint64_t)addr
                 newState:(BOOL)isOn {
  
  NSData *data = [[VMMemoryEngine shared] dataFromHexString:hex];

  if (!data || data.length == 0) {
    [self showToast:TR(@"Patch_Hex_Err")];
    return;
  }

  mach_port_t task = [VMMemoryEngine shared].targetTask;
  mach_msg_type_number_t size = (mach_msg_type_number_t)data.length;
  vm_address_t targetAddr = (vm_address_t)addr;

  mach_vm_protect(task, targetAddr, size, FALSE,
                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);

  kern_return_t kr_write =
      mach_vm_write(task, targetAddr, (vm_offset_t)data.bytes, size);

  mach_vm_protect(task, targetAddr, size, FALSE,
                  VM_PROT_READ | VM_PROT_EXECUTE);

  BOOL writeSuccess = NO;
  if (kr_write == KERN_SUCCESS) {
    usleep(5000);
    NSData *readBack = [[VMMemoryEngine shared] readRawMemory:addr
                                                       length:data.length];
    
    if (readBack && [readBack isEqualToData:data]) {
      writeSuccess = YES;
    }
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (writeSuccess) {
      [self updatePatchState:patch isOn:isOn];
      [self showToast:isOn ? TR(@"Msg_Mod_Success") : TR(@"Msg_Saved")];
      UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
          initWithStyle:UIImpactFeedbackStyleMedium];
      [gen impactOccurred];
    } else {
      if (kr_write != KERN_SUCCESS) {
        [self showToast:[NSString stringWithFormat:@"%@: %d",
                                                   TR(@"Err_File_Write"),
                                                   kr_write]];
      } else {
        [self showToast:TR(@"Err_Write_Protection")];
      }
      [self.managerTableView reloadData];
    }
  });
}

- (void)batchExport {
  NSArray *selectedPaths = [self.managerTableView indexPathsForSelectedRows];
  if (selectedPaths.count == 0) {
    [self showToast:TR(@"Msg_No_Sel")];
    return;
  }
  NSMutableArray *exportItems = [NSMutableArray array];
  for (NSIndexPath *idx in selectedPaths) {
    if (idx.row < self.filteredPatches.count) {
      [exportItems addObject:self.filteredPatches[idx.row]];
    }
  }
  if (exportItems.count == 0)
    return;
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  [fmt setDateFormat:@"yyMMddHHmmss"];
  NSString *fileName =
      [NSString stringWithFormat:@"Batch_RVA_%@.vmrva",
                                 [fmt stringFromDate:[NSDate date]]];
  NSString *tempPath =
      [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
  NSError *err;
  VMRVAPatch *firstPatch = exportItems.firstObject;
  NSString *bid = firstPatch.bundleID;
  if (!bid) {
    [self showToast:TR(@"Err_No_BundleID")];
    return;
  }
  VMDataSession *session = [VMDataSession sessionWithData:exportItems
                                                 bundleID:bid
                                                 dataType:@"rva"];
  NSData *data = [session toJSONDataForExport];
  if (data && [data writeToFile:tempPath atomically:YES]) {
    [[NSFileManager defaultManager]
        setAttributes:@{NSFilePosixPermissions : @(0666)}
         ofItemAtPath:tempPath
                error:nil];
    NSURL *fileURL = [NSURL fileURLWithPath:tempPath];
    UIView *sourceView = self.navigationController.navigationBar;
    CGRect sourceRect =
        CGRectMake(sourceView.bounds.size.width - 50, 0, 50, 44);
    [VMShareHelper shareContent:fileURL
             fromViewController:self
                     sourceView:sourceView
                     sourceRect:sourceRect];
  } else {
    [self showToast:[NSString stringWithFormat:TR(@"Export_Error_Format"),
                                               err.localizedDescription]];
  }
}

- (void)sharePatch:(VMRVAPatch *)patch
        sourceView:(UIView *)view
        sourceRect:(CGRect)rect {
  NSString *bid = patch.bundleID;
  if (!bid) {
    [self showToast:TR(@"Err_No_BundleID")];
    return;
  }

  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  [fmt setDateFormat:@"yyMMddHHmmss"];
  NSString *fileName =
      [NSString stringWithFormat:@"Rva_%@_%@.vmrva", bid,
                                 [fmt stringFromDate:[NSDate date]]];
  NSString *tempPath =
      [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
  NSError *err;
  VMDataSession *session = [VMDataSession sessionWithData:@[ patch ]
                                                 bundleID:bid
                                                 dataType:@"rva"];
  NSData *data = [session toJSONDataForExport];
  if (data && [data writeToFile:tempPath atomically:YES]) {
    [[NSFileManager defaultManager]
        setAttributes:@{NSFilePosixPermissions : @(0666)}
         ofItemAtPath:tempPath
                error:nil];
    NSURL *fileURL = [NSURL fileURLWithPath:tempPath];
    [VMShareHelper shareContent:fileURL
             fromViewController:self
                     sourceView:view
                     sourceRect:rect];
  } else {
    [self showToast:[NSString stringWithFormat:TR(@"Err_Export_Fmt"),
                                               err.localizedDescription]];
  }
}

- (void)batchDelete {
  NSArray *rows = [self.managerTableView indexPathsForSelectedRows];
  if (!rows || rows.count == 0) {
    [self showToast:TR(@"Msg_No_Sel")];
    return;
  }
  NSMutableArray *itemsToDelete = [NSMutableArray array];
  for (NSIndexPath *ip in rows) {
    if (ip.row < self.filteredPatches.count) {
      [itemsToDelete addObject:self.filteredPatches[ip.row]];
    }
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *currentFolder = self.viewingBundleID;
  if (!currentFolder || currentFolder.length == 0) {
    [self showToast:TR(@"Err_No_BundleID")];
    return;
  }
  NSString *appDir = [self rvaFolderPathForBundleID:currentFolder create:NO];
  for (VMRVAPatch *p in itemsToDelete) {
    if (p.fileName && p.fileName.length > 0) {
      NSString *filePath = [appDir stringByAppendingPathComponent:p.fileName];
      if ([fm fileExistsAtPath:filePath]) {
        NSError *err;
        [fm removeItemAtPath:filePath error:&err];
        if (err) {
        }
      }
    }
  }
  [[VMMemoryEngine shared] loadRVAPatches];
  [self checkAndCleanupFolderForBundleID:currentFolder];
  [self exitBatchMode];
  if (!self.isFolderMode &&
      [self.viewingBundleID isEqualToString:currentFolder]) {
    [self reloadPatchData];
    [self showToast:TR(@"Batch_Del_Success")];
  }
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView == self.managerTableView)
    return UITableViewAutomaticDimension;
  return 60;
}

- (CGFloat)tableView:(UITableView *)tableView
    estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView == self.managerTableView)
    return 180;
  return 60;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView == self.managerTableView) {
    return tableView.isEditing ? UITableViewCellEditingStyleNone
                               : UITableViewCellEditingStyleDelete;
  }
  return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  if (self.managerTableView.isEditing)
    return;
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (self.isFolderMode) {
    self.viewingBundleID = self.folderList[indexPath.row];
    self.isFolderMode = NO;
    [self reloadPatchData];
    [self updateNavBarButtons];
  } else {
    if (indexPath.row >= self.filteredPatches.count)
      return;
    VMRVAPatch *patch = self.filteredPatches[indexPath.row];

    if (![self isConnectedToBundle:patch.bundleID]) {
      if ([self tryReconnectForBundleID:patch.bundleID]) {
        [[VMMemoryEngine shared] loadRemoteModules];
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleLight];
        [gen impactOccurred];
        [self reloadPatchData];
        [self showToast:TR(@"Msg_Attached")];
      } else {
        NSString *bid = patch.bundleID ?: TR(@"App_Unknown");
        [self showToast:[NSString stringWithFormat:@"%@\n(%@)",
                                                   TR(@"Err_Not_Connected_Msg"),
                                                   bid]];
        return;
      }
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:TR(@"Title_Edit_RVA")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];

    BOOL shouldMask = NO;

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
      if (patch.note) {
        tf.text = patch.note;
      } else {
        tf.placeholder = TR(@"Placeholder_Note");
      }

    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
      
      tf.text = shouldMask ? @"[Hidden Location]" : [patch displayString];
      tf.enabled = NO;
      tf.textColor = [UIColor systemGrayColor];
      tf.font = [UIFont fontWithName:@"Menlo" size:12];
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
      tf.placeholder = TR(@"Placeholder_Author");
      tf.text = patch.author;
      if (patch.isImported) {
        tf.enabled = NO;
        tf.textColor = [UIColor systemGrayColor];
        tf.text = [NSString
            stringWithFormat:@"%@ (%@)", patch.author, TR(@"Status_Locked")];
      }
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
      tf.placeholder = @"Hex (e.g. E0031F2A)";
      
      tf.text = shouldMask ? @"********" : patch.patchHex;
      tf.font = [UIFont fontWithName:@"Menlo" size:12];
      if (patch.isImported || shouldMask) {
        tf.enabled = NO;
        tf.textColor = [UIColor systemGrayColor];
      }
    }];
    [alert
        addAction:
            [UIAlertAction
                actionWithTitle:TR(@"Btn_Confirm")
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) {
                          if (!patch.isImported) {
                          }
                          patch.note = alert.textFields[0].text;
                          if (!patch.isImported) {
                            NSString *authorText = alert.textFields[2].text;
                            NSString *lockedSuffix = [NSString
                                stringWithFormat:@" (%@)",
                                                 TR(@"Status_Locked")];
                            if ([authorText hasSuffix:lockedSuffix]) {
                              authorText = [authorText
                                  substringToIndex:authorText.length -
                                                   lockedSuffix.length];
                            }
                            patch.author = authorText;
                          }
                          patch.patchHex = alert.textFields[3].text;

                          if (patch.fileName && patch.fileName.length > 0) {
                            NSString *appDir =
                                [self rvaFolderPathForBundleID:patch.bundleID
                                                        create:YES];
                            NSString *filePath = [appDir
                                stringByAppendingPathComponent:patch.fileName];

                            VMDataSession *session =
                                [VMDataSession sessionWithData:@[ patch ]
                                                      bundleID:patch.bundleID
                                                      dataType:@"rva"];
                            [[session toJSONData] writeToFile:filePath
                                                   atomically:YES];
                          } else {
                            [[VMMemoryEngine shared] saveRVAPatches];
                          }

                          [self.managerTableView
                              reloadRowsAtIndexPaths:@[ indexPath ]
                                    withRowAnimation:
                                        UITableViewRowAnimationNone];
                        }]];
    [alert addAction:[UIAlertAction actionWithTitle:TR(@"Btn_Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  }
}

- (BOOL)tryReconnectForBundleID:(NSString *)bid {
  if (!bid || bid.length == 0)
    return NO;
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) == -1)
    return NO;
  struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
  if (sysctl(mib, 4, procs, &size, NULL, 0) == -1) {
    free(procs);
    return NO;
  }

  int count = size / sizeof(struct kinfo_proc);
  pid_t foundPid = 0;

  for (int i = 0; i < count; i++) {
    pid_t pid = procs[i].kp_proc.p_pid;
    if (pid <= 0)
      continue;
    char pathBuffer[4096];
    memset(pathBuffer, 0, sizeof(pathBuffer));
    proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    NSString *fullPath = [NSString stringWithUTF8String:pathBuffer];
    if ([fullPath containsString:@".app"]) {
      NSString *appDir = [fullPath stringByDeletingLastPathComponent];
      while (![appDir.pathExtension isEqualToString:@"app"] &&
             ![appDir isEqualToString:@"/"]) {
        appDir = [appDir stringByDeletingLastPathComponent];
      }
      NSString *plistPath =
          [appDir stringByAppendingPathComponent:@"Info.plist"];
      NSDictionary *info =
          [NSDictionary dictionaryWithContentsOfFile:plistPath];
      if (info && [info[@"CFBundleIdentifier"] caseInsensitiveCompare:bid] ==
                      NSOrderedSame) {
        foundPid = pid;
        break;
      }
    }
  }
  free(procs);

  if (foundPid > 0) {
    BOOL success = [[VMMemoryEngine shared] attachToPid:foundPid];
    if (success) {
      [VMMemoryEngine shared].currentBundleID = bid;
      [[VMMemoryEngine shared] loadRemoteModules];
      return YES;
    }
  }
  return NO;
}

- (void)handleManagerRefresh:(UIRefreshControl *)sender {
  sender.attributedTitle =
      [[NSAttributedString alloc] initWithString:TR(@"Pull_Loading")];

  [self reloadPatchData];

  [self.managerTableView layoutIfNeeded];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self refreshVisibleRVAStates];
      });

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [sender endRefreshing];
        sender.attributedTitle =
            [[NSAttributedString alloc] initWithString:TR(@"Pull_Idle")];
      });
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  if (scrollView == self.managerTableView) {
    if (self.managerTableView.refreshControl.isRefreshing)
      return;
    CGFloat baseOffset = scrollView.adjustedContentInset.top;
    CGFloat pullDistance = -(scrollView.contentOffset.y + baseOffset);
    CGFloat triggerHeight = 45.0;
    NSString *currentText =
        self.managerTableView.refreshControl.attributedTitle.string;
    if (pullDistance > triggerHeight) {
      if (![currentText isEqualToString:TR(@"Pull_Ready")]) {
        self.managerTableView.refreshControl.attributedTitle =
            [[NSAttributedString alloc] initWithString:TR(@"Pull_Ready")];
      }
    } else if (pullDistance > 0) {
      if (![currentText isEqualToString:TR(@"Pull_Idle")]) {
        self.managerTableView.refreshControl.attributedTitle =
            [[NSAttributedString alloc] initWithString:TR(@"Pull_Idle")];
      }
    }
  }
}

- (BOOL)isConnectedToBundle:(NSString *)targetBid {
  VMMemoryEngine *eng = [VMMemoryEngine shared];
  BOOL isTaskValid = (eng.targetTask != MACH_PORT_NULL);
  BOOL isPidAlive = (eng.targetPid > 0 && kill(eng.targetPid, 0) == 0);
  BOOL isMatch = YES;
  if (targetBid && targetBid.length > 0 && eng.currentBundleID) {
    isMatch = [eng.currentBundleID isEqualToString:targetBid];
  }
  return isTaskValid && isPidAlive && isMatch;
}

- (void)didClickRVAEdit:(UITableViewCell *)cell {
  NSIndexPath *indexPath = [self.managerTableView indexPathForCell:cell];
  if (!indexPath)
    return;
  [self tableView:self.managerTableView didSelectRowAtIndexPath:indexPath];
}

- (void)didClickRVAToggle:(UITableViewCell *)cell {
  NSIndexPath *indexPath = [self.managerTableView indexPathForCell:cell];
  if (!indexPath)
    return;
  if (indexPath.row >= self.filteredPatches.count)
    return;
  VMRVAPatch *patch = self.filteredPatches[indexPath.row];
  UIButton *tempBtn = [UIButton new];
  objc_setAssociatedObject(tempBtn, "patchObj", patch,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self rvaToggleBtnClicked:tempBtn];
}

- (void)enterBatchMode {
  self.managerTableView.allowsMultipleSelectionDuringEditing = YES;
  [self.managerTableView setEditing:YES animated:YES];
  UIBarButtonItem *selAllBtn =
      [[UIBarButtonItem alloc] initWithTitle:TR(@"Batch_Sel_All")
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(batchSelectAll)];
  self.navigationItem.leftBarButtonItem = selAllBtn;
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:TR(@"Btn_Cancel")
                                       style:UIBarButtonItemStyleDone
                                      target:self
                                      action:@selector(exitBatchMode)];
  UIView *titleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, 44)];
  UIButton *expBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  [expBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
          forState:UIControlStateNormal];
  expBtn.frame = CGRectMake(0, 2, 100, 40);
  [expBtn setTitle:TR(@"Act_Export") forState:UIControlStateNormal];
  expBtn.titleLabel.font = [UIFont systemFontOfSize:14];
  [expBtn addTarget:self
                action:@selector(performBatchShare)
      forControlEvents:UIControlEventTouchUpInside];
  [titleView addSubview:expBtn];
  UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  [delBtn setImage:[UIImage systemImageNamed:@"trash"]
          forState:UIControlStateNormal];
  delBtn.frame = CGRectMake(110, 2, 100, 40);
  [delBtn setTitle:TR(@"Act_Delete") forState:UIControlStateNormal];
  [delBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
  delBtn.tintColor = [UIColor systemRedColor];
  delBtn.titleLabel.font = [UIFont systemFontOfSize:14];
  [delBtn addTarget:self
                action:@selector(batchDelete)
      forControlEvents:UIControlEventTouchUpInside];
  [titleView addSubview:delBtn];
  self.navigationItem.titleView = titleView;
}

- (void)exitBatchMode {
  [self.managerTableView setEditing:NO animated:YES];
  self.navigationItem.titleView = nil;
  self.title = TR(@"Patch_Title");
  [self updateNavBarButtons];
}

- (void)batchSelectAll {
  for (int i = 0; i < [self.managerTableView numberOfRowsInSection:0]; i++) {
    [self.managerTableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:i
                                                                   inSection:0]
                                       animated:NO
                                 scrollPosition:UITableViewScrollPositionNone];
  }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:
        (NSIndexPath *)indexPath {
  if (tableView != self.managerTableView)
    return nil;
  UIContextualAction *del = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleDestructive
                          title:TR(@"Act_Delete")
                        handler:^(UIContextualAction *a, UIView *v,
                                  void (^c)(BOOL)) {
                          if (indexPath.row < self.filteredPatches.count) {
                            VMRVAPatch *p = self.filteredPatches[indexPath.row];
                            NSString *bid = p.bundleID;
                            if (p.fileName && p.fileName.length > 0 && bid) {
                              NSString *filePath = [[self
                                  rvaFolderPathForBundleID:bid
                                                    create:NO]
                                  stringByAppendingPathComponent:p.fileName];
                              [[NSFileManager defaultManager]
                                  removeItemAtPath:filePath
                                             error:nil];
                            }
                            [[VMMemoryEngine shared].rvaPatches removeObject:p];
                            [self.filteredPatches
                                removeObjectAtIndex:indexPath.row];
                            if (self.filteredPatches.count > 0) {
                              [tableView deleteRowsAtIndexPaths:@[ indexPath ]
                                               withRowAnimation:
                                                   UITableViewRowAnimationFade];
                            } else {
                              [self checkAndCleanupFolderForBundleID:bid];
                              if (!self.isFolderMode &&
                                  [self.viewingBundleID isEqualToString:bid]) {
                                [self backToFolderList];
                              }
                            }
                            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                              [[VMMemoryEngine shared] loadRVAPatches];
                            });
                          }
                          c(YES);
                        }];
  del.title = TR(@"Act_Delete");
  UIContextualAction *share = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleNormal
                          title:TR(@"Act_Export")
                        handler:^(UIContextualAction *a, UIView *v,
                                  void (^c)(BOOL)) {
                          if (indexPath.row < self.filteredPatches.count) {
                            VMRVAPatch *p = self.filteredPatches[indexPath.row];
                            CGRect rectInTableView =
                                [tableView rectForRowAtIndexPath:indexPath];
                            CGRect rectInView =
                                [tableView convertRect:rectInTableView
                                                toView:self.view];
                            [self sharePatch:p
                                  sourceView:self.view
                                  sourceRect:rectInView];
                          }
                          c(YES);
                        }];
  share.backgroundColor = [UIColor systemBlueColor];
  share.title = TR(@"Act_Export");
  return [UISwipeActionsConfiguration configurationWithActions:@[ del, share ]];
}

- (void)handleManagerLongPress:(UILongPressGestureRecognizer *)g {
  if (g.state == UIGestureRecognizerStateBegan &&
      !self.managerTableView.isEditing) {
    [self enterBatchMode];
  }
}

- (void)performBatchShare {
  NSArray *rows = [self.managerTableView indexPathsForSelectedRows];
  if (rows.count == 0) {
    [self showToast:TR(@"Msg_No_Sel")];
    return;
  }

  if (self.isFolderMode) {
    [self exportSelectedFolders:rows];
  } else {
    [self exportSelectedAsBackup:rows];
  }
}

- (void)exportSelectedFolders:(NSArray *)selectedPaths {
  NSString *root = [VMMemoryEngine shared].rvaRootFolder;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *tempFiles = [NSMutableArray array];

  for (NSIndexPath *ip in selectedPaths) {
    if (ip.row >= self.folderList.count)
      continue;
    NSString *bid = self.folderList[ip.row];
    NSString *folderPath = [root stringByAppendingPathComponent:bid];
    NSArray *files = [fm contentsOfDirectoryAtPath:folderPath error:nil];

    NSMutableArray *allPatches = [NSMutableArray array];
    NSString *appName = nil;
    NSString *appVer = nil;
    for (NSString *f in files) {
      if (![f hasSuffix:@".vmrva"])
        continue;
      NSData *fileData = [NSData
          dataWithContentsOfFile:[folderPath stringByAppendingPathComponent:f]];
      if (!fileData || fileData.length < 4)
        continue;

      VMDataSession *s = [VMDataSession fromJSONData:fileData];
      if (s && s.dataItems.count > 0) {
        [allPatches addObjectsFromArray:s.dataItems];
        if (s.appName) appName = s.appName;
        if (s.appVersion) appVer = s.appVersion;
        continue;
      }

      NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
      if (!dict) continue;
      VMRVAPatch *patch = [VMRVAPatch fromDictionary:dict];
      if (patch) {
        [allPatches addObject:patch];
        if (dict[@"appName"]) appName = dict[@"appName"];
        if (dict[@"appVersion"]) appVer = dict[@"appVersion"];
      }
    }

    if (allPatches.count == 0)
      continue;

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyMMddHHmmss"];
    NSString *safeName = appName ?: bid;
    NSString *fileName =
        [NSString stringWithFormat:@"%@_%@.vmrva", safeName,
                                   [fmt stringFromDate:[NSDate date]]];
    NSString *tempPath =
        [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];

    VMDataSession *session = [VMDataSession sessionWithData:allPatches
                                                   bundleID:bid
                                                   dataType:@"rva"];
    if (appName)
      session.appName = appName;
    if (appVer)
      session.appVersion = appVer;
    NSData *data = [session toJSONDataForExport];
    if (data && [data writeToFile:tempPath atomically:YES]) {
      [fm setAttributes:@{NSFilePosixPermissions : @(0666)}
           ofItemAtPath:tempPath
                  error:nil];
      [tempFiles addObject:[NSURL fileURLWithPath:tempPath]];
    }
  }

  if (tempFiles.count == 0) {
    [self showToast:TR(@"Msg_No_Sel")];
    return;
  }

  id shareContent =
      (tempFiles.count == 1) ? tempFiles.firstObject : tempFiles;
  [VMShareHelper
            shareContent:shareContent
      fromViewController:self
              sourceView:self.navigationController.navigationBar
              sourceRect:CGRectMake(self.navigationController.navigationBar
                                            .bounds.size.width -
                                        50,
                                    0, 50, 44)];
  [self exitBatchMode];
}

- (void)exportSelectedAsBackup:(NSArray *)selectedPaths {
  NSMutableArray *itemsToShare = [NSMutableArray array];
  for (NSIndexPath *ip in selectedPaths) {
    if (ip.row < self.filteredPatches.count) {
      [itemsToShare addObject:self.filteredPatches[ip.row]];
    }
  }

  if (itemsToShare.count == 0)
    return;
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  [fmt setDateFormat:@"yyMMddHHmmss"];
  NSString *fileName =
      [NSString stringWithFormat:@"Batch_RVA_%@.vmrva",
                                 [fmt stringFromDate:[NSDate date]]];
  NSString *tempPath =
      [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
  NSString *bid = ((VMRVAPatch *)itemsToShare.firstObject).bundleID;
  VMDataSession *session = [VMDataSession sessionWithData:itemsToShare
                                                 bundleID:bid
                                                 dataType:@"rva"];
  NSData *data = [session toJSONDataForExport];

  if (data && [data writeToFile:tempPath atomically:YES]) {
    [[NSFileManager defaultManager]
        setAttributes:@{NSFilePosixPermissions : @(0666)}
         ofItemAtPath:tempPath
                error:nil];
    [VMShareHelper
              shareContent:[NSURL fileURLWithPath:tempPath]
        fromViewController:self
                sourceView:self.navigationController.navigationBar
                sourceRect:CGRectMake(self.navigationController.navigationBar
                                              .bounds.size.width -
                                          50,
                                      0, 50, 44)];
    [self exitBatchMode];
  }
}

#pragma mark - State Management

- (void)resetState {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.selectedModule = nil;
    self.moduleField.text = TR(@"RVA_Select_Hint");
    self.moduleField.textColor = [UIColor systemOrangeColor];
    self.moduleDetailLabel.text = @"Select a framework to see details";
    self.offsetField.text = @"";
    self.finalAddrLabel.text = @"---";
    self.hexField.text = @"";
    self.previewInstructionLabel.text = TR(@"RVA_Waiting_Input");
    if ([VMMemoryEngine shared].targetTask != MACH_PORT_NULL) {
      [self loadModules];
    } else {
      self.procNameLabel.text = @"No Process";
      self.procDetailLabel.text = @"Base: - | Size: -";
    }
  });
}

- (void)onImportNotification {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.isShowingManager) {
      [self reloadPatchData];
    }
  });
}

#pragma mark - Keyboard Handling

- (void)keyboardWillShow:(NSNotification *)notification {
  NSDictionary *info = [notification userInfo];
  CGSize kbSize =
      [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue].size;

  UIEdgeInsets contentInsets = UIEdgeInsetsMake(0.0, 0.0, kbSize.height, 0.0);
  self.scrollView.contentInset = contentInsets;
  self.scrollView.scrollIndicatorInsets = contentInsets;

  if (self.activeField) {
    
    CGRect aRect = self.view.frame;
    aRect.size.height -= kbSize.height;

    CGRect fieldFrame = [self.activeField convertRect:self.activeField.bounds
                                               toView:self.view];

    if (!CGRectContainsPoint(
            aRect, CGPointMake(fieldFrame.origin.x,
                               fieldFrame.origin.y + fieldFrame.size.height))) {
      [self.scrollView scrollRectToVisible:fieldFrame animated:YES];
    }
  }
}

- (void)keyboardWillHide:(NSNotification *)notification {
  
  UIEdgeInsets contentInsets = UIEdgeInsetsZero;

  [UIView animateWithDuration:0.3
                   animations:^{
                     self.scrollView.contentInset = contentInsets;
                     self.scrollView.scrollIndicatorInsets = contentInsets;
                   }];
}

@end
