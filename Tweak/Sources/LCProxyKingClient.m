//
//  LCProxyKingClient.m
//  LCProxyTweak
//
//  Queen/King 免流协议客户端（JCE/WUP/PBProxy）。
//
#import "LCProxyKingClient.h"
#import "KPKCrypto.h"
#import "KPKQueenCore.h"

#import <stdlib.h>
#import <sys/time.h>
#import <string.h>
#import <zlib.h>

static NSString *const kPBProxyURL = @"https://pbprx.qq.com/";
static NSString *const kGUIDServant = @"trpc.mtt.guid.guid";
static NSString *const kGUIDFunc = @"/trpc.mtt.guid.guid/GetGuid";
static NSString *const kTokenServant = @"httpWupToken";
static NSString *const kTokenFunc = @"getTokenInfo";
static NSString *const kProxyServant = @"proxyip";
static NSString *const kProxyFunc = @"getIPListByRouter";
static NSString *const kReqKey = @"req";
static NSString *const kTokenReqType = @"MTT.TokenInfoReq";
static NSString *const kProxyReqType = @"MTT.RouteIPListReq";
static NSString *const kRspKey = @"rsp";
static NSString *const kTokenRspType = @"MTT.TokenInfoRsp";
static NSString *const kProxyRspType = @"MTT.RouteIPListRsp";

static NSString *const kCommKey = @"mvLBiZsiTbGwrfJB";
static NSString *const kKeyIDHex = @"a690d5f54b43ca535af266c3180769c7";

static NSArray<NSString *> *KPKDefaultWupURLs(void) {
    static NSArray<NSString *> *urls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        urls = @[
            @"http://qbwup.qq.com:8080/",
            @"http://wup.imtt.qq.com:8080/",
            @"http://iwup.mtt.qq.com/",
            @"http://xg-qbwup.qq.com/",
        ];
    });
    return urls;
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
static NSData *KPKDataFromHex(NSString *hex) {
    hex = [hex stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if (hex.length % 2) return nil;
    NSMutableData *d = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        NSString *b = [hex substringWithRange:NSMakeRange(i, 2)];
        unsigned int v = 0;
        NSScanner *sc = [NSScanner scannerWithString:b];
        [sc scanHexInt:&v];
        uint8_t byte = (uint8_t)v;
        [d appendBytes:&byte length:1];
    }
    return d;
}

static NSString *KPKHexUpper(NSData *d) {
    const uint8_t *b = d.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02X", b[i]];
    return s;
}

static NSString *KPKHexLower(const uint8_t *b, size_t len) {
    NSMutableString *s = [NSMutableString stringWithCapacity:len * 2];
    for (size_t i = 0; i < len; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSData *KPKRandomData(size_t len) {
    NSMutableData *d = [NSMutableData dataWithLength:len];
    arc4random_buf((void *)d.mutableBytes, len);
    return d;
}

static NSString *KPKCurrentMillis(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    long long ms = (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
    return [NSString stringWithFormat:@"%lld", ms];
}

// ---------------------------------------------------------------------------
// protobuf helpers（PBProxy GetGuid）
// ---------------------------------------------------------------------------
static NSData *pbVarint(uint64_t v) {
    NSMutableData *d = [NSMutableData data];
    while (1) {
        uint8_t b = v & 0x7F;
        v >>= 7;
        if (v) b |= 0x80;
        [d appendBytes:&b length:1];
        if (!v) break;
    }
    return d;
}

static NSData *pbTag(uint32_t field, uint32_t wire) {
    return pbVarint((field << 3) | wire);
}

static NSData *pbLen(uint32_t field, NSData *payload) {
    NSMutableData *d = [NSMutableData data];
    [d appendData:pbTag(field, 2)];
    [d appendData:pbVarint(payload.length)];
    [d appendData:payload];
    return d;
}

static NSData *pbVar(uint32_t field, uint64_t value) {
    NSMutableData *d = [NSMutableData data];
    [d appendData:pbTag(field, 0)];
    [d appendData:pbVarint(value)];
    return d;
}

static uint64_t pbReadVarint(NSData *d, NSUInteger *pos) {
    uint64_t val = 0;
    int shift = 0;
    const uint8_t *bytes = d.bytes;
    while (*pos < d.length && shift < 64) {
        uint8_t b = bytes[*pos]; *pos += 1;
        val |= (uint64_t)(b & 0x7F) << shift;
        if (!(b & 0x80)) return val;
        shift += 7;
    }
    return val;
}

static NSDictionary<NSNumber *, NSArray<NSDictionary *> *> *pbParseFields(NSData *d) {
    NSMutableDictionary<NSNumber *, NSMutableArray<NSDictionary *> *> *fields = [NSMutableDictionary dictionary];
    NSUInteger pos = 0;
    while (pos < d.length) {
        uint64_t key = pbReadVarint(d, &pos);
        uint32_t field = (uint32_t)(key >> 3);
        uint32_t wire = key & 7;
        if (wire == 0) {
            uint64_t v = pbReadVarint(d, &pos);
            NSMutableArray *arr = fields[@(field)] ?: [NSMutableArray array];
            [arr addObject:@{@"wire": @"v", @"value": @(v)}];
            fields[@(field)] = arr;
        } else if (wire == 2) {
            uint64_t len = pbReadVarint(d, &pos);
            if (pos + (NSUInteger)len > d.length) break;
            NSData *v = [d subdataWithRange:NSMakeRange(pos, (NSUInteger)len)];
            pos += (NSUInteger)len;
            NSMutableArray *arr = fields[@(field)] ?: [NSMutableArray array];
            [arr addObject:@{@"wire": @"b", @"value": v}];
            fields[@(field)] = arr;
        } else {
            break;
        }
    }
    return fields;
}

static NSData *pbGetBytes(NSDictionary *fields, uint32_t field) {
    for (NSDictionary *item in fields[@(field)] ?: @[]) {
        if ([item[@"wire"] isEqualToString:@"b"]) return item[@"value"];
    }
    return nil;
}

static NSNumber *pbGetVarint(NSDictionary *fields, uint32_t field) {
    for (NSDictionary *item in fields[@(field)] ?: @[]) {
        if ([item[@"wire"] isEqualToString:@"v"]) return item[@"value"];
    }
    return nil;
}

// ---------------------------------------------------------------------------
// JCE 写入/读取（Taf）
// ---------------------------------------------------------------------------
@interface KPKJce : NSObject
+ (NSData *)head:(uint8_t)type tag:(NSInteger)tag;
+ (NSData *)string:(NSString *)s tag:(NSInteger)tag;
+ (NSData *)intValue:(NSInteger)v tag:(NSInteger)tag;
+ (NSData *)shortValue:(NSInteger)v tag:(NSInteger)tag;
+ (NSData *)boolValue:(BOOL)b tag:(NSInteger)tag;
+ (NSData *)bytes:(NSData *)d tag:(NSInteger)tag;
+ (NSData *)map:(NSDictionary *)m tag:(NSInteger)tag;
+ (NSData *)listInts:(NSArray<NSNumber *> *)vals tag:(NSInteger)tag;
+ (NSData *)listStrings:(NSArray<NSString *> *)vals tag:(NSInteger)tag;
+ (NSData *)structWithFields:(NSData *)fields tag:(NSInteger)tag;
+ (int)readType:(NSData *)data pos:(NSUInteger *)pos tag:(NSInteger *)tag;
+ (id)readAny:(NSData *)data pos:(NSUInteger *)pos tag:(NSInteger *)tag;
+ (NSDictionary *)readFields:(NSData *)data pos:(NSUInteger *)pos;
+ (NSData *)stripStructWrapper:(NSData *)data;
@end

@implementation KPKJce

+ (NSData *)head:(uint8_t)type tag:(NSInteger)tag {
    NSMutableData *d = [NSMutableData dataWithCapacity:2];
    if (tag < 15) {
        uint8_t b = (uint8_t)(((tag & 0x0F) << 4) | (type & 0x0F));
        [d appendBytes:&b length:1];
    } else {
        uint8_t b0 = (uint8_t)(0xF0 | (type & 0x0F));
        uint8_t b1 = (uint8_t)tag;
        [d appendBytes:&b0 length:1];
        [d appendBytes:&b1 length:1];
    }
    return d;
}

+ (NSData *)string:(NSString *)s tag:(NSInteger)tag {
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 255) {
        NSMutableData *d = [NSMutableData data];
        [d appendData:[self head:7 tag:tag]];
        uint32_t len = (uint32_t)data.length;
        uint8_t lb[4] = { (uint8_t)(len >> 24), (uint8_t)((len >> 16) & 0xFF),
                          (uint8_t)((len >> 8) & 0xFF), (uint8_t)(len & 0xFF) };
        [d appendBytes:lb length:4];
        [d appendData:data];
        return d;
    }
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self head:6 tag:tag]];
    uint8_t len = (uint8_t)data.length;
    [d appendBytes:&len length:1];
    [d appendData:data];
    return d;
}

