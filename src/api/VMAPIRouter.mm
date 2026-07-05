//
// VMAPIRouter.mm
// 所有 HTTP API 路由注册 + 业务处理
//

#import "VMAPIRouter.h"
#import "VMHTTPServer.h"
#import "include/VMMemoryEngine.h"
#import "include/VMLockManager.h"
#import "include/VMPointerManager.h"
#import "include/VMPointerChain.h"
#import "include/VMRVAPatch.h"
#import "src/core/SystemCore.hpp"

// ============================================================
// JSON 辅助宏
// ============================================================
static inline NSDictionary *_ok(id data) {
    return @{@"code": @0, @"data": data ?: [NSNull null]};
}
static inline NSDictionary *_err(NSString *msg) {
    return @{@"code": @(-1), @"error": msg};
}
static NSData *_readBody(VMHTTPRequest *req) {
    return [req.body dataUsingEncoding:NSUTF8StringEncoding];
}
static NSDictionary *_parseJSON(VMHTTPRequest *req) {
    if (!req.body.length) return nil;
    NSData *d = _readBody(req);
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

// ============================================================
// 类型转换: 字符串 -> VMDataType
// ============================================================
static VMDataType _typeFromString(NSString *s) {
    if (!s) return VMDataTypeInt32;
    s = [s lowercaseString];
    if ([s isEqualToString:@"int8"]   || [s isEqualToString:@"i8"])  return VMDataTypeInt8;
    if ([s isEqualToString:@"int16"]  || [s isEqualToString:@"i16"]) return VMDataTypeInt16;
    if ([s isEqualToString:@"int32"]  || [s isEqualToString:@"i32"]) return VMDataTypeInt32;
    if ([s isEqualToString:@"int64"]  || [s isEqualToString:@"i64"]) return VMDataTypeInt64;
    if ([s isEqualToString:@"uint8"]  || [s isEqualToString:@"u8"])  return VMDataTypeUInt8;
    if ([s isEqualToString:@"uint16"] || [s isEqualToString:@"u16"]) return VMDataTypeUInt16;
    if ([s isEqualToString:@"uint32"] || [s isEqualToString:@"u32"]) return VMDataTypeUInt32;
    if ([s isEqualToString:@"uint64"] || [s isEqualToString:@"u64"]) return VMDataTypeUInt64;
    if ([s isEqualToString:@"float"]  || [s isEqualToString:@"f32"]) return VMDataTypeFloat;
    if ([s isEqualToString:@"double"] || [s isEqualToString:@"f64"]) return VMDataTypeDouble;
    if ([s isEqualToString:@"string"] || [s isEqualToString:@"str"]) return VMDataTypeString;
    return VMDataTypeInt32;
}

static NSString *_typeToString(VMDataType t) {
    switch (t) {
        case VMDataTypeInt8:   return @"int8";
        case VMDataTypeInt16:  return @"int16";
        case VMDataTypeInt32:  return @"int32";
        case VMDataTypeInt64:  return @"int64";
        case VMDataTypeUInt8:  return @"uint8";
        case VMDataTypeUInt16: return @"uint16";
        case VMDataTypeUInt32: return @"uint32";
        case VMDataTypeUInt64: return @"uint64";
        case VMDataTypeFloat:  return @"float";
        case VMDataTypeDouble: return @"double";
        case VMDataTypeString: return @"string";
        default: return @"unknown";
    }
}

// ============================================================
// 结果转换
// ============================================================
static NSDictionary *_resultItemToJSON(VMScanResultItem *item, VMDataType type) {
    return @{
        @"address":  [NSString stringWithFormat:@"0x%llX", item.address],
        @"type":     _typeToString(type),
        @"value":    item.valueStr ?: @""
    };
}

static NSDictionary *_moduleToJSON(VMModuleInfo *m) {
    return @{
        @"name":        m.name ?: @"",
        @"path":        m.path ?: @"",
        @"loadAddress": [NSString stringWithFormat:@"0x%llX", m.loadAddress],
        @"size":        @(m.size)
    };
}

static NSDictionary *_chainToJSON(VMPointerChain *c) {
    return @{
        @"moduleName":     c.moduleName ?: @"",
        @"baseOffset":     [NSString stringWithFormat:@"0x%llX", c.baseOffset],
        @"offsets":        c.offsets ?: @[],
        @"lastKnownValue": @(c.lastKnownValue),
        @"note":           c.note ?: @"",
        @"type":           c.type ?: @"int32",
        @"lockEnabled":    @(c.lockEnabled),
        @"lockValue":      c.lockValue ?: @""
    };
}

static NSDictionary *_patchToJSON(VMRVAPatch *p) {
    return @{
        @"moduleName":  p.moduleName ?: @"",
        @"offset":      [NSString stringWithFormat:@"0x%llX", p.offset],
        @"patchHex":    p.patchHex ?: @"",
        @"originalHex": p.originalHex ?: @"",
        @"isOn":        @(p.isOn),
        @"note":        p.note ?: @"",
        @"bundleID":    p.bundleID ?: @""
    };
}

// ============================================================
// VMAPIRouter
// ============================================================
@implementation VMAPIRouter

+ (void)registerAllRoutes {
    VMHTTPServer *srv = [VMHTTPServer shared];

    // ---- 基础 ----
    [srv on:@"GET"  path:@"/api/status"    handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleStatus:req respond:ok];
    }];
    [srv on:@"GET"  path:@"/api/processes" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleProcessList:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/attach"    handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleAttach:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/detach"    handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleDetach:req respond:ok];
    }];

    // ---- 内存搜索 ----
    [srv on:@"POST" path:@"/api/search/init"   handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleSearchInit:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/search/next"   handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleSearchNext:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/search/filter" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleSearchFilter:req respond:ok];
    }];
    [srv on:@"GET"  path:@"/api/search/results" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleSearchResults:req respond:ok];
    }];

    // ---- 内存读写 ----
    [srv on:@"POST" path:@"/api/memory/read"     handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleMemoryRead:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/memory/read/raw" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleMemoryReadRaw:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/memory/write"    handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleMemoryWrite:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/memory/write/raw" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleMemoryWriteRaw:req respond:ok];
    }];

    // ---- 模块 ----
    [srv on:@"GET" path:@"/api/modules" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleModules:req respond:ok];
    }];

    // ---- 特征码扫描 ----
    [srv on:@"POST" path:@"/api/signature/scan" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleSignatureScan:req respond:ok];
    }];

    // ---- 指针链 ----
    [srv on:@"POST" path:@"/api/pointer/search" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handlePointerSearch:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/pointer/chain"  handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handlePointerChain:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/pointer/resolve" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handlePointerResolve:req respond:ok];
    }];

    // ---- 锁定管理 ----
    [srv on:@"GET"  path:@"/api/locks"        handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleLockList:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/locks/add"    handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleLockAdd:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/locks/remove" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleLockRemove:req respond:ok];
    }];

    // ---- 快照 ----
    [srv on:@"POST" path:@"/api/snapshot/take"    handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleSnapshotTake:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/snapshot/baseline" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleSnapshotBaseline:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/snapshot/compare"  handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleSnapshotCompare:req respond:ok];
    }];

    // ---- RVA 补丁 ----
    [srv on:@"GET"  path:@"/api/rva/list"   handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleRVAList:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/rva/apply"  handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleRVAApply:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/rva/add"    handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleRVAAdd:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/rva/remove" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleRVARemove:req respond:ok];
    }];

    // ---- 快照备份 ----
    [srv on:@"POST" path:@"/api/timeline/capture" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleTimelineCapture:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/timeline/restore" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleTimelineRestore:req respond:ok];
    }];

    // ---- 快速模糊 ----
    [srv on:@"POST" path:@"/api/fuzzy/init"   handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleFuzzyInit:req respond:ok];
    }];
    [srv on:@"POST" path:@"/api/fuzzy/filter" handler:^(VMHTTPRequest *req, void (^ok)(int, NSDictionary *)) {
        [self handleFuzzyFilter:req respond:ok];
    }];
}

