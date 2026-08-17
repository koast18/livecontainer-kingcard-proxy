#include "KPKCrypto.h"
#include <stdio.h>
#include <string.h>

static void print_hex(const uint8_t *b, size_t len) {
    for (size_t i = 0; i < len; i++) printf("%02x", b[i]);
    printf("\n");
}

int main(void) {
    uint8_t aes_key[16] = {0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
                           0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff};
    uint8_t rsa_out[128];
    if (kpk_rsa_encrypt_aes_key(aes_key, 1, rsa_out) != 0) {
        printf("rsa rc fail\n");
        return 1;
    }
    printf("rsa_mode1=");
    print_hex(rsa_out, 128);

    if (kpk_rsa_encrypt_aes_key(aes_key, 2, rsa_out) != 0) {
        printf("rsa rc fail mode2\n");
        return 1;
    }
    printf("rsa_mode2=");
    print_hex(rsa_out, 128);

    char qkey[512];
    if (kpk_build_qkey_header("156DFD39C896CADEA5DFE8D8532888CB",
                              "ip.3322.net",
                              "http://ip.3322.net/",
                              "1755000000000",
                              "1110111011101110",
                              qkey, sizeof(qkey)) != 0) {
        printf("qkey rc fail\n");
        return 1;
    }
    printf("qkey=%s\n", qkey);
    return 0;
}
