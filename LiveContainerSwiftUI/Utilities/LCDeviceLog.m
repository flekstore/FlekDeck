//
//  LCDeviceLog.m
//  LiveContainerSwiftUI
//
//  Records this device's own system log, for a report on built-in JIT.
//
//  The log is the syslog relay a computer reads with idevicesyslog. Since iOS
//  17 it is offered over RemoteXPC, so the way to it is the one StikJIT takes
//  to the debug service: the device's service directory at 10.7.0.1:49152,
//  which the VPN leads back to the device, a tunnel opened there with the
//  pairing file, and the relay reached through the tunnel.
//
//  StikJIT keeps idevice to itself, so the functions are taken from
//  IdevicePairing.dylib, which is built from the same library — see
//  IdevicePairing/build.sh and LCDevicePairing.m.
//

#import "LCDeviceLog.h"
#import <dlfcn.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <os/lock.h>
#import <stdatomic.h>

#pragma mark idevice

// The part of idevice's C interface used here, as its header declares it
// (https://github.com/jkcoxson/idevice, MIT).
typedef struct {
    int32_t code;
    int32_t sub_code;
    const char *message;
} LCIdeviceError;
typedef struct RpPairingFileHandle RpPairingFileHandle;
typedef struct AdapterHandle AdapterHandle;
typedef struct RsdHandshakeHandle RsdHandshakeHandle;
typedef struct SyslogRelayClientHandle SyslogRelayClientHandle;

static LCIdeviceError *(*rp_pairing_file_read)(const char *path, RpPairingFileHandle **out);
static void (*rp_pairing_file_free)(RpPairingFileHandle *handle);
static LCIdeviceError *(*tunnel_create_remotexpc)(const struct sockaddr *addr, socklen_t addr_len, const char *hostname,
                                                  RpPairingFileHandle *pairing_file,
                                                  const char *(*pin_callback)(void *context), void *pin_context,
                                                  AdapterHandle **out_adapter, RsdHandshakeHandle **out_handshake);
static void (*adapter_free)(AdapterHandle *handle);
static void (*rsd_handshake_free)(RsdHandshakeHandle *handle);
static LCIdeviceError *(*syslog_relay_connect_rsd)(AdapterHandle *provider, RsdHandshakeHandle *handshake,
                                                   SyslogRelayClientHandle **client);
static LCIdeviceError *(*syslog_relay_next)(SyslogRelayClientHandle *client, char **log_message);
static void (*syslog_relay_client_free)(SyslogRelayClientHandle *handle);
static void (*idevice_error_free)(LCIdeviceError *err);
static void (*idevice_string_free)(char *string);

static BOOL LCLoadLogLibrary(void) {
    static BOOL loaded;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"IdevicePairing.dylib"];
        void *library = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
        if(!library) {
            NSLog(@"[LC] IdevicePairing did not load: %s", dlerror());
            return;
        }
        rp_pairing_file_read = dlsym(library, "rp_pairing_file_read");
        rp_pairing_file_free = dlsym(library, "rp_pairing_file_free");
        tunnel_create_remotexpc = dlsym(library, "tunnel_create_remotexpc");
        adapter_free = dlsym(library, "adapter_free");
        rsd_handshake_free = dlsym(library, "rsd_handshake_free");
        syslog_relay_connect_rsd = dlsym(library, "syslog_relay_connect_rsd");
        syslog_relay_next = dlsym(library, "syslog_relay_next");
        syslog_relay_client_free = dlsym(library, "syslog_relay_client_free");
        idevice_error_free = dlsym(library, "idevice_error_free");
        idevice_string_free = dlsym(library, "idevice_string_free");
        // A dylib from before the log was added has the pairing functions only.
        loaded = rp_pairing_file_read && rp_pairing_file_free && tunnel_create_remotexpc &&
            adapter_free && rsd_handshake_free && syslog_relay_connect_rsd && syslog_relay_next &&
            syslog_relay_client_free && idevice_error_free && idevice_string_free;
    });
    return loaded;
}

/// Takes an error from the library, leaving a line saying where it happened.
static NSString *LCConsumeError(NSString *during, LCIdeviceError *error) {
    NSString *message = error->message ? @(error->message) : @"no message";
    NSString *line = [NSString stringWithFormat:@"%@: %@ (idevice code %d/%d)", during, message, error->code, error->sub_code];
    idevice_error_free(error);
    return line;
}

#pragma mark Recorder

/// Lines kept at most, so that a check left running cannot fill the memory.
static const NSUInteger LCDeviceLogLineLimit = 20000;