+ (nullable NSString *)startServerOnPort:(uint16_t)port {
    return [[VMHTTPServer shared] startOnPort:port];
}

+ (void)stopServer {
    [[VMHTTPServer shared] stop];
}

+ (nullable NSString *)serverURL {
    return [VMHTTPServer shared].serverURL;
}

// ============================================================
// 处理器实现
// ============================================================

#pragma mark - 状态

+ (void)handleStatus:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    NSDictionary *status = @{
        @"serverRunning": @([[VMHTTPServer shared] isRunning]),
        @"version":       @"3.1.2",
        @"attached":      @(eng.targetPid != 0),
        @"pid":           @(eng.targetPid),
        @"processName":   eng.currentProcessName ?: @"",
        @"bundleID":      eng.currentBundleID ?: @"",
        @"resultCount":   @(eng.resultCount),
        @"currentType":   _typeToString(eng.currentDataType),
        @"jailbroken":    @([eng isDeviceJailbroken])
    };
    respond(200, _ok(status));
}

#pragma mark - 进程列表

+ (void)handleProcessList:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    auto procList = VMCore::SystemCore::getInstance().getProcessList();
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:procList.size()];
    for (auto &p : procList) {
        [arr addObject:@{
            @"pid":      @(p.pid),
            @"name":     [NSString stringWithUTF8String:p.name.c_str()],
            @"bundleID": [NSString stringWithUTF8String:p.bundleID.c_str()],
            @"path":     [NSString stringWithUTF8String:p.path.c_str()]
        }];
    }
    respond(200, _ok(arr));
}

