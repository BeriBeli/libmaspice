/* Apple object/block adaptation only. Policy, DER, state, deadlines, ownership
 * of application buffers, exact I/O and channel behavior are implemented in Zig. */
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import "network_bridge.h"

@interface SpiceVerificationOwner : NSObject
@property(nonatomic, assign) void *context;
@property(nonatomic, assign) SpiceNWRelease releaseContext;
@end
@implementation SpiceVerificationOwner
- (void)dealloc { if (_releaseContext) _releaseContext(_context); }
@end
@interface SpiceNativeConnection : NSObject
@property(nonatomic, strong) nw_connection_t connection;
@property(nonatomic, strong) dispatch_queue_t queue;
@end
@implementation SpiceNativeConnection
@end

static int errorDomain(nw_error_t error) { return error ? nw_error_get_error_domain(error) : 0; }
static int errorCode(nw_error_t error) { return error ? nw_error_get_error_code(error) : 0; }
void *spice_nw_create(const char *host, const char *port, int tls, const char *server_name,
                     SpiceNWState state, void *state_context, SpiceNWVerify verify,
                     void *verify_context, SpiceNWRelease release_context) {
    @autoreleasepool {
        SpiceVerificationOwner *policy = [SpiceVerificationOwner new];
        if (!policy) { if (release_context) release_context(verify_context); return NULL; }
        policy.context = verify_context;
        policy.releaseContext = release_context;
        SpiceNativeConnection *native = [SpiceNativeConnection new];
        native.queue = dispatch_queue_create("org.swiftspice.zig.network", DISPATCH_QUEUE_SERIAL);
        // A slow trust evaluation must never block the transport callback queue.
        dispatch_queue_t verify_queue = dispatch_queue_create("org.swiftspice.zig.trust", DISPATCH_QUEUE_SERIAL);
        if (!native || !native.queue || !verify_queue) return NULL;
        nw_parameters_configure_protocol_block_t tls_options = NW_PARAMETERS_DISABLE_PROTOCOL;
        if (tls) {
            tls_options = ^(nw_protocol_options_t options) {
                sec_protocol_options_t security = nw_tls_copy_sec_protocol_options(options);
                if (server_name) sec_protocol_options_set_tls_server_name(security, server_name);
                if (verify) sec_protocol_options_set_verify_block(security,
                    ^(sec_protocol_metadata_t metadata, sec_trust_t protocol_trust, sec_protocol_verify_complete_t complete) {
                        (void)metadata;
                        @autoreleasepool {
                            SecTrustRef trust = sec_trust_copy_ref(protocol_trust);
                            int accepted = trust && verify(policy.context, (void *)trust);
                            if (trust) CFRelease(trust);
                            complete(accepted != 0);
                        }
                    }, verify_queue);
            };
        }
        nw_parameters_t parameters = nw_parameters_create_secure_tcp(tls_options, ^(nw_protocol_options_t tcp) {
            nw_tcp_options_set_no_delay(tcp, true);
            nw_tcp_options_set_enable_keepalive(tcp, true);
            nw_tcp_options_set_keepalive_idle_time(tcp, 30);
            nw_tcp_options_set_keepalive_count(tcp, 3);
            nw_tcp_options_set_keepalive_interval(tcp, 15);
            nw_tcp_options_set_connection_timeout(tcp, 10);
        });
        nw_endpoint_t endpoint = nw_endpoint_create_host(host, port);
        if (!parameters || !endpoint) return NULL;
        native.connection = nw_connection_create(endpoint, parameters);
        if (!native.connection || !native.queue) return NULL;
        nw_connection_set_queue(native.connection, native.queue);
        nw_connection_set_state_changed_handler(native.connection, ^(nw_connection_state_t value, nw_error_t error) {
            state(state_context, (int)value, errorDomain(error), errorCode(error));
        });
        return (__bridge_retained void *)native;
    }
}
void spice_nw_start(void *pointer) {
    SpiceNativeConnection *native = (__bridge SpiceNativeConnection *)pointer;
    nw_connection_start(native.connection);
}
void spice_nw_cancel(void *pointer) {
    SpiceNativeConnection *native = (__bridge SpiceNativeConnection *)pointer;
    nw_connection_cancel(native.connection);
}
void spice_nw_destroy(void *pointer) {
    if (!pointer) return;
    SpiceNativeConnection *native = (__bridge_transfer SpiceNativeConnection *)pointer;
    // cancel has already reached its final callback and all I/O callers joined.
    dispatch_sync(native.queue, ^{ nw_connection_set_state_changed_handler(native.connection, NULL); });
}
void spice_nw_read(void *pointer, uint8_t *destination, uint32_t minimum, uint32_t maximum,
                   SpiceNWComplete complete, void *context) {
    SpiceNativeConnection *native = (__bridge SpiceNativeConnection *)pointer;
    nw_connection_receive(native.connection, minimum, maximum,
        ^(dispatch_data_t content, nw_content_context_t content_context, bool end, nw_error_t error) {
            (void)content_context;
            __block size_t copied = 0;
            __block bool valid = true;
            if (content && !error) dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                (void)region; (void)offset;
                if (size > maximum - copied) { valid = false; return false; }
                memcpy(destination + copied, buffer, size);
                copied += size;
                return true;
            });
            complete(context, copied, end, valid ? errorDomain(error) : -1, valid ? errorCode(error) : -1);
        });
}
int spice_nw_write(void *pointer, const uint8_t *source, size_t size, SpiceNWComplete complete, void *context) {
    SpiceNativeConnection *native = (__bridge SpiceNativeConnection *)pointer;
    // DEFAULT copies caller storage; native retention cannot outlive a borrowed
    // Zig slice. Only one bounded send per transport can be pending.
    dispatch_data_t content = dispatch_data_create(source, size, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    if (!content) return 0;
    nw_connection_send(native.connection, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        complete(context, size, 0, errorDomain(error), errorCode(error));
    });
    return 1;
}
int spice_sec_certificate_valid(const uint8_t *bytes, size_t size) {
    if (size > LONG_MAX) return 0;
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, bytes, (CFIndex)size, kCFAllocatorNull);
    if (!data) return 0;
    SecCertificateRef cert = SecCertificateCreateWithData(NULL, data);
    CFRelease(data);
    if (!cert) return 0;
    CFRelease(cert);
    return 1;
}
int spice_sec_evaluate(void *opaque, int mode, const SpiceDER *ders, size_t count, const char *server_name) {
    @autoreleasepool {
        SecTrustRef trust = opaque;
        if (!trust || !count || (mode != 2 && mode != 3)) return 0;
        NSMutableArray *anchors = [NSMutableArray arrayWithCapacity:count];
        for (size_t i = 0; i < count; ++i) {
            if (ders[i].size > LONG_MAX) return 0;
            CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, ders[i].data, (CFIndex)ders[i].size, kCFAllocatorNull);
            if (!data) return 0;
            SecCertificateRef certificate = SecCertificateCreateWithData(NULL, data);
            CFRelease(data);
            if (!certificate) return 0;
            [anchors addObject:CFBridgingRelease(certificate)];
        }
        NSString *name = server_name ? [NSString stringWithUTF8String:server_name] : nil;
        if (mode == 2 && !name) return 0;
        SecPolicyRef policy = mode == 3 ? SecPolicyCreateBasicX509() : SecPolicyCreateSSL(true, (__bridge CFStringRef)name);
        if (!policy) return 0;
        OSStatus result = SecTrustSetPolicies(trust, policy);
        CFRelease(policy);
        if (result != errSecSuccess || SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors) != errSecSuccess ||
            SecTrustSetAnchorCertificatesOnly(trust, true) != errSecSuccess) return 0;
        return SecTrustEvaluateWithError(trust, NULL);
    }
}
int spice_sec_subject(void *opaque, int (*matches)(void *, const uint8_t *, size_t), void *context) {
    SecTrustRef trust = opaque;
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (!chain) return 0;
    int accepted = 0;
    if (CFArrayGetCount(chain)) {
        SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
        CFDataRef subject = SecCertificateCopyNormalizedSubjectSequence(leaf);
        if (subject) {
            accepted = matches(context, CFDataGetBytePtr(subject), (size_t)CFDataGetLength(subject));
            CFRelease(subject);
        }
    }
    CFRelease(chain);
    return accepted;
}