+ (NSData *)intValue:(NSInteger)v tag:(NSInteger)tag {
    if (v >= -128 && v <= 127) {
        if (v == 0) return [self head:12 tag:tag];
        NSMutableData *d = [NSMutableData data];
        [d appendData:[self head:0 tag:tag]];
        int8_t b = (int8_t)v;
        [d appendBytes:&b length:1];
        return d;
    }
    if (v >= -32768 && v <= 32767) {
        NSMutableData *d = [NSMutableData data];
        [d appendData:[self head:1 tag:tag]];
        int16_t s = (int16_t)v;
        uint8_t b[2] = { (uint8_t)(((uint16_t)s >> 8) & 0xFF), (uint8_t)((uint16_t)s & 0xFF) };
        [d appendBytes:b length:2];
        return d;
    }
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self head:2 tag:tag]];
    int32_t i = (int32_t)v;
    uint8_t b[4] = { (uint8_t)(((uint32_t)i >> 24) & 0xFF), (uint8_t)(((uint32_t)i >> 16) & 0xFF),
                     (uint8_t)(((uint32_t)i >> 8) & 0xFF), (uint8_t)((uint32_t)i & 0xFF) };
    [d appendBytes:b length:4];
    return d;
}

+ (NSData *)shortValue:(NSInteger)v tag:(NSInteger)tag {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self head:1 tag:tag]];
    int16_t s = (int16_t)v;
    uint8_t b[2] = { (uint8_t)(((uint16_t)s >> 8) & 0xFF), (uint8_t)((uint16_t)s & 0xFF) };
    [d appendBytes:b length:2];
    return d;
}

+ (NSData *)boolValue:(BOOL)b tag:(NSInteger)tag {
    if (!b) return [self head:12 tag:tag];
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self head:0 tag:tag]];
    uint8_t one = 1;
    [d appendBytes:&one length:1];
    return d;
}

+ (NSData *)bytes:(NSData *)d tag:(NSInteger)tag {
    NSMutableData *out = [NSMutableData data];
    [out appendData:[self head:13 tag:tag]];
    [out appendData:[self head:0 tag:0]];
    [out appendData:[self intValue:(NSInteger)d.length tag:0]];
    [out appendData:d];
    return out;
}

+ (NSData *)map:(NSDictionary *)m tag:(NSInteger)tag {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self head:8 tag:tag]];
    [d appendData:[self intValue:(NSInteger)m.count tag:0]];
    for (NSString *key in m) {
        [d appendData:[self string:key tag:0]];
        id value = m[key];
        if ([value isKindOfClass:[NSDictionary class]]) {
            [d appendData:[self map:value tag:1]];
        } else if ([value isKindOfClass:[NSData class]]) {
            [d appendData:[self bytes:value tag:1]];
        } else {
            [d appendData:[self string:value tag:1]];
        }
    }
    return d;
}