#pragma mark - 附加

+ (void)handleAttach:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body) { respond(400, _err(@"缺少请求体")); return; }

    VMMemoryEngine *eng = [VMMemoryEngine shared];

    // 支持 pid 或 bundleID
    if (body[@"pid"]) {
        pid_t pid = (pid_t)[body[@"pid"] intValue];
        if ([eng attachToPid:pid]) {
            respond(200, _ok(@{@"pid": @(pid), @"processName": eng.currentProcessName ?: @""}));
        } else {
            respond(500, _err(@"附加进程失败"));
        }
    } else if (body[@"bundleID"]) {
        NSString *bid = body[@"bundleID"];
        int pid = VMCore::SystemCore::getInstance().getPidByBundleID([bid UTF8String]);
        if (pid <= 0) {
            respond(404, _err([NSString stringWithFormat:@"未找到进程: %@", bid]));
            return;
        }
        if ([eng attachToPid:pid]) {
            respond(200, _ok(@{@"pid": @(pid), @"bundleID": bid, @"processName": eng.currentProcessName ?: @""}));
        } else {
            respond(500, _err(@"附加进程失败"));
        }
    } else {
        respond(400, _err(@"需要 pid 或 bundleID"));
    }
}

#pragma mark - 断开

+ (void)handleDetach:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    [[VMMemoryEngine shared] clearSession];
    respond(200, _ok(@"已断开"));
}

#pragma mark - 初次搜索

+ (void)handleSearchInit:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"value"]) { respond(400, _err(@"缺少 value")); return; }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    NSString *value = [body[@"value"] description];
    VMDataType type = _typeFromString(body[@"type"]);
    VMSearchMode mode = VMSearchModeExact;
    if ([body[@"mode"] isEqualToString:@"fuzzy"])  mode = VMSearchModeFuzzy;
    if ([body[@"mode"] isEqualToString:@"group"])   mode = VMSearchModeGroup;
    if ([body[@"mode"] isEqualToString:@"between"]) mode = VMSearchModeBetween;

    [eng scanMemoryWithMode:mode valStr:value dataType:type fuzzyType:VMFuzzyChanged isNextSearch:NO completion:^(NSUInteger count, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            respond(200, _ok(@{@"count": @(count), @"msg": msg ?: @""}));
        });
    }];
}

