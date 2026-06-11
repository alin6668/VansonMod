#import "include/VMDataSession.h"
#import "VMScriptModel.h"
#import "include/VMPointerChain.h"
#import "include/VMRVAPatch.h"
#import "include/VMSignatureModel.h"
#import "include/VMMemoryEngine.h"

static NSString *getCurrentVersion(void) {
  static NSString *version = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!version) {
      version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    }
    if (!version) {
      version = @"2.4.2";
    }
  });
  return version;
}

static BOOL isRVADataType(NSString *type) {
  if (![type isKindOfClass:[NSString class]])
    return NO;
  return [[type lowercaseString] containsString:@"rva"];
}

@implementation VMDataSession

+ (BOOL)supportsSecureCoding {
  return YES;
}

+ (instancetype)sessionWithData:(NSArray *)dataItems
                       bundleID:(NSString *)bundleID
                       dataType:(NSString *)dataType {
  VMDataSession *session = [[self alloc] init];
  session.dataItems = dataItems;
  session.bundleID = bundleID;
  session.dataType = dataType;
  session.createdAt = [[NSDate date] timeIntervalSince1970];

  if (bundleID && bundleID.length > 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id proxy = [NSClassFromString(@"LSApplicationProxy")
        performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")
             withObject:bundleID];
    if (proxy) {
      NSString *name =
          [proxy performSelector:NSSelectorFromString(@"localizedName")];
      NSString *ver =
          [proxy performSelector:NSSelectorFromString(@"shortVersionString")];
      if (!ver)
        ver = [proxy performSelector:NSSelectorFromString(@"bundleVersion")];
      if (name)
        session.appName = name;
      if (ver)
        session.appVersion = ver;
    }
#pragma clang diagnostic pop
  }
  return session;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  if (self = [super init]) {
    _appName = [coder decodeObjectOfClass:[NSString class] forKey:@"appName"];
    _bundleID = [coder decodeObjectOfClass:[NSString class] forKey:@"bundleID"];
    _appVersion = [coder decodeObjectOfClass:[NSString class]
                                      forKey:@"appVersion"];
    _createdAt = [coder decodeDoubleForKey:@"createdAt"];
    _dataType = [coder decodeObjectOfClass:[NSString class] forKey:@"dataType"];

    NSSet *classes =
        [NSSet setWithObjects:[NSArray class], NSClassFromString(@"VMRVAPatch"),
                              [VMPointerChain class], [VMSignatureModel class],
                              [VMScriptModel class], [NSString class],
                              [NSNumber class], nil];
    _dataItems = [coder decodeObjectOfClasses:classes forKey:@"dataItems"];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeObject:_appName forKey:@"appName"];
  [coder encodeObject:_bundleID forKey:@"bundleID"];
  [coder encodeObject:_appVersion forKey:@"appVersion"];
  [coder encodeDouble:_createdAt forKey:@"createdAt"];
  [coder encodeObject:_dataItems forKey:@"dataItems"];
  [coder encodeObject:_dataType forKey:@"dataType"];
}

#pragma mark - Serialization Public Methods

- (NSData *)_toJSONDataWithForceImported:(BOOL)forceImported {
  NSMutableDictionary *jsonDict = [NSMutableDictionary dictionary];
  
  jsonDict[@"version"] = getCurrentVersion();
  
  if (self.dataType)
    jsonDict[@"dataType"] = self.dataType;
  if (self.bundleID)
    jsonDict[@"bundleID"] = self.bundleID;
  if (self.appName)
    jsonDict[@"appName"] = self.appName;
  if (self.appVersion)
    jsonDict[@"appVersion"] = self.appVersion;

  NSMutableArray *itemsArray = [NSMutableArray array];
  for (id item in self.dataItems) {
    if ([item respondsToSelector:@selector(toDictionary)]) {
      NSMutableDictionary *dict =
          [[item performSelector:@selector(toDictionary)] mutableCopy];

      if ([item isKindOfClass:[VMPointerChain class]]) {
        dict[@"type"] = @"pointer";
      } else if ([item isKindOfClass:[VMRVAPatch class]]) {
        dict[@"type"] = @"rva";
      } else if ([item isKindOfClass:[VMSignatureModel class]]) {
        dict[@"type"] = @"signature";
      } else if ([item isKindOfClass:[VMScriptModel class]]) {
        dict[@"type"] = @"script";
      }

      if (forceImported) {
        dict[@"isImported"] = @(YES);
      }

      [itemsArray addObject:dict];
    }
  }
  jsonDict[@"dataItems"] = itemsArray;

  NSError *error;
  NSData *data = [NSJSONSerialization dataWithJSONObject:jsonDict
                                                 options:0
                                                   error:&error];
  if (error)
    return nil;

  return data;
}