+ (NSData *)listInts:(NSArray<NSNumber *> *)vals tag:(NSInteger)tag {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self head:9 tag:tag]];
    [d appendData:[self intValue:(NSInteger)vals.count tag:0]];
    for (NSNumber *v in vals) [d appendData:[self intValue:v.integerValue tag:0]];
    return d;
}

+ (NSData *)listStrings:(NSArray<NSString *> *)vals tag:(NSInteger)tag {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self head:9 tag:tag]];
    [d appendData:[self intValue:(NSInteger)vals.count tag:0]];
    for (NSString *v in vals) [d appendData:[self string:v tag:0]];
    return d;
}

+ (NSData *)structWithFields:(NSData *)fields tag:(NSInteger)tag {
    NSMutableData *d = [NSMutableData data];
    [d appendData:[self head:10 tag:tag]];
    [d appendData:fields];
    [d appendData:[self head:11 tag:0]];
    return d;
}

+ (int)readType:(NSData *)data pos:(NSUInteger *)pos tag:(NSInteger *)tag {
    if (*pos >= data.length) return -1;
    const uint8_t *bytes = data.bytes;
    uint8_t b0 = bytes[*pos];
    *pos += 1;
    int type = b0 & 0x0F;
    NSInteger t = (b0 >> 4) & 0x0F;
    if (t == 15) {
        if (*pos >= data.length) return -1;
        t = bytes[*pos];
        *pos += 1;
    }
    if (tag) *tag = t;
    return type;
}

+ (id)readAnyWithType:(int)type tag:(NSInteger)tag data:(NSData *)data pos:(NSUInteger *)pos {
    const uint8_t *bytes = data.bytes;
    switch (type) {
        case 12: return @0;
        case 0: {
            if (*pos + 1 > data.length) return nil;
            int8_t v;
            memcpy(&v, bytes + *pos, 1); *pos += 1;
            return @(v);
        }
        case 1: {
            if (*pos + 2 > data.length) return nil;
            uint16_t u = ((uint16_t)bytes[*pos] << 8) | bytes[*pos + 1];
            *pos += 2;
            return @((int16_t)u);
        }
        case 2: {
            if (*pos + 4 > data.length) return nil;
            uint32_t u = ((uint32_t)bytes[*pos] << 24) | ((uint32_t)bytes[*pos + 1] << 16) |
                         ((uint32_t)bytes[*pos + 2] << 8) | bytes[*pos + 3];
            *pos += 4;
            return @((int32_t)u);
        }
        case 3: {
            if (*pos + 8 > data.length) return nil;
            uint64_t u = 0;
            for (int i = 0; i < 8; i++) u = (u << 8) | bytes[*pos + i];
            *pos += 8;
            return @((int64_t)u);
        }
        case 6: {
            if (*pos + 1 > data.length) return nil;
            NSUInteger n = bytes[*pos]; *pos += 1;
            if (*pos + n > data.length) return nil;
            NSData *d = [data subdataWithRange:NSMakeRange(*pos, n)];
            *pos += n;
            return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        }
        case 7: {
            if (*pos + 4 > data.length) return nil;
            NSUInteger n = ((NSUInteger)bytes[*pos] << 24) | ((NSUInteger)bytes[*pos + 1] << 16) |
                           ((NSUInteger)bytes[*pos + 2] << 8) | bytes[*pos + 3];
            *pos += 4;
            if (*pos + n > data.length) return nil;
            NSData *d = [data subdataWithRange:NSMakeRange(*pos, n)];
            *pos += n;
            return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        }
        case 13: {
            NSInteger dummyTag = 0;
            [self readType:data pos:pos tag:&dummyTag];
            NSInteger lenTag = 0;
            id lenObj = [self readAny:data pos:pos tag:&lenTag];
            NSUInteger n = [lenObj isKindOfClass:[NSNumber class]] ? (NSUInteger)[lenObj integerValue] : 0;
            if (*pos + n > data.length) return nil;
            NSData *d = [data subdataWithRange:NSMakeRange(*pos, n)];
            *pos += n;
            return d;
        }
        case 8: {
            NSInteger sizeTag = 0;
            id sizeObj = [self readAny:data pos:pos tag:&sizeTag];
            NSUInteger size = [sizeObj isKindOfClass:[NSNumber class]] ? (NSUInteger)[sizeObj integerValue] : 0;
            NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:size];
            for (NSUInteger i = 0; i < size; i++) {
                NSInteger kTag = 0, vTag = 0;
                id key = [self readAny:data pos:pos tag:&kTag];
                id value = [self readAny:data pos:pos tag:&vTag];
                if (key) out[key] = value ?: [NSNull null];
            }
            return out;
        }
        case 9: {
            NSInteger sizeTag = 0;
            id sizeObj = [self readAny:data pos:pos tag:&sizeTag];
            NSUInteger size = [sizeObj isKindOfClass:[NSNumber class]] ? (NSUInteger)[sizeObj integerValue] : 0;
            NSMutableArray *out = [NSMutableArray arrayWithCapacity:size];
            for (NSUInteger i = 0; i < size; i++) {
                NSInteger vTag = 0;
                id value = [self readAny:data pos:pos tag:&vTag];
                if (value) [out addObject:value];
            }
            return out;
        }
        case 10: {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            while (1) {
                NSInteger ftag = 0;
                int ftype = [self readType:data pos:pos tag:&ftag];
                if (ftype < 0) break;
                if (ftype == 11) break;
                id value = [self readAnyWithType:ftype tag:ftag data:data pos:pos];
                if (value) out[@(ftag)] = value;
            }
            return out;
        }
        default:
            return nil;
    }
}

+ (id)readAny:(NSData *)data pos:(NSUInteger *)pos tag:(NSInteger *)tag {
    NSInteger t = 0;
    int type = [self readType:data pos:pos tag:&t];
    if (type < 0) return nil;
    if (tag) *tag = t;
    return [self readAnyWithType:type tag:t data:data pos:pos];
}