@implementation LCDeviceLog {
    NSURL *_pairingFile;
    BOOL (^_keep)(NSString *);
    os_unfair_lock _lock;
    NSMutableArray<NSString *> *_lines;
    NSString *_failure;
    atomic_bool _stopped;
    dispatch_semaphore_t _settled;
    atomic_bool _didSettle;
}

+ (BOOL)isAvailable {
    return LCLoadLogLibrary();
}

- (instancetype)initWithPairingFile:(NSURL *)pairingFile keep:(BOOL (^)(NSString *))keep {
    if((self = [super init])) {
        _pairingFile = pairingFile;
        _keep = [keep copy];
        _lock = OS_UNFAIR_LOCK_INIT;
        _lines = [NSMutableArray array];
        _settled = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)start {
    // The thread holds on to the recorder until it ends, which is after
    // `stop`, once the next line has arrived.
    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(record) object:nil];
    thread.name = @"com.fs.flekdeck.deviceLog";
    thread.qualityOfService = NSQualityOfServiceUtility;
    [thread start];
}

- (BOOL)waitUntilRecordingWithTimeout:(NSTimeInterval)timeout {
    dispatch_semaphore_wait(_settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    // Signalled again, for any other waiter.
    if(atomic_load(&_didSettle)) {
        dispatch_semaphore_signal(_settled);
    }
    os_unfair_lock_lock(&_lock);
    BOOL recording = atomic_load(&_didSettle) && !_failure;
    os_unfair_lock_unlock(&_lock);
    return recording;
}

- (void)stop {
    atomic_store(&_stopped, true);
}

- (NSArray<NSString *> *)lines {
    os_unfair_lock_lock(&_lock);
    NSArray *lines = [_lines copy];
    os_unfair_lock_unlock(&_lock);
    return lines;
}

- (NSString *)failure {
    os_unfair_lock_lock(&_lock);
    NSString *failure = _failure;
    os_unfair_lock_unlock(&_lock);
    return failure;
}

- (void)fail:(NSString *)failure {
    os_unfair_lock_lock(&_lock);
    _failure = failure;
    os_unfair_lock_unlock(&_lock);
    [self settle];
}

/// The connection is up or has failed: whoever waits on it can go on.
- (void)settle {
    if(!atomic_exchange(&_didSettle, true)) {
        dispatch_semaphore_signal(_settled);
    }
}

- (void)record {
    if(!LCLoadLogLibrary()) {
        [self fail:@"The log library is not in this build"];
        return;
    }

    RpPairingFileHandle *pairingFile = NULL;
    LCIdeviceError *error = rp_pairing_file_read(_pairingFile.fileSystemRepresentation, &pairingFile);
    if(error) {
        [self fail:LCConsumeError(@"Reading the pairing file", error)];
        return;
    }

    // Where the VPN leads back to the device, as StikJIT's configuration has it.
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(49152);
    inet_pton(AF_INET, "10.7.0.1", &address.sin_addr);

    AdapterHandle *adapter = NULL;
    RsdHandshakeHandle *handshake = NULL;
    error = tunnel_create_remotexpc((const struct sockaddr *)&address, sizeof(address), "FlekDeck",
                                    pairingFile, NULL, NULL, &adapter, &handshake);
    if(error) {
        rp_pairing_file_free(pairingFile);
        [self fail:LCConsumeError(@"Opening a tunnel to the device", error)];
        return;
    }

    SyslogRelayClientHandle *client = NULL;
    error = syslog_relay_connect_rsd(adapter, handshake, &client);
    if(error) {
        [self fail:LCConsumeError(@"Connecting to the device log", error)];
    } else {
        [self settle];
        NSUInteger count = 0;
        while(!atomic_load(&_stopped)) {
            char *message = NULL;
            error = syslog_relay_next(client, &message);
            if(error) {
                if(!atomic_load(&_stopped)) {
                    [self fail:LCConsumeError(@"Reading the device log", error)];
                } else {
                    idevice_error_free(error);
                }
                break;
            }
            if(!message) {
                continue;
            }
            NSString *line = [@(message) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            idevice_string_free(message);
            if(line.length == 0 || atomic_load(&_stopped) || !_keep(line)) {
                continue;
            }
            os_unfair_lock_lock(&_lock);
            if(count < LCDeviceLogLineLimit) {
                [_lines addObject:line];
                count++;
            }
            os_unfair_lock_unlock(&_lock);
        }
        syslog_relay_client_free(client);
    }
    // The client is a stream through the tunnel, so it goes first.
    rsd_handshake_free(handshake);
    adapter_free(adapter);
    rp_pairing_file_free(pairingFile);
}

@end