#pragma mark - 再次搜索

+ (void)handleSearchNext:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"value"]) { respond(400, _err(@"缺少 value")); return; }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    NSString *value = [body[@"value"] description];
    VMDataType type = _typeFromString(body[@"type"]);

    // 模糊类型映射
    VMFuzzyType fuzzy = VMFuzzyChanged;
    NSString *ft = body[@"fuzzyType"];
    if ([ft isEqualToString:@"increasedBy"]) fuzzy = VMFuzzyIncreasedBy;
    else if ([ft isEqualToString:@"decreasedBy"]) fuzzy = VMFuzzyDecreasedBy;
    else if ([ft isEqualToString:@"increased"])   fuzzy = VMFuzzyGreater;
    else if ([ft isEqualToString:@"decreased"])   fuzzy = VMFuzzyLess;
    else if ([ft isEqualToString:@"unchanged"])   fuzzy = VMFuzzyUnchanged;

    [eng scanMemoryWithMode:VMSearchModeExact valStr:value dataType:type fuzzyType:fuzzy isNextSearch:YES completion:^(NSUInteger count, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            respond(200, _ok(@{@"count": @(count), @"msg": msg ?: @""}));
        });
    }];
}

#pragma mark - 过滤

+ (void)handleSearchFilter:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    VMFilterMode mode = VMFilterModeChanged;
    NSString *m = body[@"filterMode"];
    if ([m isEqualToString:@"less"])      mode = VMFilterModeLess;
    else if ([m isEqualToString:@"greater"])  mode = VMFilterModeGreater;
    else if ([m isEqualToString:@"between"])  mode = VMFilterModeBetween;
    else if ([m isEqualToString:@"increased"]) mode = VMFilterModeIncreased;
    else if ([m isEqualToString:@"decreased"]) mode = VMFilterModeDecreased;
    else if ([m isEqualToString:@"unchanged"]) mode = VMFilterModeUnchanged;

    VMDataType type = _typeFromString(body[@"type"]);
    NSString *val1 = [body[@"val1"] description] ?: @"";
    NSString *val2 = [body[@"val2"] description] ?: @"";

    [eng filterResultsWithMode:mode val1:val1 val2:val2 type:type completion:^(NSUInteger count, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            respond(200, _ok(@{@"count": @(count), @"msg": msg ?: @""}));
        });
    }];
}

#pragma mark - 搜索结果

+ (void)handleSearchResults:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    NSDictionary *q = req.query;
    NSUInteger offset = [q[@"offset"] unsignedIntegerValue];
    NSUInteger limit  = [q[@"limit"] unsignedIntegerValue] ?: 50;
    VMDataType type = _typeFromString(q[@"type"]);

    NSUInteger total = eng.resultCount;
    NSUInteger end = MIN(offset + limit, total);
    NSMutableArray *results = [NSMutableArray array];

    for (NSUInteger i = offset; i < end; i++) {
        VMScanResultItem *item = [eng getResultItemAtIndex:i dataType:type];
        if (item) [results addObject:_resultItemToJSON(item, type)];
    }

    respond(200, _ok(@{
        @"total":   @(total),
        @"offset":  @(offset),
        @"limit":   @(limit),
        @"results": results
    }));
}

#pragma mark - 内存读取

+ (void)handleMemoryRead:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"address"]) { respond(400, _err(@"缺少 address")); return; }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    uint64_t addr = strtoull([body[@"address"] UTF8String], NULL, 0);
    VMDataType type = _typeFromString(body[@"type"]);

    NSString *val = [eng readAddress:addr type:type];
    respond(200, _ok(@{
        @"address": [NSString stringWithFormat:@"0x%llX", addr],
        @"type": _typeToString(type),
        @"value": val ?: @""
    }));
}

#pragma mark - 读取原始字节