+ (NSDictionary *)readFields:(NSData *)data pos:(NSUInteger *)pos {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    while (*pos < data.length) {
        NSInteger tag = 0;
        int type = [self readType:data pos:pos tag:&tag];
        if (type < 0 || type == 11) break;
        id value = [self readAnyWithType:type tag:tag data:data pos:pos];
        if (value) out[@(tag)] = value;
    }
    return out;
}

+ (NSData *)stripStructWrapper:(NSData *)data {
    if (data.length >= 2) {
        const uint8_t *b = data.bytes;
        if ((b[0] & 0x0F) == 10 && (b[data.length - 1] & 0x0F) == 11) {
            return [data subdataWithRange:NSMakeRange(1, data.length - 2)];
        }
    }
    return data;
}

@end

// ---------------------------------------------------------------------------
// WUP / Token / RouteIPList 请求构建
// ---------------------------------------------------------------------------
static NSData *KPKWupRequest(NSString *servant, NSString *func,
                             NSString *paramKey, NSString *paramType,
                             NSData *paramBytes, int reqId) {
    NSData *inner = [KPKJce map:@{ paramKey: @{ paramType: paramBytes } } tag:0];
    NSMutableData *packet = [NSMutableData data];
    [packet appendData:[KPKJce intValue:2 tag:1]];
    [packet appendData:[KPKJce intValue:0 tag:2]];
    [packet appendData:[KPKJce intValue:0 tag:3]];
    [packet appendData:[KPKJce intValue:reqId tag:4]];
    [packet appendData:[KPKJce string:servant tag:5]];
    [packet appendData:[KPKJce string:func tag:6]];
    [packet appendData:[KPKJce bytes:inner tag:7]];
    [packet appendData:[KPKJce intValue:0 tag:8]];
    [packet appendData:[KPKJce map:@{} tag:9]];
    [packet appendData:[KPKJce map:@{} tag:10]];

    uint32_t total = (uint32_t)packet.length + 4;
    NSMutableData *out = [NSMutableData dataWithCapacity:4 + packet.length];
    uint8_t lb[4] = { (uint8_t)(total >> 24), (uint8_t)((total >> 16) & 0xFF),
                      (uint8_t)((total >> 8) & 0xFF), (uint8_t)(total & 0xFF) };
    [out appendBytes:lb length:4];
    [out appendData:packet];
    return out;
}

static NSData *KPKTokenInfoReq(NSString *guid, NSString *qua2, NSString *phone) {
    NSMutableData *fields = [NSMutableData data];
    [fields appendData:[KPKJce string:guid tag:0]];
    [fields appendData:[KPKJce string:qua2 tag:1]];
    [fields appendData:[KPKJce string:phone tag:2]];
    return [KPKJce structWithFields:fields tag:0];
}

static NSData *KPKUserBase(NSString *guid, NSString *qua2, NSString *apn) {
    NSMutableData *fields = [NSMutableData data];
    [fields appendData:[KPKJce string:@"" tag:0]];
    [fields appendData:[KPKJce bytes:KPKDataFromHex(guid) tag:1]];
    [fields appendData:[KPKJce string:qua2 tag:2]];
    [fields appendData:[KPKJce string:@"" tag:3]];
    [fields appendData:[KPKJce string:@"" tag:4]];
    [fields appendData:[KPKJce string:@"" tag:5]];
    [fields appendData:[KPKJce string:@"" tag:6]];
    [fields appendData:[KPKJce intValue:2 tag:7]];
    [fields appendData:[KPKJce boolValue:YES tag:8]];
    [fields appendData:[KPKJce string:@"" tag:9]];
    [fields appendData:[KPKJce string:@"" tag:10]];
    [fields appendData:[KPKJce string:@"" tag:11]];
    [fields appendData:[KPKJce intValue:200 tag:12]];
    [fields appendData:[KPKJce shortValue:0 tag:13]];
    [fields appendData:[KPKJce shortValue:0 tag:14]];
    [fields appendData:[KPKJce string:apn tag:15]];
    [fields appendData:[KPKJce string:@"" tag:16]];
    [fields appendData:[KPKJce bytes:[NSData dataWithBytes:(uint8_t[]){0} length:1] tag:17]];
    [fields appendData:[KPKJce listInts:@[] tag:19]];
    [fields appendData:[KPKJce bytes:[NSData dataWithBytes:(uint8_t[]){0} length:1] tag:20]];
    [fields appendData:[KPKJce string:@"" tag:21]];
    [fields appendData:[KPKJce string:@"" tag:22]];
    [fields appendData:[KPKJce string:@"" tag:23]];
    return [KPKJce structWithFields:fields tag:0];
}

static NSData *KPKRouteIPListReq(NSString *guid, NSString *qua2, NSDictionary *p) {
    NSString *apn = p[@"apn"] ?: @"UNKNOW";
    NSString *typeName = p[@"typeName"] ?: @"UNKNOW";
    NSInteger subtype = [p[@"subtype"] isKindOfClass:[NSNumber class]] ? [p[@"subtype"] integerValue] : 0;
    NSString *extraInfo = p[@"extraInfo"] ?: @"UNKNOW";
    NSString *mccmnc = p[@"mccmnc"] ?: @"NULLNULL";
    NSInteger cardType = [p[@"cardType"] isKindOfClass:[NSNumber class]] ? [p[@"cardType"] integerValue] : 1;

    NSMutableData *fields = [NSMutableData data];
    [fields appendData:KPKUserBase(guid, qua2, apn)];
    [fields appendData:[KPKJce listInts:@[@15, @16] tag:1]];
    [fields appendData:[KPKJce string:typeName tag:2]];
    [fields appendData:[KPKJce intValue:subtype tag:3]];
    [fields appendData:[KPKJce string:extraInfo tag:4]];
    [fields appendData:[KPKJce string:mccmnc tag:5]];
    [fields appendData:[KPKJce intValue:cardType tag:6]];
    [fields appendData:[KPKJce listStrings:@[mccmnc] tag:7]];
    return [KPKJce structWithFields:fields tag:0];
}

