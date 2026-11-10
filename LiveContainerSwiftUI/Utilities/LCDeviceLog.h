//
//  LCDeviceLog.h
//  LiveContainerSwiftUI
//
//  Records this device's own system log, for a report on built-in JIT.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads the device's system log the way a computer would, through a tunnel
/// to the device made with the pairing file built-in JIT uses and over the VPN
/// it goes through. Why the device turned built-in JIT away — a disk image it
/// would not mount, a session it closed — is said there and nowhere else, and
/// a user's device cannot be connected to a computer to read it.
///
/// An instance records once: from `start` until `stop`.
@interface LCDeviceLog : NSObject

/// Whether the library that reads the log is in this build. A Simulator build
/// has none.
@property(class, nonatomic, readonly) BOOL isAvailable;

/// - Parameters:
///   - pairingFile: The RemotePairing record built-in JIT connects with.
///   - keep: Called for each line, on the thread that reads them; only the
///     lines it accepts are kept.
- (instancetype)initWithPairingFile:(NSURL *)pairingFile keep:(BOOL (^)(NSString *line))keep;
- (instancetype)init NS_UNAVAILABLE;

/// Connects and starts recording, on a thread of its own. Returns at once.
- (void)start;

/// Blocks until the log is being read or the connection has failed, or for
/// `timeout` at most. Whether it is being read.
- (BOOL)waitUntilRecordingWithTimeout:(NSTimeInterval)timeout;

/// Stops keeping lines. The connection is closed once the line being waited
/// for arrives, which on a device is a moment later.
- (void)stop;

/// The lines kept so far, oldest first.
@property(nonatomic, readonly) NSArray<NSString *> *lines;

/// Why the log could not be read, or stopped being read; nil while all is well.
@property(nonatomic, readonly, nullable) NSString *failure;

@end

NS_ASSUME_NONNULL_END