+ (void)handleMemoryReadRaw:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"address"] || !body[@"length"]) {
        respond(400, _err(@"缺少 address 或 length")); return;
    }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    uint64_t addr = strtoull([body[@"address"] UTF8String], NULL, 0);
    NSUInteger len = [body[@"length"] unsignedIntegerValue];
    if (len > 4096) len = 4096; // 限制单次读取

    NSData *data = [eng readRawMemory:addr length:len];
    NSString *hex = [self hexStringFromData:data];

    respond(200, _ok(@{
        @"address": [NSString stringWithFormat:@"0x%llX", addr],
        @"length": @(data.length),
        @"hex": hex ?: @""
    }));
}

#pragma mark - 写入内存

+ (void)handleMemoryWrite:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"address"] || !body[@"value"]) {
        respond(400, _err(@"缺少 address 或 value")); return;
    }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    uint64_t addr = strtoull([body[@"address"] UTF8String], NULL, 0);
    NSString *val = [body[@"value"] description];
    VMDataType type = _typeFromString(body[@"type"]);

    [eng writeAddress:addr value:val type:type];
    respond(200, _ok(@{@"address": [NSString stringWithFormat:@"0x%llX", addr], @"written": val}));
}

#pragma mark - 写入原始字节

+ (void)handleMemoryWriteRaw:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"address"] || !body[@"hexData"]) {
        respond(400, _err(@"缺少 address 或 hexData")); return;
    }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    uint64_t addr = strtoull([body[@"address"] UTF8String], NULL, 0);
    NSData *data = [eng dataFromHexString:body[@"hexData"]];

    BOOL ok = [eng writeRawData:data toAddress:addr];
    respond(ok ? 200 : 500, ok ? _ok(@"写入成功") : _err(@"写入失败"));
}

#pragma mark - 模块列表

+ (void)handleModules:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    NSArray<VMModuleInfo *> *modules = [eng loadRemoteModules];
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:modules.count];
    for (VMModuleInfo *m in modules) {
        [arr addObject:_moduleToJSON(m)];
    }
    respond(200, _ok(arr));
}

#pragma mark - 特征码扫描

+ (void)handleSignatureScan:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"signature"]) { respond(400, _err(@"缺少 signature")); return; }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    NSString *sig = body[@"signature"];
    uint64_t rangeStart = strtoull([body[@"rangeStart"] ?: @"0x100000000" UTF8String], NULL, 0);
    uint64_t rangeEnd   = strtoull([body[@"rangeEnd"] ?: @"0x200000000" UTF8String], NULL, 0);

    // 模块快速扫描
    if (body[@"module"]) {
        [eng fastScanSignature:sig inModule:body[@"module"] completion:^(NSArray<VMScanResultItem *> *results) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableArray *arr = [NSMutableArray array];
                for (VMScanResultItem *item in results) [arr addObject:_resultItemToJSON(item, VMDataTypeInt8)];
                respond(200, _ok(@{@"results": arr, @"count": @(arr.count)}));
            });
        }];
    } else {
        [eng scanSignature:sig rangeStart:rangeStart rangeEnd:rangeEnd completion:^(NSArray<VMScanResultItem *> *results) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableArray *arr = [NSMutableArray array];
                for (VMScanResultItem *item in results) [arr addObject:_resultItemToJSON(item, VMDataTypeInt8)];
                respond(200, _ok(@{@"results": arr, @"count": @(arr.count)}));
            });
        }];
    }
}

#pragma mark - 指针搜索

+ (void)handlePointerSearch:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"address"]) { respond(400, _err(@"缺少 address")); return; }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    uint64_t target = strtoull([body[@"address"] UTF8String], NULL, 0);
    uint64_t rangeStart = strtoull([body[@"rangeStart"] ?: @"0x100000000" UTF8String], NULL, 0);
    uint64_t rangeEnd   = strtoull([body[@"rangeEnd"] ?: @"0x200000000" UTF8String], NULL, 0);
    uint32_t maxOffset  = (uint32_t)[body[@"maxOffset"] unsignedIntValue] ?: 0x200;

    NSSet *targets = [NSSet setWithObject:@(target)];

    [eng scanPointersPointingToAddresses:targets rangeStart:rangeStart rangeEnd:rangeEnd maxOffset:maxOffset completion:^(NSArray<NSDictionary *> *results) {
        dispatch_async(dispatch_get_main_queue(), ^{
            respond(200, _ok(@{@"count": @(results.count), @"results": results}));
        });
    }];
}

