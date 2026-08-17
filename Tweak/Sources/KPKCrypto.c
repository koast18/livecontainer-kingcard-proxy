//
//  KPKCrypto.c
//  LCProxyTweak
//
//  AES / gzip / RSA(1024) / Queen Q-Key 计算。
//
#include "KPKCrypto.h"

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

// ---------------------------------------------------------------------------
// 缓冲区小工具
// ---------------------------------------------------------------------------
typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} kpk_buf;

static void kpk_buf_init(kpk_buf *b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static int kpk_buf_reserve(kpk_buf *b, size_t extra) {
    if (b->len + extra <= b->cap) return 0;
    size_t nc = b->cap ? b->cap : 256;
    while (nc < b->len + extra) {
        if (nc > SIZE_MAX / 2) return -1;
        nc *= 2;
    }
    uint8_t *p = realloc(b->data, nc);
    if (!p) return -1;
    b->data = p;
    b->cap = nc;
    return 0;
}

static int kpk_buf_append(kpk_buf *b, const void *data, size_t len) {
    if (kpk_buf_reserve(b, len) != 0) return -1;
    if (len) {
        memcpy(b->data + b->len, data, len);
        b->len += len;
    }
    return 0;
}

static int kpk_buf_byte(kpk_buf *b, uint8_t v) {
    return kpk_buf_append(b, &v, 1);
}

static int kpk_buf_be16(kpk_buf *b, uint16_t v) {
    uint8_t tmp[2] = { (uint8_t)(v >> 8), (uint8_t)(v & 0xFF) };
    return kpk_buf_append(b, tmp, 2);
}

static int kpk_buf_be32(kpk_buf *b, uint32_t v) {
    uint8_t tmp[4] = { (uint8_t)(v >> 24), (uint8_t)((v >> 16) & 0xFF),
                       (uint8_t)((v >> 8) & 0xFF), (uint8_t)(v & 0xFF) };
    return kpk_buf_append(b, tmp, 4);
}

// ---------------------------------------------------------------------------
// AES（CommonCrypto）
// ---------------------------------------------------------------------------
static int kpk_aes_crypt(int encrypt, const uint8_t *in, size_t in_len,
                         const uint8_t *key, size_t key_len,
                         const uint8_t *iv, int ecb,
                         uint8_t *out, size_t out_cap, size_t *out_len) {
    if (!in || !key || !out || !out_len) return -1;
    if (key_len != kCCKeySizeAES128 && key_len != kCCKeySizeAES192 && key_len != kCCKeySizeAES256) return -1;
    if (in_len == 0) return -1;
    CCOptions opts = kCCOptionPKCS7Padding;
    if (ecb) opts |= kCCOptionECBMode;
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt,
                                 kCCAlgorithmAES,
                                 opts,
                                 key, key_len,
                                 iv,
                                 in, in_len,
                                 out, out_cap,
                                 &moved);
    if (st != kCCSuccess) return -1;
    *out_len = moved;
    return 0;
}

int kpk_aes_ecb_encrypt(const uint8_t *in, size_t in_len,
                        const uint8_t *key, size_t key_len,
                        uint8_t *out, size_t out_cap, size_t *out_len) {
    return kpk_aes_crypt(1, in, in_len, key, key_len, NULL, 1, out, out_cap, out_len);
}

int kpk_aes_cbc_encrypt(const uint8_t *in, size_t in_len,
                        const uint8_t *key, size_t key_len,
                        const uint8_t iv[16],
                        uint8_t *out, size_t out_cap, size_t *out_len) {
    return kpk_aes_crypt(1, in, in_len, key, key_len, iv, 0, out, out_cap, out_len);
}

int kpk_aes_ecb_decrypt(const uint8_t *in, size_t in_len,
                        const uint8_t *key, size_t key_len,
                        uint8_t *out, size_t out_cap, size_t *out_len) {
    return kpk_aes_crypt(0, in, in_len, key, key_len, NULL, 1, out, out_cap, out_len);
}

int kpk_aes_cbc_decrypt(const uint8_t *in, size_t in_len,
                        const uint8_t *key, size_t key_len,
                        const uint8_t iv[16],
                        uint8_t *out, size_t out_cap, size_t *out_len) {
    return kpk_aes_crypt(0, in, in_len, key, key_len, iv, 0, out, out_cap, out_len);
}

