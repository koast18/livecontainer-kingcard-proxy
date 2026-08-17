#ifndef KPKCrypto_h
#define KPKCrypto_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// AES-ECB / AES-CBC（PKCS7Padding），密钥长度 16/24/32 字节。
/// CBC 的 iv 固定 16 字节。out_len 回填实际加密后长度（含 padding）。
int kpk_aes_ecb_encrypt(const uint8_t *in, size_t in_len,
                        const uint8_t *key, size_t key_len,
                        uint8_t *out, size_t out_cap, size_t *out_len);
int kpk_aes_cbc_encrypt(const uint8_t *in, size_t in_len,
                        const uint8_t *key, size_t key_len,
                        const uint8_t iv[16],
                        uint8_t *out, size_t out_cap, size_t *out_len);
int kpk_aes_ecb_decrypt(const uint8_t *in, size_t in_len,
                        const uint8_t *key, size_t key_len,
                        uint8_t *out, size_t out_cap, size_t *out_len);
int kpk_aes_cbc_decrypt(const uint8_t *in, size_t in_len,
                        const uint8_t *key, size_t key_len,
                        const uint8_t iv[16],
                        uint8_t *out, size_t out_cap, size_t *out_len);

/// gzip 压缩/解压。成功返回 0，失败返回 -1。
int kpk_gzip_compress(const uint8_t *in, size_t in_len,
                      uint8_t *out, size_t out_cap, size_t *out_len);
int kpk_gzip_decompress(const uint8_t *in, size_t in_len,
                        uint8_t *out, size_t out_cap, size_t *out_len);

/// 用硬编码的 QQ 浏览器 RSA 公钥加密 16 字节 AES key。
/// mode 1 = RSA/ECB/NoPadding（左补零到 128 字节），
/// mode 2 = RSA/ECB/OAEP(SHA1)。
/// out 固定 128 字节。成功返回 0。
int kpk_rsa_encrypt_aes_key(const uint8_t aes_key[16], int mode, uint8_t out[128]);

/// 计算 Queen 代理 Q-Key 头：
/// JCE(HttpInfoEncrypt) 字段（tag0 guid / tag1 domain / tag2 url / tag3 request_id）
/// 用 qkey 的 UTF-8 字节做 AES/ECB/PKCS7Padding，输出小写 hex。
/// 成功返回 0。
int kpk_build_qkey_header(const char *guid, const char *domain, const char *url,
                          const char *request_id, const char *qkey,
                          char *out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif
