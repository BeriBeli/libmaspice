#include "spice_zig.h"
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>

static SecKeyRef generate_key(int bits) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &bits);
    const void *keys[] = {kSecAttrKeyType, kSecAttrKeySizeInBits};
    const void *values[] = {kSecAttrKeyTypeRSA, number};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFErrorRef error = NULL;
    SecKeyRef key = SecKeyCreateRandomKey(attributes, &error);
    if (!key) fprintf(stderr, "Security ephemeral key generation failed (code %ld)\n", error ? (long)CFErrorGetCode(error) : 0L);
    assert(key && !error);
    if (error) CFRelease(error);
    CFRelease(attributes);
    CFRelease(number);
    return key;
}

int main(void) {
    SecKeyRef private_key = generate_key(1024);
    SecKeyRef public_key = SecKeyCopyPublicKey(private_key);
    CFErrorRef error = NULL;
    CFDataRef pkcs1 = SecKeyCopyExternalRepresentation(public_key, &error);
    assert(pkcs1 && !error && CFDataGetLength(pkcs1) == 140);
    const uint8_t prefix[] = {0x30,0x81,0x9f,0x30,0x0d,0x06,0x09,
        0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0,0x03,0x81,0x8d,0};
    uint8_t spki[162];
    memcpy(spki, prefix, sizeof(prefix));
    memcpy(spki+sizeof(prefix), CFDataGetBytePtr(pkcs1), 140);
    uint8_t password[61];
    memset(password, 'x', sizeof(password));
    struct { uint8_t before[16], bytes[128], after[16]; } output;
    memset(&output, 0x5a, sizeof(output));
    const size_t sizes[] = {0, 6, 60};
    for (size_t format=0; format<2; format++) {
        const uint8_t *der = format ? spki : CFDataGetBytePtr(pkcs1);
        const size_t der_size = format ? sizeof(spki) : 140;
        for (size_t i=0; i<sizeof(sizes)/sizeof(sizes[0]); i++) {
            assert(spice_zig_ticket_encrypt(password, sizes[i], der, der_size, output.bytes) == 0);
            CFDataRef cipher = CFDataCreate(NULL, output.bytes, 128);
            CFDataRef plain = SecKeyCreateDecryptedData(private_key, kSecKeyAlgorithmRSAEncryptionOAEPSHA1, cipher, &error);
            assert(plain && !error && CFDataGetLength(plain) == (CFIndex)sizes[i]+1);
            assert(memcmp(CFDataGetBytePtr(plain), password, sizes[i]) == 0);
            assert(CFDataGetBytePtr(plain)[sizes[i]] == 0);
            CFRelease(plain);
            CFRelease(cipher);
        }
    }
    memset(output.bytes, 0x5a, 128);
    assert(spice_zig_ticket_encrypt(password, 61, spki, sizeof(spki), output.bytes) == -10);
    password[1] = 0;
    assert(spice_zig_ticket_encrypt(password, 3, spki, sizeof(spki), output.bytes) == -11);
    for (size_t end=0; end<sizeof(spki); end++) {
        assert(spice_zig_ticket_encrypt(NULL, 0, spki, end, output.bytes) < 0);
    }
    // Unsupported RSA sizes must not silently change the protocol ciphertext.
    SecKeyRef larger = generate_key(2048);
    SecKeyRef larger_public = SecKeyCopyPublicKey(larger);
    CFDataRef larger_der = SecKeyCopyExternalRepresentation(larger_public, &error);
    assert(larger_der && !error);
    assert(spice_zig_ticket_encrypt(NULL, 0, CFDataGetBytePtr(larger_der), (size_t)CFDataGetLength(larger_der), output.bytes) == -13);
    const uint8_t *guard = (const uint8_t *)&output;
    for (size_t i=0; i<sizeof(output); i++) assert(guard[i] == 0x5a);
    CFRelease(larger_der);
    CFRelease(larger_public);
    CFRelease(larger);
    CFRelease(pkcs1);
    CFRelease(public_key);
    CFRelease(private_key);
    return 0;
}