- (NSData *)toJSONData {
  return [self _toJSONDataWithForceImported:NO];
}

- (NSData *)toJSONDataForExport {
  return [self _toJSONDataWithForceImported:YES];
}

+ (instancetype)fromJSONData:(NSData *)fileData {
  if (!fileData || fileData.length == 0)
    return nil;

  NSError *error;
  NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:fileData
                                                           options:0
                                                             error:&error];
  if (!jsonDict || error)
    return nil;

  VMDataSession *session = [[self alloc] init];
  session.dataType = jsonDict[@"dataType"] ?: @"unknown";
  session.bundleID = jsonDict[@"bundleID"] ?: @"com.unknown.app";
  session.appName = jsonDict[@"appName"] ?: @"Unknown App";
  session.appVersion = jsonDict[@"appVersion"] ?: @"1.0";

  NSArray *itemsArray = jsonDict[@"dataItems"];
  if (!itemsArray) {
    itemsArray = @[];
  }

  NSMutableArray *dataItems = [NSMutableArray array];

  for (NSDictionary *itemDict in itemsArray) {
    NSString *type = itemDict[@"type"];
    if ((!type || type.length == 0) && isRVADataType(session.dataType)) {
      type = @"rva";
    }

    if ([type isEqualToString:@"pointer"]) {
      VMPointerChain *chain = [VMPointerChain fromDictionary:itemDict];
      if (chain) {
        [dataItems addObject:chain];
      }
    } else if ([type isEqualToString:@"rva"]) {
      VMRVAPatch *patch = [VMRVAPatch fromDictionary:itemDict];
      if (patch) {
        [dataItems addObject:patch];
      }
    } else if ([type isEqualToString:@"signature"]) {
      VMSignatureModel *sig = [VMSignatureModel fromDictionary:itemDict];
      if (sig) {
        [dataItems addObject:sig];
      }
    } else if ([type isEqualToString:@"script"]) {
      VMScriptModel *sc = [VMScriptModel fromDictionary:itemDict];
      if (sc) {
        [dataItems addObject:sc];
      }
    }
  }
  
  if (session.bundleID && session.bundleID.length > 0) {
    for (id item in dataItems) {
      if ([item respondsToSelector:@selector(setBundleID:)]) {
        NSString *itemBid = nil;
        if ([item respondsToSelector:@selector(bundleID)]) {
          itemBid = [item performSelector:@selector(bundleID)];
        }
        if (!itemBid || itemBid.length == 0) {
          [item performSelector:@selector(setBundleID:)
                     withObject:session.bundleID];
        }
      }
    }
  }
  session.dataItems = dataItems;
  return session;
}

- (NSData *)toVerifierJSONData {
  NSMutableDictionary *jsonDict = [NSMutableDictionary dictionary];
  
  jsonDict[@"version"] = getCurrentVersion();
  
  if (self.bundleID)
    jsonDict[@"bundleID"] = self.bundleID;
  if (self.appName)
    jsonDict[@"appName"] = self.appName;
  if (self.appVersion)
    jsonDict[@"appVersion"] = self.appVersion;

  NSMutableArray *itemsArray = [NSMutableArray array];
  for (id item in self.dataItems) {
    if ([item isKindOfClass:[VMPointerChain class]]) {
      VMPointerChain *chain = (VMPointerChain *)item;
      if (chain.isSignatureMode) {
        
        [itemsArray addObject:@{
          @"type" : @"pointer",
          @"isSignatureMode" : @YES,
          @"signature" : chain.signature ?: @""
        }];
      } else {
        
        [itemsArray addObject:@{
          @"type" : @"pointer",
          @"moduleName" : chain.moduleName ?: @"",
          @"baseOffset" : @(chain.baseOffset),
          @"offsets" : chain.offsets ?: @[]
        }];
      }
    }
  }
  jsonDict[@"dataItems"] = itemsArray;
  jsonDict[@"createdAt"] = @(self.createdAt);

  NSError *error;
  NSData *data = [NSJSONSerialization dataWithJSONObject:jsonDict
                                                 options:0
                                                   error:&error];
  if (error)
    return nil;

  return data;
}