#pragma mark - 指针链搜索

+ (void)handlePointerChain:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"address"]) { respond(400, _err(@"缺少 address")); return; }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    uint64_t target = strtoull([body[@"address"] UTF8String], NULL, 0);
    uint64_t heapStart = strtoull([body[@"heapStart"] ?: @"0x100000000" UTF8String], NULL, 0);
    uint64_t heapEnd   = strtoull([body[@"heapEnd"] ?: @"0x200000000" UTF8String], NULL, 0);
    uint64_t baseStart = strtoull([body[@"baseStart"] ?: @"0x100000000" UTF8String], NULL, 0);
    uint64_t baseEnd   = strtoull([body[@"baseEnd"] ?: @"0x140000000" UTF8String], NULL, 0);
    NSInteger maxLevels = [body[@"maxLevels"] integerValue] ?: 3;
    NSInteger maxPerLevel = [body[@"maxPerLevel"] integerValue] ?: 50;
    uint32_t maxOffset = (uint32_t)[body[@"maxOffset"] unsignedIntValue] ?: 0x500;

    [eng autoSearchPointerChain:target heapStart:heapStart heapEnd:heapEnd baseStart:baseStart baseEnd:baseEnd maxLevels:maxLevels maxPerLevel:maxPerLevel maxOffset:maxOffset selectedModule:nil progressBlock:nil completion:^(NSArray<NSArray *> *paths) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *chains = [NSMutableArray array];
            for (NSArray *path in paths) {
                NSMutableString *desc = [NSMutableString string];
                for (id item in path) {
                    if ([item isKindOfClass:[NSNumber class]]) {
                        [desc appendFormat:@"[0x%llX] ", [item unsignedLongLongValue]];
                    } else if ([item isKindOfClass:[NSString class]]) {
                        [desc appendFormat:@"%@ ", item];
                    }
                }
                [chains addObject:desc];
            }
            respond(200, _ok(@{@"count": @(chains.count), @"chains": chains}));
        });
    }];
}

#pragma mark - 解析指针

+ (void)handlePointerResolve:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"baseAddress"] || !body[@"offsets"]) {
        respond(400, _err(@"缺少 baseAddress 或 offsets")); return;
    }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    uint64_t baseAddr = strtoull([body[@"baseAddress"] UTF8String], NULL, 0);
    NSArray *offsetsRaw = body[@"offsets"];
    NSMutableArray *offsets = [NSMutableArray array];
    for (id o in offsetsRaw) {
        [offsets addObject:@([o unsignedLongLongValue])];
    }

    uint64_t result = [eng resolvePointerChain:baseAddr offsets:offsets];
    respond(200, _ok(@{
        @"baseAddress": [NSString stringWithFormat:@"0x%llX", baseAddr],
        @"offsets": offsetsRaw,
        @"result": [NSString stringWithFormat:@"0x%llX", result]
    }));
}

#pragma mark - 锁定列表

+ (void)handleLockList:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    NSMutableArray *items = [NSMutableArray array];

    for (VMPointerChain *c in eng.lockedItems) {
        if ([c isKindOfClass:[VMPointerChain class]]) {
            [items addObject:_chainToJSON(c)];
        }
    }
    respond(200, _ok(items));
}

#pragma mark - 添加锁定