static NSData *KPKPbCommonHeader(NSString *guid) {
    NSMutableData *plain = [NSMutableData data];
    [plain appendData:pbLen(1, [guid dataUsingEncoding:NSUTF8StringEncoding])];
    NSData *key = [kCommKey dataUsingEncoding:NSUTF8StringEncoding];
    size_t cap = ((plain.length / 16) + 1) * 16;
    NSMutableData *enc = [NSMutableData dataWithLength:cap];
    size_t enc_len = 0;
    if (kpk_aes_cbc_encrypt(plain.bytes, plain.length, key.bytes, key.length, key.bytes,
                            enc.mutableBytes, enc.length, &enc_len) != 0) {
        return nil;
    }
    enc.length = enc_len;
    NSMutableData *msg = [NSMutableData data];
    [msg appendData:pbVar(1, 2)];
    [msg appendData:pbVar(2, 1)];
    [msg appendData:pbLen(3, enc)];
    return msg;
}

static NSData *KPKGzipData(NSData *data) {
    uLongf cap = compressBound((uLongf)data.length);
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    size_t out_len = 0;
    if (kpk_gzip_compress(data.bytes, data.length, out.mutableBytes, out.length, &out_len) != 0) {
        return nil;
    }
    out.length = out_len;
    return out;
}

static NSData *KPKGunzipData(NSData *data) {
    size_t cap = data.length * 4 + 64;
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    size_t out_len = 0;
    while (1) {
        int rc = kpk_gzip_decompress(data.bytes, data.length, out.mutableBytes, out.length, &out_len);
        if (rc == 0) { out.length = out_len; return out; }
        if (cap >= 4 * 1024 * 1024) return nil;
        cap *= 2;
        out = [NSMutableData dataWithLength:cap];
    }
}

// ---------------------------------------------------------------------------
// 旧 WUP 加密信封
// ---------------------------------------------------------------------------
static NSDictionary *KPKBuildWupEnvelope(NSString *guid, NSString *qua2, NSData *wupBody, NSInteger mode) {
    NSData *gz = KPKGzipData(wupBody);
    if (!gz) return nil;

    NSData *aesKey = KPKRandomData(16);
    NSData *iv16 = nil;
    NSString *ivHex = nil;
    if (mode == 2) {
        NSData *iv8 = KPKRandomData(8);
        ivHex = KPKHexLower(iv8.bytes, iv8.length);
        iv16 = [ivHex dataUsingEncoding:NSUTF8StringEncoding];
    }

    size_t cap = ((gz.length / 16) + 1) * 16;
    NSMutableData *encBody = [NSMutableData dataWithLength:cap];
    size_t enc_len = 0;
    int rc;
    if (mode == 2) {
        rc = kpk_aes_cbc_encrypt(gz.bytes, gz.length, aesKey.bytes, aesKey.length,
                                 iv16.bytes, encBody.mutableBytes, encBody.length, &enc_len);
    } else {
        rc = kpk_aes_ecb_encrypt(gz.bytes, gz.length, aesKey.bytes, aesKey.length,
                                 encBody.mutableBytes, encBody.length, &enc_len);
    }
    if (rc != 0) return nil;
    encBody.length = enc_len;

    NSData *guidBytes = KPKDataFromHex(guid);
    if (!guidBytes || guidBytes.length != 16) return nil;
    cap = ((guidBytes.length / 16) + 1) * 16;
    NSMutableData *encGuid = [NSMutableData dataWithLength:cap];
    enc_len = 0;
    if (mode == 2) {
        rc = kpk_aes_cbc_encrypt(guidBytes.bytes, guidBytes.length, aesKey.bytes, aesKey.length,
                                 iv16.bytes, encGuid.mutableBytes, encGuid.length, &enc_len);
    } else {
        rc = kpk_aes_ecb_encrypt(guidBytes.bytes, guidBytes.length, aesKey.bytes, aesKey.length,
                                 encGuid.mutableBytes, encGuid.length, &enc_len);
    }
    if (rc != 0) return nil;
    encGuid.length = enc_len;

    uint8_t rsaOut[128];
    if (kpk_rsa_encrypt_aes_key(aesKey.bytes, (int)mode, rsaOut) != 0) return nil;
    NSString *qbkey = KPKHexLower(rsaOut, sizeof(rsaOut));

    NSMutableString *query = [NSMutableString string];
    [query appendFormat:@"encrypt=%@", mode == 2 ? @"17" : @"12"];
    [query appendFormat:@"&qbkey=%@", qbkey];
    [query appendString:@"&len=1024"];
    [query appendFormat:@"&id=%@", kKeyIDHex];
    [query appendString:@"&v=3"];
    if (mode == 2) [query appendFormat:@"&iv=%@", ivHex];

    NSData *commonHeader = KPKPbCommonHeader(guid);
    if (!commonHeader) return nil;

    NSMutableArray<NSString *> *headers = [NSMutableArray array];
    [headers addObject:@"Content-Type: application/multipart-formdata"];
    [headers addObject:@"User-Agent: MQQBrowser"];
    [headers addObject:@"Accept: */*"];
    [headers addObject:@"Accept-Encoding: identity"];
    [headers addObject:[NSString stringWithFormat:@"Q-GUID: %@", KPKHexUpper(encGuid)]];
    [headers addObject:[NSString stringWithFormat:@"Q-UA2: %@", qua2]];
    [headers addObject:[NSString stringWithFormat:@"Common-Header: %@", KPKHexUpper(commonHeader)]];
    [headers addObject:@"QQ-S-ZIP: gzip"];
    [headers addObject:[NSString stringWithFormat:@"Traceid: %@", KPKCurrentMillis()]];

    return @{
        @"query": query,
        @"headers": headers,
        @"body": encBody,
        @"aesKey": aesKey,
        @"ivHex": ivHex ?: @"",
        @"mode": @(mode),
    };
}