+ (instancetype)fromVerifierJSONData:(NSData *)fileData {
  if (!fileData || fileData.length == 0)
    return nil;

  NSError *error;
  NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:fileData
                                                           options:0
                                                             error:&error];
  if (!jsonDict || ![jsonDict isKindOfClass:[NSDictionary class]])
    return nil;

  VMDataSession *session = [[self alloc] init];
  session.dataType = jsonDict[@"dataType"] ?: @"unknown";
  session.bundleID = jsonDict[@"bundleID"] ?: @"com.unknown.app";
  session.appName = jsonDict[@"appName"] ?: @"Unknown App";
  session.appVersion = jsonDict[@"appVersion"] ?: @"1.0";

  NSArray *itemsArray = jsonDict[@"dataItems"];
  NSMutableArray *dataItems = [NSMutableArray array];
  for (NSDictionary *itemDict in itemsArray) {
    NSString *type = itemDict[@"type"];

    if (!type || type.length == 0) {
      type = isRVADataType(session.dataType) ? @"rva" : @"pointer";
    }

    if ([type isEqualToString:@"pointer"]) {
      VMPointerChain *chain = [VMPointerChain fromDictionary:itemDict];
      if (chain)
        [dataItems addObject:chain];
    } else if ([type isEqualToString:@"rva"]) {
      VMRVAPatch *patch = [VMRVAPatch fromDictionary:itemDict];
      if (patch)
        [dataItems addObject:patch];
    } else if ([type isEqualToString:@"signature"]) {
      VMSignatureModel *sig = [VMSignatureModel fromDictionary:itemDict];
      if (sig)
        [dataItems addObject:sig];
    }
  }
  
  if (session.bundleID && session.bundleID.length > 0) {
    for (id item in dataItems) {
      if ([item respondsToSelector:@selector(setBundleID:)]) {
        if (![item performSelector:@selector(bundleID)]) {
          [item performSelector:@selector(setBundleID:)
                     withObject:session.bundleID];
        }
      }
    }
  }
  session.dataItems = dataItems;
  session.createdAt = [jsonDict[@"createdAt"] doubleValue];
  return session;
}

#pragma mark - [v2.6] Binary Format for High Performance

#define VMBP_MAGIC 0x564D4250
#define VMBP_VERSION 1
#define VMBP_HEADER_SIZE 64
#define VMBP_ITEM_SIZE 128
#define VMBP_MODULE_NAME_SIZE 64
#define VMBP_MAX_OFFSETS 13