+ (void)handleLockAdd:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"address"] || !body[@"value"]) {
        respond(400, _err(@"缺少 address 或 value")); return;
    }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    uint64_t addr = strtoull([body[@"address"] UTF8String], NULL, 0);
    NSString *val = [body[@"value"] description];
    VMDataType type = _typeFromString(body[@"type"]);

    // 直接写入内存 (VMMemoryEngine 本身没有直接锁 API，通过写入 + 定时重写实现)
    [eng writeAddress:addr value:val type:type];

    // 添加到锁列表
    VMPointerChain *chain = [[VMPointerChain alloc] init];
    chain.baseOffset = addr;
    chain.lockEnabled = YES;
    chain.lockValue = val;
    chain.type = _typeToString(type);
    chain.note = body[@"note"] ?: @"API Lock";

    [[VMLockManager shared] addPointerToLock:chain];

    respond(200, _ok(@{@"address": [NSString stringWithFormat:@"0x%llX", addr], @"value": val}));
}

#pragma mark - 移除锁定

+ (void)handleLockRemove:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"address"]) { respond(400, _err(@"缺少 address")); return; }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    uint64_t addr = strtoull([body[@"address"] UTF8String], NULL, 0);

    for (VMPointerChain *c in [eng.lockedItems copy]) {
        if ([c isKindOfClass:[VMPointerChain class]] && c.baseOffset == addr) {
            [[VMLockManager shared] removePointer:c];
            respond(200, _ok(@"移除成功"));
            return;
        }
    }
    respond(404, _err(@"未找到该锁定"));
}

#pragma mark - 快照

+ (void)handleSnapshotTake:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    [eng takeGlobalSnapshot];
    respond(200, _ok(@"快照已保存"));
}

+ (void)handleSnapshotBaseline:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    [eng saveBaselineSnapshot];
    respond(200, _ok(@"基线快照已保存"));
}

+ (void)handleSnapshotCompare:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    if (![eng hasBaselineSnapshot]) {
        respond(400, _err(@"无基线快照，请先调用 /api/snapshot/baseline"));
        return;
    }

    NSArray<NSDictionary *> *changes = [eng compareWithBaseline];
    respond(200, _ok(@{@"changes": changes ?: @[], @"count": @(changes.count)}));
}

#pragma mark - RVA 补丁

+ (void)handleRVAList:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    NSMutableArray *arr = [NSMutableArray array];
    for (VMRVAPatch *p in eng.rvaPatches) {
        [arr addObject:_patchToJSON(p)];
    }
    respond(200, _ok(arr));
}

+ (void)handleRVAApply:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"moduleName"] || !body[@"offset"] || !body[@"patchHex"]) {
        respond(400, _err(@"缺少 moduleName, offset, patchHex")); return;
    }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    // 查找模块基址
    uint64_t baseAddr = [eng findModuleBaseAddress:body[@"moduleName"]];
    if (baseAddr == 0) { respond(404, _err(@"模块未找到")); return; }

    uint64_t offset = strtoull([body[@"offset"] UTF8String], NULL, 0);
    uint64_t addr = baseAddr + offset;

    NSData *patchData = [eng dataFromHexString:body[@"patchHex"]];
    BOOL ok = [eng writeRawData:patchData toAddress:addr];

    // 保存到补丁列表
    VMRVAPatch *patch = [[VMRVAPatch alloc] init];
    patch.moduleName = body[@"moduleName"];
    patch.offset = offset;
    patch.patchHex = body[@"patchHex"];
    patch.originalHex = body[@"originalHex"] ?: @"";
    patch.isOn = [body[@"enable"] boolValue] ?: YES;
    patch.note = body[@"note"] ?: @"API Patch";
    patch.bundleID = eng.currentBundleID;
    [eng.rvaPatches addObject:patch];
    [eng saveRVAPatches];

    respond(ok ? 200 : 500, ok ? _ok(@"补丁已应用") : _err(@"写入失败"));
}