static BOOL KPKParseHttpURL(NSString *url, NSString **host, NSInteger *port, NSString **path) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u.host.length || ![u.scheme.lowercaseString isEqualToString:@"http"]) return NO;
    *host = u.host;
    *port = u.port ? u.port.integerValue : 80;
    *path = [NSString stringWithFormat:@"%@?%@", u.path.length ? u.path : @"/", u.query ?: @""];
    if (u.query.length == 0) *path = u.path.length ? u.path : @"/";
    return YES;
}

static NSString *KPKResponseHeader(NSData *resp, size_t respLen, NSString *name) {
    char buf[256];
    if (kpq_http_header(resp.bytes, respLen, name.UTF8String, buf, sizeof(buf))) {
        return [NSString stringWithUTF8String:buf] ?: @"";
    }
    return nil;
}

static NSData *KPKResponseBody(NSData *resp, size_t respLen) {
    int off = kpq_http_body_offset(resp.bytes, respLen);
    if (off < 0) return nil;
    return [resp subdataWithRange:NSMakeRange((NSUInteger)off, respLen - (NSUInteger)off)];
}

static NSDictionary *KPKParseWupResponse(NSData *plain, NSString *rspType) {
    if (plain.length < 4) return nil;
    const uint8_t *b = plain.bytes;
    uint32_t total = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    if (total != plain.length) return nil;

    NSUInteger pos = 4;
    NSDictionary *packet = [KPKJce readFields:plain pos:&pos];
    NSData *sbuf = packet[@7];
    if (![sbuf isKindOfClass:[NSData class]] || sbuf.length == 0) return nil;

    NSUInteger p2 = 0;
    NSInteger outerTag = 0;
    id outer = [KPKJce readAny:sbuf pos:&p2 tag:&outerTag];
    if (![outer isKindOfClass:[NSDictionary class]]) return nil;
    id rspMap = outer[kRspKey];
    if (![rspMap isKindOfClass:[NSDictionary class]]) return nil;
    NSData *rspBytes = rspMap[rspType];
    if (![rspBytes isKindOfClass:[NSData class]]) return nil;

    NSUInteger p3 = 0;
    NSInteger structTag = 0;
    id structValue = [KPKJce readAny:rspBytes pos:&p3 tag:&structTag];
    if ([structValue isKindOfClass:[NSDictionary class]]) return structValue;
    NSUInteger p4 = 0;
    return [KPKJce readFields:rspBytes pos:&p4];
}

// ---------------------------------------------------------------------------
// 网络发送与解析
// ---------------------------------------------------------------------------
static NSDictionary *KPKSendWupAndParse(NSString *guid, NSString *qua2, NSData *wupBody,
                                        NSString *rspType, NSArray<NSString *> *servers,
                                        NSTimeInterval timeout) {
    for (NSNumber *mode in @[@1, @2]) {
        NSDictionary *env = KPKBuildWupEnvelope(guid, qua2, wupBody, mode.integerValue);
        if (!env) continue;
        NSArray<NSString *> *headers = env[@"headers"];
        NSData *body = env[@"body"];
        NSData *aesKey = env[@"aesKey"];
        NSString *ivHex = env[@"ivHex"];
        NSInteger modeVal = mode.integerValue;

        for (NSString *server in servers) {
            NSString *host = nil;
            NSInteger port = 0;
            NSString *path = nil;
            if (!KPKParseHttpURL(server, &host, &port, &path)) continue;

            NSString *pathQuery = [NSString stringWithFormat:@"%@?%@", path, env[@"query"]];
            const char **cheaders = calloc(headers.count, sizeof(char *));
            for (NSUInteger i = 0; i < headers.count; i++) cheaders[i] = headers[i].UTF8String;

            uint8_t *rbuf = malloc(128 * 1024);
            size_t rlen = 0;
            int status = 0;
            if (rbuf) {
                status = kpq_http_post(host.UTF8String, (int)port, pathQuery.UTF8String,
                                       cheaders, headers.count,
                                       body.bytes, body.length,
                                       rbuf, 128 * 1024, &rlen, (int)(timeout * 1000));
            }
            free(cheaders);
            if (!rbuf) continue;
            NSData *respData = [NSData dataWithBytes:rbuf length:rlen];
            free(rbuf);

            if (status != 200) continue;

            NSString *encFlag = KPKResponseHeader(respData, rlen, @"QQ-S-Encrypt");
            NSString *zipFlag = KPKResponseHeader(respData, rlen, @"QQ-S-ZIP");
            NSData *bodyData = KPKResponseBody(respData, rlen);
            if (!bodyData) continue;

            NSData *plain = nil;
            BOOL enc = encFlag.length > 0 || (status == 200 && bodyData.length > 16);
            if (enc) {
                size_t cap = bodyData.length + 32;
                NSMutableData *dec = [NSMutableData dataWithLength:cap];
                size_t dec_len = 0;
                int rc;
                if (modeVal == 2) {
                    NSData *iv = [ivHex dataUsingEncoding:NSUTF8StringEncoding];
                    rc = kpk_aes_cbc_decrypt(bodyData.bytes, bodyData.length,
                                             aesKey.bytes, aesKey.length, iv.bytes,
                                             dec.mutableBytes, dec.length, &dec_len);
                } else {
                    rc = kpk_aes_ecb_decrypt(bodyData.bytes, bodyData.length,
                                             aesKey.bytes, aesKey.length,
                                             dec.mutableBytes, dec.length, &dec_len);
                }
                if (rc == 0) { dec.length = dec_len; plain = dec; }
            } else {
                plain = bodyData;
            }

            if ([zipFlag.lowercaseString isEqualToString:@"gzip"] && plain) {
                plain = KPKGunzipData(plain);
            }
            if (!plain) continue;

            NSDictionary *fields = KPKParseWupResponse(plain, rspType);
            if (!fields) {
                continue;
            }

            NSNumber *rspCode = fields[@0];
            if ([rspCode isKindOfClass:[NSNumber class]] && rspCode.integerValue != 0) continue;

            return @{
                @"fields": fields,
                @"mode": @(modeVal),
                @"url": server,
            };
        }
    }
    return nil;
}

