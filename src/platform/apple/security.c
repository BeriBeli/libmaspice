/* Narrow Apple Security adapter: no protocol parsing, passwords or policy.
 * Borrowed buffers are wrapped without copies and released synchronously.
 * Zig owns the NUL-terminated plaintext and securely zeroes it after return. */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <limits.h>

int spice_zig_security_encrypt(const uint8_t *key_bytes, size_t key_size,
                              const uint8_t *plaintext, size_t plaintext_size,
                              uint8_t output[128]) {
    if (!key_bytes || !plaintext || !output || key_size > LONG_MAX || plaintext_size > LONG_MAX) return 2;
    int result = 2;
    CFErrorRef error = NULL;
    CFDataRef key_data = NULL, clear_data = NULL, encrypted = NULL;
    CFDictionaryRef attributes = NULL;
    SecKeyRef key = NULL;
    const void *keys[] = {kSecAttrKeyType, kSecAttrKeyClass};
    const void *values[] = {kSecAttrKeyTypeRSA, kSecAttrKeyClassPublic};
    key_data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, key_bytes, (CFIndex)key_size, kCFAllocatorNull);
    if (!key_data) goto done;
    attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes) goto done;
    key = SecKeyCreateWithData(key_data, attributes, &error);
    if (!key) goto done;
    if (SecKeyGetBlockSize(key) != 128 || !SecKeyIsAlgorithmSupported(key, kSecKeyOperationTypeEncrypt, kSecKeyAlgorithmRSAEncryptionOAEPSHA1)) {
        result = 1;
        goto done;
    }
    clear_data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, plaintext, (CFIndex)plaintext_size, kCFAllocatorNull);
    if (!clear_data) goto done;
    encrypted = SecKeyCreateEncryptedData(key, kSecKeyAlgorithmRSAEncryptionOAEPSHA1, clear_data, &error);
    if (!encrypted || CFDataGetLength(encrypted) != 128) goto done;
    memcpy(output, CFDataGetBytePtr(encrypted), 128);
    result = 0;
done:
    if (encrypted) CFRelease(encrypted);
    if (clear_data) CFRelease(clear_data);
    if (key) CFRelease(key);
    if (attributes) CFRelease(attributes);
    if (key_data) CFRelease(key_data);
    if (error) CFRelease(error);
    return result;
}
