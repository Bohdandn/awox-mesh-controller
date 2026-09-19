#include <CommonCrypto/CommonCryptor.h>
#include <stdint.h>

int32_t awox_aes128_ecb_encrypt(
    const uint8_t *key,
    const uint8_t *input,
    uint8_t *output
) {
    size_t output_length = 0;
    CCCryptorStatus status = CCCrypt(
        kCCEncrypt,
        kCCAlgorithmAES,
        kCCOptionECBMode,
        key,
        kCCKeySizeAES128,
        NULL,
        input,
        kCCBlockSizeAES128,
        output,
        kCCBlockSizeAES128,
        &output_length
    );
    return status == kCCSuccess && output_length == kCCBlockSizeAES128 ? 0 : status;
}