// ---------------------------------------------------------------------------
// PBProxy GetGuid
// ---------------------------------------------------------------------------
static NSData *KPKBuildGetGuidRequest(NSString *qua2) {
    NSMutableData *deviceInfo = [NSMutableData data];
    [deviceInfo appendData:pbLen(1, [NSData data])];
    [deviceInfo appendData:pbLen(2, [NSData data])];
    [deviceInfo appendData:pbLen(3, [NSData data])];
    NSMutableData *userStat = [NSMutableData data];
    [userStat appendData:pbVar(1, 3)];
    [userStat appendData:pbVar(2, 1)];
    NSMutableData *req = [NSMutableData data];
    [req appendData:pbLen(1, [NSData data])];
    [req appendData:pbLen(2, [qua2 dataUsingEncoding:NSUTF8StringEncoding])];
    [req appendData:pbLen(3, deviceInfo)];
    [req appendData:pbLen(4, userStat)];
    [req appendData:pbLen(5, [NSData data])];

    NSMutableData *msg = [NSMutableData data];
    [msg appendData:pbVar(1, (uint64_t)arc4random_uniform(100000) + 1)];
    [msg appendData:pbLen(2, [kGUIDServant dataUsingEncoding:NSUTF8StringEncoding])];
    [msg appendData:pbLen(3, [kGUIDFunc dataUsingEncoding:NSUTF8StringEncoding])];
    [msg appendData:pbLen(4, req)];

    uint32_t total = (uint32_t)msg.length + 4;
    NSMutableData *out = [NSMutableData dataWithCapacity:4 + msg.length];
    uint8_t lb[4] = { (uint8_t)(total >> 24), (uint8_t)((total >> 16) & 0xFF),
                      (uint8_t)((total >> 8) & 0xFF), (uint8_t)(total & 0xFF) };
    [out appendBytes:lb length:4];
    [out appendData:msg];
    return out;
}

static NSString *KPKParseGetGuidResponse(NSData *raw) {
    if (raw.length < 4) return nil;
    const uint8_t *b = raw.bytes;
    uint32_t total = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    if (total < 4 || total > raw.length) return nil;
    NSData *pb = [raw subdataWithRange:NSMakeRange(4, total - 4)];
    NSDictionary *fields = pbParseFields(pb);
    NSData *inner = pbGetBytes(fields, 4);
    if (!inner) return nil;
    NSDictionary *rsp = pbParseFields(inner);
    NSData *header = pbGetBytes(rsp, 1);
    if (header) {
        NSDictionary *hf = pbParseFields(header);
        NSNumber *ret = pbGetVarint(hf, 1);
        if (ret && ret.integerValue != 0) return nil;
    }
    NSData *guid = pbGetBytes(rsp, 2);
    if (guid.length != 16) return nil;
    return KPKHexUpper(guid);
}

static NSData *KPKSyncPost(NSString *urlString, NSDictionary *headers, NSData *body, NSTimeInterval timeout) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = body;
    req.timeoutInterval = timeout;
    for (NSString *key in headers) {
        [req setValue:headers[key] forHTTPHeaderField:key];
    }

    __block NSData *result = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            resultError = error;
        } else {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC) + 5LL * NSEC_PER_SEC));
    [session finishTasksAndInvalidate];
    if (resultError) return nil;
    return result;
}

// ---------------------------------------------------------------------------
// LCProxyKingClient
// ---------------------------------------------------------------------------
@implementation LCProxyKingClient

+ (NSString *)generateQua2WithModel:(NSString *)model
                              width:(NSInteger)width
                             height:(NSInteger)height
                                os:(NSString *)osRelease
                                api:(NSInteger)api {
    NSMutableString *clean = [NSMutableString stringWithString:model ?: @""];
    [clean replaceOccurrencesOfString:@" " withString:@""
                              options:0 range:NSMakeRange(0, clean.length)];
    [clean replaceOccurrencesOfString:@"/" withString:@""
                              options:0 range:NSMakeRange(0, clean.length)];
    [clean replaceOccurrencesOfString:@"_" withString:@""
                              options:0 range:NSMakeRange(0, clean.length)];
    [clean replaceOccurrencesOfString:@"&" withString:@""
                              options:0 range:NSMakeRange(0, clean.length)];
    [clean replaceOccurrencesOfString:@"|" withString:@""
                              options:0 range:NSMakeRange(0, clean.length)];
    [clean replaceOccurrencesOfString:@"\\" withString:@""
                              options:0 range:NSMakeRange(0, clean.length)];
    NSString *mo = [NSString stringWithFormat:@" %@ ", clean];
    return [NSString stringWithFormat:@"QV=3&PL=ADR&PR=QB&PP=com.tencent.mtt&PPVN=19.9.0.0047&CO=SYS&PB=GE&VE=GA&DE=PHONE&CHID=0&LCID=25681&MO=%@&RL=%ld*%ld&OS=%@&API=%ld&DS=64&RT=64&REF=qb_0&TM=01",
            mo, (long)width, (long)height, osRelease ?: @"10", (long)api];
}