// ---------------------------------------------------------------------------
// gzip（zlib）
// ---------------------------------------------------------------------------
int kpk_gzip_compress(const uint8_t *in, size_t in_len,
                      uint8_t *out, size_t out_cap, size_t *out_len) {
    if (!in || !out || !out_len) return -1;
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (deflateInit2(&zs, 9, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) return -1;
    zs.next_in = (Bytef *)(uintptr_t)in;
    zs.avail_in = (uInt)in_len;
    zs.next_out = out;
    zs.avail_out = (uInt)out_cap;
    int rc = deflate(&zs, Z_FINISH);
    *out_len = out_cap - zs.avail_out;
    deflateEnd(&zs);
    if (rc != Z_STREAM_END) return -1;
    return 0;
}

int kpk_gzip_decompress(const uint8_t *in, size_t in_len,
                        uint8_t *out, size_t out_cap, size_t *out_len) {
    if (!in || !out || !out_len) return -1;
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 15 + 16) != Z_OK) return -1;
    zs.next_in = (Bytef *)(uintptr_t)in;
    zs.avail_in = (uInt)in_len;
    zs.next_out = out;
    zs.avail_out = (uInt)out_cap;
    int rc = inflate(&zs, Z_FINISH);
    *out_len = out_cap - zs.avail_out;
    inflateEnd(&zs);
    if (rc != Z_STREAM_END && rc != Z_OK) return -1;
    return 0;
}

// ---------------------------------------------------------------------------
// 1024 位 RSA（硬编码 QQ 浏览器公钥），用于加密 16 字节 AES key。
// 实现为 32-limb 大整数 + 二进制长除取模，避免依赖平台 OpenSSL。
// ---------------------------------------------------------------------------
#define KPK_RSA_LIMBS 32
#define KPK_RSA_PRODUCT_LIMBS 64
#define KPK_RSA_TMP_LIMBS 33

typedef uint32_t kpk_limb_t;

static const uint8_t kpk_rsa_modulus_be[128] = {
    0xb3,0x6b,0x32,0x02,0x3d,0x00,0xfd,0x4e,0xe9,0x32,0xd8,0xbf,0x4d,0x97,0xcf,0x12,
    0xe9,0x62,0x36,0x41,0x00,0x14,0x8a,0xb2,0x73,0x9f,0x32,0xea,0xf7,0x6d,0xd0,0xe6,
    0x65,0x7a,0x0c,0x72,0x53,0x2d,0x88,0x06,0xe2,0x1c,0x78,0xe3,0xed,0x15,0x88,0xf8,
    0x30,0x30,0x7c,0xc7,0x88,0xc9,0xf8,0xb1,0xf2,0xb9,0xf9,0x97,0x6c,0xba,0x48,0xcf,
    0x5c,0x41,0xb4,0x5a,0x6f,0x98,0x1e,0xa0,0x8a,0xd0,0x81,0x02,0x1c,0x4e,0xdd,0x37,
    0x75,0x8f,0x07,0x20,0x6c,0xa6,0x6e,0x18,0x95,0x90,0x49,0x50,0x22,0x9b,0x30,0x19,
    0x4e,0xd2,0x36,0x0f,0xcb,0x05,0x12,0x3e,0x64,0x10,0xf6,0x76,0xb3,0x96,0x5d,0x3f,
    0xa3,0x52,0x4e,0x7a,0x98,0x5d,0x0e,0xcd,0x62,0xc6,0xcc,0xd6,0x4b,0xdd,0x96,0x9d
};

static void kpk_bn_from_be(kpk_limb_t out[KPK_RSA_LIMBS], const uint8_t *be, size_t len) {
    memset(out, 0, KPK_RSA_LIMBS * sizeof(kpk_limb_t));
    if (len > KPK_RSA_LIMBS * 4) len = KPK_RSA_LIMBS * 4;
    for (size_t i = 0; i < len; i++) {
        size_t bi = len - 1 - i;
        out[bi / 4] |= ((kpk_limb_t)be[i]) << ((bi % 4) * 8);
    }
}

static void kpk_bn_to_be(const kpk_limb_t in[KPK_RSA_LIMBS], uint8_t *out, size_t len) {
    for (size_t i = 0; i < len; i++) {
        out[len - 1 - i] = (uint8_t)(in[i / 4] >> ((i % 4) * 8));
    }
}

static int kpk_bn_cmp(const kpk_limb_t *a, const kpk_limb_t *b, int n) {
    for (int i = n - 1; i >= 0; i--) {
        if (a[i] > b[i]) return 1;
        if (a[i] < b[i]) return -1;
    }
    return 0;
}

static void kpk_bn_sub(kpk_limb_t *a, const kpk_limb_t *b, int n) {
    uint64_t borrow = 0;
    for (int i = 0; i < n; i++) {
        uint64_t ai = a[i];
        uint64_t bi = (uint64_t)b[i] + borrow;
        if (ai < bi) {
            a[i] = (kpk_limb_t)((ai + ((uint64_t)1 << 32)) - bi);
            borrow = 1;
        } else {
            a[i] = (kpk_limb_t)(ai - bi);
            borrow = 0;
        }
    }
}