+ (void)handleRVAAdd:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || !body[@"moduleName"] || !body[@"offset"] || !body[@"patchHex"]) {
        respond(400, _err(@"缺少 moduleName, offset, patchHex")); return;
    }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    uint64_t offset = strtoull([body[@"offset"] UTF8String], NULL, 0);

    VMRVAPatch *patch = [[VMRVAPatch alloc] init];
    patch.moduleName = body[@"moduleName"];
    patch.offset = offset;
    patch.patchHex = body[@"patchHex"];
    patch.originalHex = body[@"originalHex"] ?: @"";
    patch.isOn = NO;
    patch.note = body[@"note"] ?: @"API Patch";
    patch.bundleID = eng.currentBundleID ?: body[@"bundleID"];

    [eng.rvaPatches addObject:patch];
    [eng saveRVAPatches];

    respond(200, _ok(@"补丁已保存"));
}

+ (void)handleRVARemove:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    if (!body || (!body[@"offset"] && !body[@"note"])) {
        respond(400, _err(@"需要 offset 或 note 来定位补丁")); return;
    }

    VMMemoryEngine *eng = [VMMemoryEngine shared];
    NSMutableArray *toRemove = [NSMutableArray array];

    for (VMRVAPatch *p in eng.rvaPatches) {
        if (body[@"offset"]) {
            uint64_t off = strtoull([body[@"offset"] UTF8String], NULL, 0);
            if (p.offset == off) [toRemove addObject:p];
        } else if (body[@"note"] && [p.note isEqualToString:body[@"note"]]) {
            [toRemove addObject:p];
        }
    }

    for (VMRVAPatch *p in toRemove) {
        [eng.rvaPatches removeObject:p];
    }
    [eng saveRVAPatches];

    respond(200, _ok(@{@"removed": @(toRemove.count)}));
}

#pragma mark - Timeline

+ (void)handleTimelineCapture:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    NSDictionary *body = _parseJSON(req);
    NSString *title = body[@"title"] ?: @"API Snapshot";
    NSString *detail = body[@"detail"] ?: @"";
    VMDataType type = _typeFromString(body[@"type"]);

    [eng captureMemoryTimelineWithTitle:title detail:detail dataType:type];
    respond(200, _ok(@"时间线快照已保存"));
}

+ (void)handleTimelineRestore:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    NSDictionary *body = _parseJSON(req);
    NSUInteger index = [body[@"index"] unsignedIntegerValue];

    BOOL ok = [eng restoreMemoryTimelineAtIndex:index];
    respond(ok ? 200 : 500, ok ? _ok(@"已恢复") : _err(@"恢复失败"));
}

#pragma mark - 快速模糊

+ (void)handleFuzzyInit:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    [eng fastFuzzyInitWithCompletion:^(BOOL success, NSString *msg, NSUInteger addrCount) {
        dispatch_async(dispatch_get_main_queue(), ^{
            respond(200, _ok(@{@"success": @(success), @"msg": msg ?: @"", @"addressCount": @(addrCount)}));
        });
    }];
}

+ (void)handleFuzzyFilter:(VMHTTPRequest *)req respond:(void (^)(int, NSDictionary *))respond {
    NSDictionary *body = _parseJSON(req);
    VMMemoryEngine *eng = [VMMemoryEngine shared];
    if (eng.targetPid <= 0) { respond(400, _err(@"未附加进程")); return; }

    VMFilterMode mode = VMFilterModeChanged;
    NSString *m = body[@"filterMode"];
    if ([m isEqualToString:@"increased"])   mode = VMFilterModeIncreased;
    else if ([m isEqualToString:@"decreased"]) mode = VMFilterModeDecreased;
    else if ([m isEqualToString:@"unchanged"]) mode = VMFilterModeUnchanged;

    VMDataType type = _typeFromString(body[@"type"]);

    [eng fastFuzzyFilterWithMode:mode dataType:type completion:^(NSUInteger count, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            respond(200, _ok(@{@"count": @(count), @"msg": msg ?: @""}));
        });
    }];
}

#pragma mark - 工具方法

+ (NSString *)hexStringFromData:(NSData *)data {
    if (!data.length) return @"";
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02X", bytes[i]];
    }
    return hex;
}

@end