+ (void)fetchGuidFromServerWithQua2:(NSString *)qua2
                            timeout:(NSTimeInterval)timeout
                         completion:(void (^)(NSString * _Nullable guid, NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *body = KPKBuildGetGuidRequest(qua2);
        NSDictionary *headers = @{
            @"Host": @"pbprx.qq.com",
            @"Content-Type": @"application/multipart-formdata",
            @"User-Agent": @"MQQBrowser",
            @"Accept": @"*/*",
            @"Connection": @"Close",
            @"PB": @"1",
            @"Q-GUID": @"00000000000000000000000000000000",
            @"Q-UA2": qua2,
            @"Traceid": KPKCurrentMillis(),
        };
        NSData *resp = KPKSyncPost(kPBProxyURL, headers, body, timeout);
        if (!resp) {
            completion(nil, [NSError errorWithDomain:@"LCProxyKing" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"GetGuid 网络失败"}]);
            return;
        }
        NSString *guid = KPKParseGetGuidResponse(resp);
        if (!guid) {
            completion(nil, [NSError errorWithDomain:@"LCProxyKing" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"GetGuid 响应解析失败"}]);
            return;
        }
        completion(guid, nil);
    });
}

+ (void)fetchTokenWithGuid:(NSString *)guid
                      qua2:(NSString *)qua2
                     phone:(NSString *)phone
                   timeout:(NSTimeInterval)timeout
                completion:(void (^)(NSDictionary * _Nullable info, NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *wup = KPKTokenInfoReq(guid, qua2, phone);
        NSData *body0 = KPKWupRequest(kTokenServant, kTokenFunc, kReqKey, kTokenReqType, wup, 0);
        NSDictionary *parsed = KPKSendWupAndParse(guid, qua2, body0, kTokenRspType, KPKDefaultWupURLs(), timeout);
        if (!parsed) {
            completion(nil, [NSError errorWithDomain:@"LCProxyKing" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Q-Token 获取失败"}]);
            return;
        }
        NSDictionary *fields = parsed[@"fields"];
        NSString *token = fields[@1];
        if (![token isKindOfClass:[NSString class]] || token.length == 0) {
            completion(nil, [NSError errorWithDomain:@"LCProxyKing" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Q-Token 响应为空"}]);
            return;
        }
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"token"] = token;
        if ([fields[@3] isKindOfClass:[NSString class]]) info[@"qkey"] = fields[@3];
        if ([fields[@2] isKindOfClass:[NSNumber class]]) info[@"expire_seconds"] = fields[@2];
        info[@"mode"] = parsed[@"mode"];
        info[@"url"] = parsed[@"url"];
        completion(info, nil);
    });
}

+ (void)fetchQueenProxiesWithGuid:(NSString *)guid
                             qua2:(NSString *)qua2
                           params:(NSDictionary *)params
                          timeout:(NSTimeInterval)timeout
                       completion:(void (^)(NSDictionary * _Nullable info, NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *route = KPKRouteIPListReq(guid, qua2, params);
        NSData *body0 = KPKWupRequest(kProxyServant, kProxyFunc, kReqKey, kProxyReqType, route, 0);
        NSDictionary *parsed = KPKSendWupAndParse(guid, qua2, body0, kProxyRspType, @[@"http://qbwup.qq.com:8080/"], timeout);
        if (!parsed) {
            completion(nil, [NSError errorWithDomain:@"LCProxyKing" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"Queen 代理池获取失败"}]);
            return;
        }
        NSDictionary *fields = parsed[@"fields"];
        NSArray *infos = fields[@0];
        NSMutableArray<NSString *> *queenHttp = [NSMutableArray array];
        NSMutableArray<NSString *> *queenHttps = [NSMutableArray array];
        NSInteger minLifePeriod = NSIntegerMax;
        if ([infos isKindOfClass:[NSArray class]]) {
            for (id info in infos) {
                if (![info isKindOfClass:[NSDictionary class]]) continue;
                NSNumber *iptype = info[@0];
                NSArray *vip = info[@1];
                if (![iptype isKindOfClass:[NSNumber class]] || ![vip isKindOfClass:[NSArray class]]) continue;
                if (iptype.integerValue == 15 || iptype.integerValue == 16) {
                    NSNumber *life = info[@3];
                    if ([life isKindOfClass:[NSNumber class]]) {
                        NSInteger lifeValue = life.integerValue;
                        if (lifeValue > 0 && lifeValue < minLifePeriod) minLifePeriod = lifeValue;
                    }
                }
                if (iptype.integerValue == 15) {
                    for (id s in vip) if ([s isKindOfClass:[NSString class]]) [queenHttp addObject:s];
                } else if (iptype.integerValue == 16) {
                    for (id s in vip) if ([s isKindOfClass:[NSString class]]) [queenHttps addObject:s];
                }
            }
        }
        if (queenHttp.count == 0 && queenHttps.count == 0) {
            completion(nil, [NSError errorWithDomain:@"LCProxyKing" code:-6 userInfo:@{NSLocalizedDescriptionKey: @"Queen 代理池为空"}]);
            return;
        }
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"queen_http"] = queenHttp;
        info[@"queen_https"] = queenHttps;
        info[@"lifePeriod"] = @(minLifePeriod == NSIntegerMax ? 600 : minLifePeriod);
        info[@"server"] = parsed[@"url"];
        info[@"mode"] = parsed[@"mode"];
        info[@"sApn"] = fields[@1] ?: @"";
        info[@"bProxy"] = fields[@2] ?: @0;
        completion(info, nil);
    });
}


#pragma mark - Debug binary builders

+ (NSData *)debugTokenWupRequestWithGuid:(NSString *)guid qua2:(NSString *)qua2 phone:(NSString *)phone {
    NSData *wup = KPKTokenInfoReq(guid, qua2, phone);
    return KPKWupRequest(kTokenServant, kTokenFunc, kReqKey, kTokenReqType, wup, 0);
}

+ (NSData *)debugRouteIPListWupRequestWithGuid:(NSString *)guid qua2:(NSString *)qua2 params:(NSDictionary *)params {
    NSData *route = KPKRouteIPListReq(guid, qua2, params);
    return KPKWupRequest(kProxyServant, kProxyFunc, kReqKey, kProxyReqType, route, 0);
}

+ (NSString *)debugCommonHeaderHexWithGuid:(NSString *)guid {
    NSData *header = KPKPbCommonHeader(guid);
    return KPKHexUpper(header);
}

@end