static void kpk_bn_mul(kpk_limb_t out[KPK_RSA_PRODUCT_LIMBS],
                       const kpk_limb_t a[KPK_RSA_LIMBS],
                       const kpk_limb_t b[KPK_RSA_LIMBS]) {
    memset(out, 0, KPK_RSA_PRODUCT_LIMBS * sizeof(kpk_limb_t));
    for (int i = 0; i < KPK_RSA_LIMBS; i++) {
        uint64_t carry = 0;
        uint64_t ai = a[i];
        for (int j = 0; j < KPK_RSA_LIMBS; j++) {
            uint64_t t = ai * b[j] + out[i + j] + carry;
            out[i + j] = (kpk_limb_t)(t & 0xFFFFFFFFULL);
            carry = t >> 32;
        }
        out[i + KPK_RSA_LIMBS] = (kpk_limb_t)carry;
    }
}

static void kpk_bn_modmul(kpk_limb_t out[KPK_RSA_LIMBS],
                          const kpk_limb_t a[KPK_RSA_LIMBS],
                          const kpk_limb_t b[KPK_RSA_LIMBS],
                          const kpk_limb_t m[KPK_RSA_LIMBS]) {
    kpk_limb_t a0[KPK_RSA_LIMBS], b0[KPK_RSA_LIMBS];
    memcpy(a0, a, sizeof(a0));
    memcpy(b0, b, sizeof(b0));
    kpk_limb_t prod[KPK_RSA_PRODUCT_LIMBS];
    kpk_bn_mul(prod, a0, b0);

    kpk_limb_t m33[KPK_RSA_TMP_LIMBS];
    memset(m33, 0, sizeof(m33));
    memcpy(m33, m, KPK_RSA_LIMBS * sizeof(kpk_limb_t));

    kpk_limb_t rem[KPK_RSA_TMP_LIMBS];
    memset(rem, 0, sizeof(rem));

    for (int bit = KPK_RSA_PRODUCT_LIMBS * 32 - 1; bit >= 0; bit--) {
        uint64_t carry = 0;
        for (int i = 0; i < KPK_RSA_TMP_LIMBS; i++) {
            uint64_t v = ((uint64_t)rem[i] << 1) | carry;
            rem[i] = (kpk_limb_t)(v & 0xFFFFFFFFULL);
            carry = v >> 32;
        }
        if ((prod[bit / 32] >> (bit % 32)) & 1U) rem[0] |= 1;
        if (kpk_bn_cmp(rem, m33, KPK_RSA_TMP_LIMBS) >= 0) {
            kpk_bn_sub(rem, m33, KPK_RSA_TMP_LIMBS);
        }
    }
    memcpy(out, rem, KPK_RSA_LIMBS * sizeof(kpk_limb_t));
}

static void kpk_bn_modpow(kpk_limb_t out[KPK_RSA_LIMBS],
                          const kpk_limb_t base[KPK_RSA_LIMBS],
                          uint32_t exp,
                          const kpk_limb_t mod[KPK_RSA_LIMBS]) {
    kpk_limb_t result[KPK_RSA_LIMBS];
    memset(result, 0, sizeof(result));
    result[0] = 1;

    kpk_limb_t b[KPK_RSA_LIMBS];
    memcpy(b, base, sizeof(b));

    int bits = 0;
    uint32_t e = exp;
    while (e) { bits++; e >>= 1; }

    for (int i = bits - 1; i >= 0; i--) {
        kpk_bn_modmul(result, result, result, mod);
        if ((exp >> i) & 1U) {
            kpk_bn_modmul(result, result, b, mod);
        }
    }
    memcpy(out, result, sizeof(result));
}