- (NSData *)toVerifierBinaryData {
  if (!self.dataItems || self.dataItems.count == 0) {
    return nil;
  }
  
  NSMutableArray<VMPointerChain *> *chains = [NSMutableArray array];
  for (id item in self.dataItems) {
    if ([item isKindOfClass:[VMPointerChain class]]) {
      VMPointerChain *chain = (VMPointerChain *)item;
      
      if (!chain.isSignatureMode) {
        [chains addObject:chain];
      }
    }
  }
  
  if (chains.count == 0) {
    return nil;
  }
  
  NSData *bundleIDData = [self.bundleID dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  NSData *appNameData = [self.appName dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  NSData *appVersionData = [self.appVersion dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  
  size_t totalSize = VMBP_HEADER_SIZE + 
                     bundleIDData.length + appNameData.length + appVersionData.length +
                     chains.count * VMBP_ITEM_SIZE;
  
  NSMutableData *data = [NSMutableData dataWithLength:totalSize];
  uint8_t *ptr = (uint8_t *)data.mutableBytes;
  
  uint32_t magic = VMBP_MAGIC;
  uint32_t version = VMBP_VERSION;
  uint32_t itemCount = (uint32_t)chains.count;
  uint32_t bundleIDLen = (uint32_t)bundleIDData.length;
  uint32_t appNameLen = (uint32_t)appNameData.length;
  uint32_t appVersionLen = (uint32_t)appVersionData.length;
  double createdAt = self.createdAt;
  
  memcpy(ptr + 0, &magic, 4);
  memcpy(ptr + 4, &version, 4);
  memcpy(ptr + 8, &itemCount, 4);
  memcpy(ptr + 12, &bundleIDLen, 4);
  memcpy(ptr + 16, &appNameLen, 4);
  memcpy(ptr + 20, &appVersionLen, 4);
  memcpy(ptr + 24, &createdAt, 8);
  
  size_t offset = VMBP_HEADER_SIZE;
  
  if (bundleIDData.length > 0) {
    memcpy(ptr + offset, bundleIDData.bytes, bundleIDData.length);
    offset += bundleIDData.length;
  }
  if (appNameData.length > 0) {
    memcpy(ptr + offset, appNameData.bytes, appNameData.length);
    offset += appNameData.length;
  }
  if (appVersionData.length > 0) {
    memcpy(ptr + offset, appVersionData.bytes, appVersionData.length);
    offset += appVersionData.length;
  }
  
  for (VMPointerChain *chain in chains) {
    uint8_t *itemPtr = ptr + offset;
    memset(itemPtr, 0, VMBP_ITEM_SIZE);
    
    NSData *moduleData = [chain.moduleName dataUsingEncoding:NSUTF8StringEncoding];
    if (moduleData && moduleData.length > 0) {
      size_t copyLen = MIN(moduleData.length, VMBP_MODULE_NAME_SIZE - 1);
      memcpy(itemPtr, moduleData.bytes, copyLen);
    }
    
    uint64_t baseOffset = chain.baseOffset;
    memcpy(itemPtr + 64, &baseOffset, 8);
    
    uint16_t offsetCount = (uint16_t)MIN(chain.offsets.count, VMBP_MAX_OFFSETS);
    uint16_t chainType = (uint16_t)chain.chainType;
    memcpy(itemPtr + 72, &offsetCount, 2);
    memcpy(itemPtr + 74, &chainType, 2);
    
    for (uint16_t i = 0; i < offsetCount; i++) {
      int32_t off = [chain.offsets[i] intValue];
      memcpy(itemPtr + 76 + i * 4, &off, 4);
    }
    
    offset += VMBP_ITEM_SIZE;
  }
  
  return data;
}

+ (instancetype)fromVerifierBinaryData:(NSData *)fileData {
  NSData *data = fileData;
  if (!data || data.length < VMBP_HEADER_SIZE) {
    return nil;
  }
  
  const uint8_t *ptr = (const uint8_t *)data.bytes;
  
  uint32_t magic, version, itemCount, bundleIDLen, appNameLen, appVersionLen;
  double createdAt;
  
  memcpy(&magic, ptr + 0, 4);
  memcpy(&version, ptr + 4, 4);
  memcpy(&itemCount, ptr + 8, 4);
  memcpy(&bundleIDLen, ptr + 12, 4);
  memcpy(&appNameLen, ptr + 16, 4);
  memcpy(&appVersionLen, ptr + 20, 4);
  memcpy(&createdAt, ptr + 24, 8);
  
  if (magic != VMBP_MAGIC) {
    return nil;
  }
  
  if (version > VMBP_VERSION) {
    return nil;  
  }
  
  size_t expectedSize = VMBP_HEADER_SIZE + bundleIDLen + appNameLen + appVersionLen + itemCount * VMBP_ITEM_SIZE;
  if (data.length < expectedSize) {
    return nil;
  }
  
  VMDataSession *session = [[self alloc] init];
  session.createdAt = createdAt;
  
  size_t offset = VMBP_HEADER_SIZE;
  
  if (bundleIDLen > 0) {
    session.bundleID = [[NSString alloc] initWithBytes:ptr + offset length:bundleIDLen encoding:NSUTF8StringEncoding];
    offset += bundleIDLen;
  }
  if (appNameLen > 0) {
    session.appName = [[NSString alloc] initWithBytes:ptr + offset length:appNameLen encoding:NSUTF8StringEncoding];
    offset += appNameLen;
  }
  if (appVersionLen > 0) {
    session.appVersion = [[NSString alloc] initWithBytes:ptr + offset length:appVersionLen encoding:NSUTF8StringEncoding];
    offset += appVersionLen;
  }
  
  NSMutableArray<VMPointerChain *> *chains = [NSMutableArray arrayWithCapacity:itemCount];
  
  for (uint32_t i = 0; i < itemCount; i++) {
    const uint8_t *itemPtr = ptr + offset;
    
    VMPointerChain *chain = [[VMPointerChain alloc] init];
    
    char moduleNameBuf[VMBP_MODULE_NAME_SIZE];
    memcpy(moduleNameBuf, itemPtr, VMBP_MODULE_NAME_SIZE);
    moduleNameBuf[VMBP_MODULE_NAME_SIZE - 1] = '\0';
    chain.moduleName = [NSString stringWithUTF8String:moduleNameBuf];
    
    uint64_t baseOffset;
    memcpy(&baseOffset, itemPtr + 64, 8);
    chain.baseOffset = baseOffset;
    
    uint16_t offsetCount, chainType;
    memcpy(&offsetCount, itemPtr + 72, 2);
    memcpy(&chainType, itemPtr + 74, 2);
    chain.chainType = (VMPointerChainType)chainType;
    
    NSMutableArray *offsets = [NSMutableArray arrayWithCapacity:offsetCount];
    for (uint16_t j = 0; j < offsetCount && j < VMBP_MAX_OFFSETS; j++) {
      int32_t off;
      memcpy(&off, itemPtr + 76 + j * 4, 4);
      [offsets addObject:@(off)];
    }
    chain.offsets = offsets;
    
    chain.bundleID = session.bundleID;
    
    [chains addObject:chain];
    offset += VMBP_ITEM_SIZE;
  }
  
  session.dataItems = chains;
  session.dataType = @"pointer";
  
  return session;
}

+ (instancetype)fromVerifierData:(NSData *)data {
  if (!data || data.length < 4) {
    return nil;
  }
  
  uint32_t innerMagic;
  [data getBytes:&innerMagic length:4];
  
  if (innerMagic == VMBP_MAGIC) {
    
    return [self fromVerifierBinaryData:data];
  } else {
    
    return [self fromVerifierJSONData:data];
  }
}

@end