static void kpk_mgf1_sha1(const uint8_t *seed, size_t seed_len,
                          uint8_t *out, size_t out_len) {
    size_t done = 0;
    uint32_t counter = 0;
    while (done < out_len) {
        uint8_t c[4] = { (uint8_t)(counter >> 24), (uint8_t)((counter >> 16) & 0xFF),
                         (uint8_t)((counter >> 8) & 0xFF), (uint8_t)(counter & 0xFF) };
        uint8_t hash[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1_CTX ctx;
        CC_SHA1_Init(&ctx);
        CC_SHA1_Update(&ctx, seed, (CC_LONG)seed_len);
        CC_SHA1_Update(&ctx, c, 4);
        CC_SHA1_Final(hash, &ctx);
        size_t cp = out_len - done;
        if (cp > CC_SHA1_DIGEST_LENGTH) cp = CC_SHA1_DIGEST_LENGTH;
        memcpy(out + done, hash, cp);
        done += cp;
        counter++;
    }
}

static int kpk_rsa_oaep_encode(const uint8_t msg[16], uint8_t em[128]) {
    uint8_t seed[20];
    arc4random_buf(seed, sizeof(seed));
    uint8_t lhash[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1((const uint8_t *)"", 0, lhash);

    uint8_t db[107];
    memset(db, 0, sizeof(db));
    memcpy(db, lhash, CC_SHA1_DIGEST_LENGTH);
    db[90] = 0x01;
    memcpy(db + 91, msg, 16);

    uint8_t masked_db[107];
    kpk_mgf1_sha1(seed, sizeof(seed), masked_db, sizeof(masked_db));
    for (int i = 0; i < 107; i++) masked_db[i] ^= db[i];

    uint8_t masked_seed[20];
    kpk_mgf1_sha1(masked_db, sizeof(masked_db), masked_seed, sizeof(masked_seed));
    for (int i = 0; i < 20; i++) masked_seed[i] ^= seed[i];

    em[0] = 0x00;
    memcpy(em + 1, masked_seed, 20);
    memcpy(em + 1 + 20, masked_db, 107);
    return 0;
}

static int kpk_rsa_raw_encrypt(const uint8_t in[128], uint8_t out[128]) {
    kpk_limb_t n[KPK_RSA_LIMBS], m[KPK_RSA_LIMBS], c[KPK_RSA_LIMBS];
    kpk_bn_from_be(n, kpk_rsa_modulus_be, sizeof(kpk_rsa_modulus_be));
    kpk_bn_from_be(m, in, 128);
    if (kpk_bn_cmp(m, n, KPK_RSA_LIMBS) >= 0) return -1;
    kpk_bn_modpow(c, m, 65537U, n);
    kpk_bn_to_be(c, out, 128);
    return 0;
}

int kpk_rsa_encrypt_aes_key(const uint8_t aes_key[16], int mode, uint8_t out[128]) {
    if (!aes_key || !out) return -1;
    uint8_t block[128];
    if (mode == 2) {
        if (kpk_rsa_oaep_encode(aes_key, block) != 0) return -1;
    } else {
        memset(block, 0, sizeof(block));
        memcpy(block + 112, aes_key, 16);
    }
    return kpk_rsa_raw_encrypt(block, out);
}

// ---------------------------------------------------------------------------
// Queen Q-Key 头计算
// ---------------------------------------------------------------------------
static int kpk_jce_string_append(kpk_buf *b, const char *s, int tag) {
    size_t sl = strlen(s);
    int long_form = sl > 255;
    uint8_t type = long_form ? 7 : 6;
    if (tag < 15) {
        if (kpk_buf_byte(b, (uint8_t)(((tag & 0x0F) << 4) | type)) != 0) return -1;
    } else {
        if (kpk_buf_byte(b, (uint8_t)(0xF0 | type)) != 0 ||
            kpk_buf_byte(b, (uint8_t)tag) != 0) return -1;
    }
    if (long_form) {
        if (kpk_buf_be32(b, (uint32_t)sl) != 0) return -1;
    } else {
        if (kpk_buf_byte(b, (uint8_t)sl) != 0) return -1;
    }
    return kpk_buf_append(b, s, sl);
}

int kpk_build_qkey_header(const char *guid, const char *domain, const char *url,
                          const char *request_id, const char *qkey,
                          char *out, size_t out_cap) {
    if (!guid || !domain || !url || !request_id || !qkey || !out) return -1;
    size_t qkey_len = strlen(qkey);
    if (qkey_len != 16 && qkey_len != 24 && qkey_len != 32) return -1;

    kpk_buf b;
    kpk_buf_init(&b);
    if (kpk_jce_string_append(&b, guid, 0) != 0 ||
        kpk_jce_string_append(&b, domain, 1) != 0 ||
        kpk_jce_string_append(&b, url, 2) != 0 ||
        kpk_jce_string_append(&b, request_id, 3) != 0) {
        free(b.data);
        return -1;
    }

    size_t enc_cap = ((b.len / 16) + 1) * 16;
    uint8_t *enc = malloc(enc_cap);
    if (!enc) { free(b.data); return -1; }
    size_t enc_len = 0;
    int rc = kpk_aes_ecb_encrypt(b.data, b.len, (const uint8_t *)qkey, qkey_len,
                                 enc, enc_cap, &enc_len);
    free(b.data);
    if (rc != 0) { free(enc); return -1; }

    if (out_cap < enc_len * 2 + 1) { free(enc); return -1; }
    static const char *hexc = "0123456789abcdef";
    for (size_t i = 0; i < enc_len; i++) {
        out[i * 2] = hexc[enc[i] >> 4];
        out[i * 2 + 1] = hexc[enc[i] & 0x0F];
    }
    out[enc_len * 2] = '\0';
    free(enc);
    return 0;
}
