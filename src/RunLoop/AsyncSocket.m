//
//  AsyncSocket.m
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#if !__has_feature(objc_arc)
#warning this file must be compiled with arc. use -fobjc-arc flag (or convert project to ARC).
#endif

#import "AsyncSocket.h"

#import <TargetConditionals.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>

#if TARGET_OS_IPHONE
#import <CFNetwork/CFNetwork.h>
#endif

#import "AsyncReadPacket.h"
#import "AsyncWritePacket.h"
#import "AsyncSpecialPacket.h"


#define DEFAULT_PREBUFFERING YES

#define READQUEUE_CAPACITY 5
#define WRITEQUEUE_CAPACITY 5
#define READALL_CHUNKSIZE 256
#define WRITE_CHUNKSIZE (1024*4)

#if DEBUG
#define DEBUG_THREAD_SAFETY 1
#else
#define DEBUG_THREAD_SAFETY 0
#endif

NSString *const AsyncSocketException = @"AsyncSocketException";
NSString *const AsyncSocketErrorDomain = @"AsyncSocketErrorDomain";

enum AsyncSocketFlags
{
    kEnablePreBuffering      = 1 <<  0,  // If set, pre-buffering is enabled
    kDidStartDelegate        = 1 <<  1,  // If set, disconnection results in delegate call
    kDidCompleteOpenForRead  = 1 <<  2,  // If set, open callback has been called for read stream
    kDidCompleteOpenForWrite = 1 <<  3,  // If set, open callback has been called for write stream
    kStartingReadTLS         = 1 <<  4,  // If set, we're waiting for TLS negotiation to complete
    kStartingWriteTLS        = 1 <<  5,  // If set, we're waiting for TLS negotiation to complete
    kForbidReadsWrites       = 1 <<  6,  // If set, no new reads or writes are allowed
    kDisconnectAfterReads    = 1 <<  7,  // If set, disconnect after no more reads are queued
    kDisconnectAfterWrites   = 1 <<  8,  // If set, disconnect after no more writes are queued
    kClosingWithError        = 1 <<  9,  // If set, the socket is being closed due to an error
    kDequeueReadScheduled    = 1 << 10,  // If set, a maybeDequeueRead operation is already scheduled
    kDequeueWriteScheduled   = 1 << 11,  // If set, a maybeDequeueWrite operation is already scheduled
    kSocketCanAcceptBytes    = 1 << 12,  // If set, we know socket can accept bytes. If unset, it's unknown.
    kSocketHasBytesAvailable = 1 << 13,  // If set, we know socket has bytes available. If unset, it's unknown.
};

static void MyCFSocketCallback(CFSocketRef, CFSocketCallBackType, CFDataRef, const void *, void *);
static void MyCFReadStreamCallback(CFReadStreamRef stream, CFStreamEventType type, void *pInfo);
static void MyCFWriteStreamCallback(CFWriteStreamRef stream, CFStreamEventType type, void *pInfo);

@implementation AsyncSocket

- (void)dealloc {
    [self close];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (instancetype)init {
    return  [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<AsyncSocketDelegate>)delegate {
    return [self initWithDelegate:delegate userData:0];
}

- (instancetype)initWithDelegate:(id<AsyncSocketDelegate>)delegate userData:(long)userData {
    if((self = [super init])) {
        _theFlags = DEFAULT_PREBUFFERING ? kEnablePreBuffering : 0;
        _theDelegate = delegate;
        _theUserData = userData;
        
        _theNativeSocket4 = 0;
        _theNativeSocket6 = 0;
        
        _theSocket4 = _theSocket6 = NULL;
        
        _theRunLoop = NULL;
        _theReadStream = NULL;
        _theWriteStream = NULL;
        
        _theConnectTimer = nil;
        
        _theReadQueue = [[NSMutableArray alloc] initWithCapacity:READQUEUE_CAPACITY];
        _theCurrentRead = nil;
        _theReadTimer = nil;
        _partialReadBuffer = [[NSMutableData alloc] initWithCapacity:READALL_CHUNKSIZE];
        
        _theWriteQueue = [[NSMutableArray alloc] initWithCapacity:WRITEQUEUE_CAPACITY];
        _theCurrentWrite = nil;
        _theWriteTimer = nil;
        
        // Socket context
        NSAssert(sizeof(CFSocketContext) == sizeof(CFStreamClientContext), @"CFSocketContext != CFStreamClientContext");
        _theContext.version = 0;
        _theContext.info = (__bridge void *)self;
        _theContext.retain = nil;
        _theContext.release = nil;
        _theContext.copyDescription = nil;
        
        //default run loop modes
        _theRunLoopModes = [NSArray arrayWithObject:NSDefaultRunLoopMode];
    }
    
    return self;
}

#pragma mark Thread-safety
- (void)checkForThreadSafety {
    if(_theRunLoop && (_theRunLoop != CFRunLoopGetCurrent())) {
        [NSException raise:AsyncSocketException format:@"Attempting to access AsyncSocket instance from incorrect thread."];
    }
}

#pragma mark  Progress
- (float)progressOfReadReturningTag:(long *)tag bytesDone:(NSUInteger *)done total:(NSUInteger *)total {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    // Check to make sure we're actually reading something right now,
    // and that the read packet isn't an AsyncSpecialPacket (upgrade to TLS).
    if(!_theCurrentRead || ![_theCurrentRead isKindOfClass:[AsyncReadPacket class]]) {
        if(tag != NULL) *tag = 0;
        if(done != NULL) *done = 0;
        if(NULL != total) *total = 0;
        
        return NAN;
    }
    
    // It's only possible to know the progress of our read if we're reading to a certain length.
    // If we're reading to data, we of course have no idea when the data will arrive.
    // If we're reading to timeout, then we have no idea when the next chunk of data will arrive.
    NSUInteger d = _theCurrentRead->_bytesDone;
    NSUInteger t = _theCurrentRead->_readLength;
    
    if(tag != NULL) *tag = _theCurrentRead->_tag;
    if(done != NULL) *done = d;
    if(total != NULL) *total = t;
    
    if(t > 0.0) {
        return (float)d / (float)t;
    }
    
    return 1.0F;
}

- (float)progressOfWriteReturningTag:(long *)tag bytesDone:(NSUInteger *)done total:(NSUInteger *)total {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    // Check to make sure we're actually writing something right now,
    // and that the write packet isn't an AsyncSpecialPacket (upgrade to TLS).
    if(!_theCurrentWrite || ![_theCurrentWrite isKindOfClass:[AsyncWritePacket class]]) {
        if(tag != NULL) *tag = 0;
        if(done != NULL) *done = 0;
        if(total != NULL) *total = 0;
        
        return NAN;
    }
    
    NSUInteger d = _theCurrentWrite->_bytesDone;
    NSUInteger t = _theCurrentWrite->_buffer.length;
    
    if(tag != NULL) *tag = _theCurrentWrite->_tag;
    if(done != NULL) *done = d;
    if(total != NULL) *total = t;
    
    return (float)d / (float)t;
}

#pragma mark Run Loop
- (void)runLoopAddSource:(CFRunLoopSourceRef)source {
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFRunLoopAddSource(_theRunLoop, source, (__bridge CFStringRef)runLoopMode);
    }
}

- (void)runLoopRemoveSource:(CFRunLoopSourceRef)source {
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFRunLoopRemoveSource(_theRunLoop, source, (__bridge CFStringRef)runLoopMode);
    }
}

- (void)runLoopAddSource:(CFRunLoopSourceRef)source mode:(NSString *)runLoopMode {
    CFRunLoopAddSource(_theRunLoop, source, (__bridge CFStringRef)runLoopMode);
}

- (void)runLoopRemoveSource:(CFRunLoopSourceRef)source mode:(NSString *)runLoopMode {
    CFRunLoopRemoveSource(_theRunLoop, source, (__bridge CFStringRef)runLoopMode);
}

- (void)runLoopAddTimer:(NSTimer *)timer {
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFRunLoopAddTimer(_theRunLoop, (__bridge CFRunLoopTimerRef)timer, (__bridge CFStringRef)runLoopMode);
    }
}

- (void)runLoopRemoveTimer:(NSTimer *)timer {
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFRunLoopRemoveTimer(_theRunLoop, (__bridge CFRunLoopTimerRef)timer, (__bridge CFStringRef)runLoopMode);
    }
}

- (void)runLoopAddTimer:(NSTimer *)timer mode:(NSString *)runLoopMode {
    CFRunLoopAddTimer(_theRunLoop, (__bridge CFRunLoopTimerRef)timer, (__bridge CFStringRef)runLoopMode);
}

- (void)runLoopRemoveTimer:(NSTimer *)timer mode:(NSString *)runLoopMode {
    CFRunLoopRemoveTimer(_theRunLoop, (__bridge CFRunLoopTimerRef)timer, (__bridge CFStringRef)runLoopMode);
}

- (void)runLoopUnscheduleReadStream {
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFReadStreamUnscheduleFromRunLoop(_theReadStream, _theRunLoop, (__bridge CFStringRef)runLoopMode);
    }
    
    CFReadStreamSetClient(_theReadStream, kCFStreamEventNone, NULL, NULL);
}

- (void)runLoopUnscheduleWriteStream {
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFWriteStreamUnscheduleFromRunLoop(_theWriteStream, _theRunLoop, (__bridge CFStringRef)runLoopMode);
    }
    
    CFWriteStreamSetClient(_theWriteStream, kCFStreamEventNone, NULL, NULL);
}

#pragma mark  Configuration
- (void)enablePreBuffering {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    _theFlags |= kEnablePreBuffering;
}

- (BOOL)moveToRunLoop:(NSRunLoop *)runLoop {
    NSAssert((_theRunLoop == NULL ) || _theRunLoop == CFRunLoopGetCurrent(), @"moveToRunLoop must be called from within the current RunLoop!");
    
    if(runLoop == nil) {
        return NO;
    }
    if(_theRunLoop == [runLoop getCFRunLoop]) {
        return YES;
    }
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _theFlags &= ~kDequeueReadScheduled;
    _theFlags &= ~kDequeueWriteScheduled;
    
    if(_theReadStream && _theWriteStream) {
        [self runLoopUnscheduleReadStream];
        [self runLoopUnscheduleWriteStream];
    }
    
    if(_theSource4) [self runLoopRemoveSource:_theSource4];
    if(_theSource6) [self runLoopRemoveSource:_theSource6];
    
    if(_theReadTimer) [self runLoopRemoveTimer:_theReadTimer];
    if(_theWriteTimer) [self runLoopRemoveTimer:_theWriteTimer];
    
    _theRunLoop = [runLoop getCFRunLoop];
    
    if(_theReadTimer) [self runLoopAddTimer:_theReadTimer];
    if(_theWriteTimer) [self runLoopAddTimer:_theWriteTimer];
    
    if(_theSource4) [self runLoopAddSource:_theSource4];
    if(_theSource6) [self runLoopAddSource:_theSource6];
    
    if(_theReadStream && _theWriteStream) {
        if(![self attachStreamsToRunLoop:runLoop error:nil]) {
            return NO;
        }
    }
    
    [runLoop performSelector:@selector(maybeDequeueRead) target:self argument:nil order:0 modes:_theRunLoopModes];
    [runLoop performSelector:@selector(maybeDequeueWrite) target:self argument:nil order:0 modes:_theRunLoopModes];
    [runLoop performSelector:@selector(maybeScheduleDisconnect) target:self argument:nil order:0 modes:_theRunLoopModes];
    
    return YES;
}

- (BOOL)setRunLoopModes:(NSArray *)runLoopModes {
    NSAssert(_theRunLoop == NULL || _theRunLoop == CFRunLoopGetCurrent(), @"setRunLoopModes must be called from within the current RunLoop!");
    
    if(_theRunLoopModes.count == 0) {
        return NO;
    }
    if([_theRunLoopModes isEqualToArray:runLoopModes]) {
        return YES;
    }
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _theFlags &= ~kDequeueReadScheduled;
    _theFlags &= ~kDequeueWriteScheduled;
    
    if(_theReadStream && _theWriteStream) {
        [self runLoopUnscheduleReadStream];
        [self runLoopUnscheduleWriteStream];
    }
    
    if(_theSource4) [self runLoopRemoveSource:_theSource4];
    if(_theSource6) [self runLoopRemoveSource:_theSource6];
    
    if(_theReadTimer) [self runLoopRemoveTimer:_theReadTimer];
    if(_theWriteTimer) [self runLoopRemoveTimer:_theWriteTimer];
    
    _theRunLoopModes = [runLoopModes copy];
    
    if(_theReadTimer) [self runLoopAddTimer:_theReadTimer];
    if(_theWriteTimer) [self runLoopAddTimer:_theWriteTimer];
    
    if(_theSource4) [self runLoopAddSource:_theSource4];
    if(_theSource6) [self runLoopAddSource:_theSource6];
    
    if(_theReadStream && _theWriteStream) {
        // Note: theRunLoop variable is a CFRunLoop, and NSRunLoop is NOT toll-free bridged with CFRunLoop.
        // So we cannot pass theRunLoop to the method below, which is expecting a NSRunLoop parameter.
        // Instead we pass nil, which will result in the method properly using the current run loop.
        if(![self attachStreamsToRunLoop:nil error:nil]) {
            return NO;
        }
    }
    
    [self performSelector:@selector(maybeDequeueRead) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    [self performSelector:@selector(maybeDequeueWrite) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    [self performSelector:@selector(maybeScheduleDisconnect) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    
    return YES;
}

- (BOOL)addRunLoopMode:(NSString *)runLoopMode {
    NSAssert(_theRunLoop == NULL || _theRunLoop == CFRunLoopGetCurrent(), @"addRunLoopMode must be called from within the current RunLoop!");
    
    if(runLoopMode == nil)
        return NO;
    if([_theRunLoopModes containsObject:runLoopMode])
        return YES;
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _theFlags &= ~kDequeueReadScheduled;
    _theFlags &= ~kDequeueWriteScheduled;
    
    NSArray *newRunLoopModes = [_theRunLoopModes arrayByAddingObject:runLoopMode];
    _theRunLoopModes = newRunLoopModes;
    
    if(_theReadTimer) [self runLoopAddTimer:_theReadTimer mode:runLoopMode];
    if(_theWriteTimer) [self runLoopAddTimer:_theWriteTimer mode:runLoopMode];
    
    if(_theSource4) [self runLoopAddSource:_theSource4 mode:runLoopMode];
    if(_theSource6) [self runLoopAddSource:_theSource6 mode:runLoopMode];
    
    if(_theReadStream && _theWriteStream) {
        CFReadStreamScheduleWithRunLoop(_theReadStream, CFRunLoopGetCurrent(), (__bridge CFStringRef)runLoopMode);
        CFWriteStreamScheduleWithRunLoop(_theWriteStream, CFRunLoopGetCurrent(), (__bridge CFStringRef)runLoopMode);
    }
    
    [self performSelector:@selector(maybeDequeueRead) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    [self performSelector:@selector(maybeDequeueWrite) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    [self performSelector:@selector(maybeScheduleDisconnect) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    
    return YES;
}

- (BOOL)removeRunLoopMode:(NSString *)runLoopMode {
    NSAssert(_theRunLoop == NULL || _theRunLoop == CFRunLoopGetCurrent(), @"addRunLoopMode must be called from within the current RunLoop!");
    
    if(runLoopMode == nil)
        return NO;
    if(![_theRunLoopModes containsObject:runLoopMode])
        return YES;
    
    NSMutableArray *newRunLoopModes = [_theRunLoopModes mutableCopy];
    [newRunLoopModes removeObject:runLoopMode];
    
    if(newRunLoopModes.count == 0)
        return NO;
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _theFlags &= ~kDequeueReadScheduled;
    _theFlags &= ~kDequeueWriteScheduled;
    
    _theRunLoopModes = [newRunLoopModes copy];
    
    if(_theReadTimer) [self runLoopRemoveTimer:_theReadTimer mode:runLoopMode];
    if(_theWriteTimer) [self runLoopRemoveTimer:_theWriteTimer mode:runLoopMode];
    
    if(_theSource4) [self runLoopRemoveSource:_theSource4 mode:runLoopMode];
    if(_theSource6) [self runLoopRemoveSource:_theSource6 mode:runLoopMode];
    
    if(_theReadStream && _theWriteStream) {
        CFReadStreamScheduleWithRunLoop(_theReadStream, CFRunLoopGetCurrent(), (__bridge CFStringRef)runLoopMode);
        CFWriteStreamScheduleWithRunLoop(_theWriteStream, CFRunLoopGetCurrent(), (__bridge CFStringRef)runLoopMode);
    }
    
    [self performSelector:@selector(maybeDequeueRead) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    [self performSelector:@selector(maybeDequeueWrite) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    [self performSelector:@selector(maybeScheduleDisconnect) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    
    return YES;
}

- (NSArray *)runLoopModes {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    return _theRunLoopModes;
}

#pragma mark Accepting
- (BOOL)acceptOnPort:(UInt16)port error:(NSError **)errPtr {
    return [self acceptOnInterface:nil port:port error:errPtr];
}

/**
 * To accept on a certain interface, pass the address to accept on.
 * To accept on any interface, pass nil or an empty string.
 * To accept only connections from localhost pass "localhost" or "loopback".
 **/
- (BOOL)acceptOnInterface:(NSString *)interface port:(UInt16)port error:(NSError **)errPtr {
    if(_theDelegate == NULL) {
        [NSException raise:AsyncSocketException format:@"Attempting to accept without a delegate. Set a delegate first."];
    }
    
    if(![self isDisconnected]) {
        [NSException raise:AsyncSocketException
                    format:@"Attempting to accept while connected or accepting connections. Disconnect first."];
    }
    
    // clear queues (spurious read/write requests post disconnect)
    [self emptyQueues];
    
    // set up the listen sockaddr structs if needed.
    NSData *address4 = nil, *address6 = nil;
    if(interface == nil || interface.length == 0) {
        // accept on ANY address
        struct sockaddr_in nativeAddr4;
        nativeAddr4.sin_len = sizeof(struct sockaddr_in);
        nativeAddr4.sin_family = AF_INET;
        nativeAddr4.sin_port = HTONS(port);
        nativeAddr4.sin_addr.s_addr = htonl(INADDR_ANY);
        memset(&(nativeAddr4.sin_zero), 0, sizeof(nativeAddr4.sin_zero));

        struct sockaddr_in6 nativeAddr6;
        nativeAddr6.sin6_len = sizeof(struct sockaddr_in6);
        nativeAddr6.sin6_family = AF_INET6;
        nativeAddr6.sin6_port = htons(port);
        nativeAddr6.sin6_flowinfo = 0;
        nativeAddr6.sin6_addr = in6addr_any;
        nativeAddr6.sin6_scope_id = 0;
        
        // wrap the native address structures for CFSocketSetAddress.
        address4 = [NSData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
        address6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
    }
    else if([interface isEqualToString:@"localhost"] || [interface isEqualToString:@"lookback"]) {
        // accept only on LOOPBACK address
        struct sockaddr_in nativeAddr4;
        nativeAddr4.sin_len = sizeof(struct sockaddr_in);
        nativeAddr4.sin_family = AF_INET;
        nativeAddr4.sin_port = htons(port);
        nativeAddr4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        memset(&(nativeAddr4.sin_zero), 0, sizeof(nativeAddr4.sin_zero));
        
        struct sockaddr_in6 nativeAddr6;
        nativeAddr6.sin6_len = sizeof(struct sockaddr_in6);
        nativeAddr6.sin6_family = AF_INET6;
        nativeAddr6.sin6_port = htons(port);
        nativeAddr6.sin6_flowinfo = 0;
        nativeAddr6.sin6_addr = in6addr_loopback;
        nativeAddr6.sin6_scope_id = 0;
        
        // wrap the native address structures for CFSocketSetAddress.
        address4 = [NSData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
        address6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
    }
    else {
        NSString *portStr = [NSString stringWithFormat:@"%hu", port];
        
        struct addrinfo hints, *res, *res0;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = PF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_protocol = IPPROTO_TCP;
        hints.ai_flags = AI_PASSIVE;
        
        int error = getaddrinfo(interface.UTF8String, portStr.UTF8String, &hints, &res0);
        if(error) {
            if(errPtr) {
                NSString *errMsg = [NSString stringWithCString:gai_strerror(error) encoding:NSASCIIStringEncoding];
                NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
                
                *errPtr = [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:error userInfo:info];
            }
        }
        else {
            for(res=res0; res; res=res->ai_next) {
                if(!address4 && res->ai_family == AF_INET) {
                    // found IPv4 address
                    // wrap the native address structures for CFSocketSetAddress.
                    address4 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
                }
                else if(!address6 && res->ai_family == AF_INET6) {
                    // found IPv6 address
                    address6 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
                }
            }
            freeaddrinfo(res0);
        }
        
        if(!address4 && !address6) return NO;
    }
    
    // create the sockets.
    if(address4) {
        _theSocket4 = [self newAcceptSocketForAddress:address4 error:errPtr];
        if(_theSocket4 == NULL) goto Failed;
    }
    if(address6) {
        _theSocket6 = [self newAcceptSocketForAddress:address6 error:errPtr];
#if !TARGET_OS_IPHONE
        if(_theSocket6 == NULL) goto Failed;
    
#endif
    }
    
    // Attach the sockets to the run loop so that callback methods work
    [self attachSocketsToRunLoop:nil error:nil];
    
    // Set the OS_REUSEADDR flags.
    int reuseOn = 1;
    if(_theSocket4) setsockopt(CFSocketGetNative(_theSocket4), SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
    if(_theSocket6) setsockopt(CFSocketGetNative(_theSocket6), SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
    
    // set the local binding which acuses the sockets to start listening.
    
    CFSocketError err;
    if(_theSocket4) {
        err = CFSocketSetAddress(_theSocket4, (__bridge CFDataRef)address4);
        if(err != kCFSocketSuccess) goto Failed;
        
    }
    
    if(port == 0 && _theSocket4 && _theSocket6) {
        // The user has passed in port 0, which means he wants to allow the kernel to choose the port for them
        // However, the kernel will choose a different port for both theSocket4 and theSocket6
        // So we grab the port the kernel choose for theSocket4, and set it as the port for theSocket6
        UInt16 chosePort = [self localPortFromCFSocket4:_theSocket4];
        
        struct sockaddr_in6 *pSockAddr6 = (struct sockaddr_in6 *)[address6 bytes];
        if(pSockAddr6) // if statement to quiet the static analyzer
        {
            pSockAddr6->sin6_port = htons(chosePort);
        }
    }
    
    if(_theSocket6) {
        err = CFSocketSetAddress(_theSocket6, (__bridge CFDataRef)address6);
        if(err != kCFSocketSuccess) goto Failed;
    }
    
    _theFlags |= kDidStartDelegate;
    return YES;
    
Failed:
    if(errPtr) *errPtr = [self getSocketError];
    if(_theSocket4 == NULL) {
        CFSocketInvalidate(_theSocket4);
        CFRelease(_theSocket4);
        _theSocket4 = NULL;
    }
    
    if(_theSocket6 == NULL) {
        CFSocketInvalidate(_theSocket6);
        CFRelease(_theSocket6);
        _theSocket6 = NULL;
    }
    
    return NO;
}

#pragma mark Connecting
- (BOOL)connectToHost:(NSString *)hostname onPort:(UInt16)port error:(NSError **)errPtr {
    return [self connectToHost:hostname onPort:port withTimeout:-1 error:errPtr];
}

- (BOOL)connectToHost:(NSString *)hostname onPort:(UInt16)port withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr {
    if(_theDelegate == NULL) {
        [NSException raise:AsyncSocketException format:@"Attempting to connect without a delegate. Set a delegate first"];
    }
    if(![self isDisconnected]) {
        [NSException raise:AsyncSocketException format:@"Attempting to connect while connected or accepting connections. DisConnect first"];
    }
    
    // clear queues (spurious read/write requests post disconnect)
    [self emptyQueues];
    
    if(![self createStreamsToHost:hostname onPort:port error:errPtr])
        goto Failed;
    if(![self attachStreamsToRunLoop:nil error:errPtr])
        goto Failed;
    if(![self configureSocketAndReturnError:errPtr])
        goto Failed;
    if(![self openStreamsAndReturnError:errPtr])
        goto Failed;
    
    [self startConnectTimeout:timeout];
    _theFlags |= kDidStartDelegate;
    
    return YES;
Failed:
    [self close];
    return NO;
}

- (BOOL)connectToAddress:(NSData *)remoteAddress error:(NSError **)errPtr {
    return [self connectToAddress:remoteAddress withTimeout:-1 error:errPtr];
}

- (BOOL)connectToAddress:(NSData *)remoteAddress withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr {
    return [self connectToAddress:remoteAddress viaInterfaceAddress:nil withTimeout:timeout error:errPtr];
}

/**
 * This method is similar to the one above, but allows you to specify which socket interface
 * the connection should run over. E.g. ethernet, wifi, bluetooth, etc.
 **/
- (BOOL)connectToAddress:(NSData *)remoteAddress viaInterfaceAddress:(NSData *)interfaceAddress withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr {
    if(_theDelegate == NULL) {
        [NSException raise:AsyncSocketException format:@"Attempting to connect without a delegate. Set a delegate first."];
    }
    
    if(![self isDisconnected]) {
        [NSException raise:AsyncSocketException format:@"Attempting to connect while connected or accepting connections. Disconnect first."];
    }
    
    // clear Queues (spurious read/write requests post disconnect)
    [self emptyQueues];
    
    if(![self createSocketForAddress:remoteAddress error:errPtr])
        goto Failed;
    if(![self bindSocketToAddress:interfaceAddress error:errPtr])
        goto Failed;
    if(![self attachSocketsToRunLoop:nil error:errPtr])
        goto Failed;
    if(![self configureSocketAndReturnError:errPtr])
        goto Failed;
    if(![self connectSocketToAddress:remoteAddress error:errPtr])
        goto Failed;
    
    [self startConnectTimeout:timeout];
    _theFlags |= kDidStartDelegate;
        
    return YES;

Failed:
    [self close];
    return NO;
}

- (void)startConnectTimeout:(NSTimeInterval)timeout {
    if(timeout >= 0.0) {
        _theConnectTimer = [NSTimer timerWithTimeInterval:timeout target:self selector:@selector(doConnectTimeout:) userInfo:nil repeats:NO];
        
        [self runLoopAddTimer:_theConnectTimer];
    }
}
- (void)endConnectTimout {
    [_theConnectTimer invalidate], _theConnectTimer = nil;
}

- (void)doConnectTimeout:(__unused NSTimer *)timer {
#pragma unused(timer)
    
    [self endConnectTimout];
    [self closeWithError:[self getconnectTimeoutError]];
}

#pragma mark Socket Implementation
- (BOOL)createSocketForAddress:(NSData *)remoteAddr error:(NSError **)errPtr {
    struct sockaddr *pSockAddr = (struct sockaddr *)[remoteAddr bytes];
    
    if(pSockAddr->sa_family == AF_INET) {
        _theSocket4 = CFSocketCreate(NULL,  // Default allocator
                                     PF_INET, // Protocol Family
                                     SOCK_STREAM, //Socket type
                                     IPPROTO_TCP, // protocol
                                     kCFSocketConnectCallBack, // callback flags
                                     (CFSocketCallBack)&MyCFSocketCallback, // callback method
                                     &_theContext // socket
                                     );
        if(_theSocket4 == NULL) {
            if(errPtr) *errPtr = [self getSocketError];
            return NO;
        }
    }
    else if(pSockAddr->sa_family == AF_INET6) {
        _theSocket6 = CFSocketCreate(NULL, // default allocator
                                     PF_INET6, // protocol family
                                     SOCK_STREAM, // socket type
                                     IPPROTO_TCP, //protocol
                                     kCFSocketConnectCallBack, //callback flags
                                     (CFSocketCallBack)&MyCFSocketCallback, // callback method
                                     &_theContext // socket context
                                     );
        if(_theSocket6 == NULL) {
            if(errPtr) *errPtr = [self getSocketError];
            return NO;
        }
    }
    else {
        if(errPtr) {
            NSString *errMsg = @"Remote address is not IPv4 or IPv6";
            NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
            
            *errPtr = [NSError errorWithDomain:AsyncSocketErrorDomain code:AsyncSocketCFSocketError userInfo:info];
        }
        return NO;
    }
    
    return YES;
}

- (BOOL)bindSocketToAddress:(NSData *)interfaceAddr error:(NSError **)errPtr {
    if(interfaceAddr == nil) return YES;
    
    struct sockaddr *pSockAddr = (struct sockaddr *)[interfaceAddr bytes];
    
    CFSocketRef theSocket = (_theSocket4 != NULL) ? _theSocket4 : _theSocket6;
    NSAssert(theSocket != NULL, @"bindSocketToAddress called without valid socket");
    
    CFSocketNativeHandle nativeSocket = CFSocketGetNative(theSocket);
    
    if(pSockAddr->sa_family == AF_INET || pSockAddr->sa_family == AF_INET6) {
        int result = bind(nativeSocket, pSockAddr, (socklen_t)interfaceAddr.length);
        if(result != 0) {
            if(errPtr) *errPtr = [self getErrnoError];
            return NO;
        }
    }
    else {
        if(errPtr) {
            NSString *errMsg = @"Interface address is not IPv4 or IPv6";
            NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
            
            *errPtr = [NSError errorWithDomain:AsyncSocketErrorDomain code:AsyncSocketCFSocketError userInfo:info];
        }
        
        return NO;
    }
    
    return YES;
}

/**
 * Creates the accept sockets.
 * Returns true if either IPv4 or IPv6 is created.
 * If either is missing, an error is returned (even though the method may return true).
 **/
- (CFSocketRef)newAcceptSocketForAddress:(NSData *)addr error:(NSError **)errPtr {
    struct sockaddr *pSockAddr = (struct sockaddr *)[addr bytes];
    int addressFamily = pSockAddr->sa_family;
    
    CFSocketRef theSockt = CFSocketCreate(kCFAllocatorDefault, addressFamily, SOCK_STREAM, 0, kCFSocketAcceptCallBack, (CFSocketCallBack)&MyCFSocketCallback, &_theContext);
    if(theSockt == NULL) {
        if(errPtr) *errPtr = [self getSocketError];
    }
    
    return theSockt;
}

/**
 * Adds the CFSocket's to the run-loop so that callbacks will work properly.
 **/
- (BOOL)attachSocketsToRunLoop:(NSRunLoop *)runLoop error:(__unused NSError **)errPtr {
    // Get the CFRunLoop to whitch the socket should be attached.
    _theRunLoop = (runLoop == nil) ? CFRunLoopGetCurrent() : [runLoop getCFRunLoop];
    if(_theSocket4) {
        _theSource4 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _theSocket4, 0);
        [self runLoopAddSource:_theSource4];
    }
    
    if(_theSource6) {
        _theSource6 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _theSocket6, 0);
        [self runLoopAddSource:_theSource6];
    }
    
    return YES;
}

/**
 * Allows the delegate method to configure the CFSocket or CFNativeSocket as desired before we connect.
 * Note that the CFReadStream and CFWriteStream will not be available until after the connection is opened.
 **/
- (BOOL)configureSocketAndReturnError:(NSError **)errPtr {
    // call the delegate method for further configuration
    if([_theDelegate respondsToSelector:@selector(onSocketWillConnect:)]) {
        if([_theDelegate onSocketWillConnect:self] == NO) {
            if(errPtr) *errPtr = [self getAbortError];
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)connectSocketToAddress:(NSData *)remoteAddr error:(NSError **)errPtr {
    // start connecting to the given address in the background
    //the MyCFSocketCallback method will be called when the connection succeeds or fails
    if(_theSocket4) {
        CFSocketError err = CFSocketConnectToAddress(_theSocket4, (__bridge CFDataRef)remoteAddr, -1);
        if(err != kCFSocketSuccess) {
            if(errPtr) *errPtr = [self getSocketError];
            return NO;
        }
    }
    else if(_theSocket6) {
        CFSocketError err = CFSocketConnectToAddress(_theSocket6, (__bridge CFDataRef)remoteAddr, -1);
        if(err != kCFSocketSuccess) {
            if(errPtr) *errPtr = [self getSocketError];
            return NO;
        }
    }
    
    return YES;
}

/**
 * Attempt to make the new socket.
 * If an error occurs, ignore this event.
 **/
- (void)doAcceptFromSocket:(CFSocketRef)parentSocket withNewNativeSocket:(CFSocketNativeHandle)newNativeSocket {
    if(newNativeSocket) {
        // New socket inherits same delegate and run loop modes.
        // Note: We use [self class] to support subclassing AsyncSocket.
        AsyncSocket *newSocket = [[[self class] alloc] initWithDelegate:_theDelegate];
        [newSocket setRunLoopModes:_theRunLoopModes];
        
        if(![newSocket createStreamsFromNative:newNativeSocket error:nil]) {
            [newSocket close];
            return;
        }
        
        if(parentSocket == _theSocket4) {
            newSocket->_theNativeSocket4 = newNativeSocket;
        }
        else newSocket->_theNativeSocket6 = newNativeSocket;
        
        if([_theDelegate respondsToSelector:@selector(onSocket:didAcceptNewSocket:)]) {
            [_theDelegate onSocket:self didAcceptNewSocket:newSocket];
        }
        newSocket->_theFlags |= kDidStartDelegate;
        
        NSRunLoop *runLoop = nil;
        if([_theDelegate respondsToSelector:@selector(onSocket:wantsRunLoopForNewSocket:)]) {
            runLoop = [_theDelegate onSocket:self wantsRunLoopForNewSocket:newSocket];
        }
        
        if(![newSocket attachSocketsToRunLoop:runLoop error:nil])
            goto Failed;
        if(![newSocket configureSocketAndReturnError:nil])
            goto Failed;
        if(![newSocket openStreamsAndReturnError:nil])
            goto Failed;
        
        return;
        
    Failed:
        [newSocket close];
    }
}

/**
 * This method is called as a result of connectToAddress:withTimeout:error:.
 * At this point we have an open CFSocket from which we need to create our read and write stream.
 **/
- (void)doSocketOpen:(CFSocketRef)sock withCFSocketError:(CFSocketError)socketError {
    NSParameterAssert((sock==_theSocket4) || (sock == _theSocket6));
    
    if(socketError == kCFSocketTimeout || socketError == kCFSocketError) {
        [self closeWithError:[self getSocketError]];
        return;
    }
    
    // get the underlying native (BSD) socket
    CFSocketNativeHandle nativeSocket = CFSocketGetNative(sock);
    // store a reference to it
    if(sock == _theSocket4) {
        _theNativeSocket4 = nativeSocket;
    }
    else
        _theNativeSocket6 = nativeSocket;
    
    CFSocketInvalidate(sock);
    CFRelease(sock);
    _theSocket4 = NULL;
    _theSocket6 = NULL;
    
    NSError *err;
    BOOL pass = YES;
    
    if(pass && ![self createStreamsFromNative:nativeSocket error:&err]) pass = NO;
    if(pass && ![self attachStreamsToRunLoop:nil error:&err]) pass = NO;
    if(pass && ![self openStreamsAndReturnError:&err]) pass = NO;
    
    if(!pass) [self closeWithError:err];
}

#pragma mark Stream Implementation
- (BOOL)createStreamsFromNative:(CFSocketNativeHandle)native error:(NSError **)errPtr {
    // create the socket & streams
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, native, &_theReadStream, &_theWriteStream);
    if(_theReadStream == NULL || _theWriteStream == NULL) {
        NSError *err = [self getStreamError];
        NSLog(@"AsyncSocket %p counldn't create streams from accepted socket: %@", self, err);
        
        if(errPtr) *errPtr = err;
        return NO;
    }
    // Ensure the CF & BSD socket is closed when the streams are closed.
    CFReadStreamSetProperty(_theReadStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(_theWriteStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    
    return YES;
}

- (BOOL)createStreamsToHost:(NSString *)hostname onPort:(UInt16)port error:(NSError **)errPtr {
    // create the socket & streams
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)hostname, port, &_theReadStream, &_theWriteStream);
    if(_theWriteStream == NULL ||   _theReadStream == NULL ) {
        if(errPtr) *errPtr = [self getStreamError];
        
        return NO;
    }
    
    // ensure the CF & BSD socket is closed when the streams are closed
    CFReadStreamSetProperty(_theReadStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(_theWriteStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    
    return YES;
}

- (BOOL)attachStreamsToRunLoop:(NSRunLoop *)runLoop error:(NSError **)errPtr {
    // get the CFRunLoop to which the socket should be attached
    _theRunLoop = (runLoop == nil) ? CFRunLoopGetCurrent() : [runLoop getCFRunLoop];
    
    // setup read stream callbacks
    CFOptionFlags readStreamEvents = kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred |
        kCFStreamEventEndEncountered |
        kCFStreamEventOpenCompleted;
    if(!CFReadStreamSetClient(_theReadStream, readStreamEvents, (CFReadStreamClientCallBack)&MyCFReadStreamCallback, (CFStreamClientContext *)(&_theContext))) {
        NSError *err = [self getStreamError];
        
        NSLog(@"AsyncSocket %p couldn't attach read stream to run-loop,", self);
        NSLog(@"Error: %@", err);
        
        if(errPtr) *errPtr = err;
        return NO;
    }
    
    // setup write stream callbacks
    CFOptionFlags writeStreamEvents = kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered | kCFStreamEventOpenCompleted;
    
    if(!CFWriteStreamSetClient(_theWriteStream, writeStreamEvents, (CFWriteStreamClientCallBack)&MyCFWriteStreamCallback, (CFStreamClientContext *)(&_theContext))) {
        NSError *err = [self getStreamError];
        NSLog (@"AsyncSocket %p couldn't attach write stream to run-loop,", self);
        NSLog (@"Error: %@", err);
        
        if (errPtr) *errPtr = err;
        return NO;
    }
    
    // add read and write streams to run loop
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFReadStreamScheduleWithRunLoop(_theReadStream, _theRunLoop, (__bridge CFStringRef)runLoopMode);
        CFWriteStreamScheduleWithRunLoop(_theWriteStream, _theRunLoop, (__bridge CFStringRef)runLoopMode);
    }
    
    return YES;
}

/**
 * Allows the delegate method to configure the CFReadStream and/or CFWriteStream as desired before we connect.
 *
 * If being called from a connect method,
 * the CFSocket and CFNativeSocket will not be available until after the connection is opened.
 **/
- (BOOL)configureStreamsAndReturnError:(NSError **)errPtr {
    // Call the delegate method for further configuration
    if([_theDelegate respondsToSelector:@selector(onSocketWillConnect:)]) {
        if([_theDelegate onSocketWillConnect:self] == NO) {
            if(errPtr) *errPtr = [self getAbortError];
            
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)openStreamsAndReturnError:(NSError **)errPtr {
    BOOL pass = YES;
    
    if(pass && !CFReadStreamOpen(_theReadStream)) {
        NSLog(@"AsyncSocket %p couldn't open read stream,", self);
        pass = NO;
    }
    
    if(pass && !CFWriteStreamOpen(_theWriteStream)) {
        NSLog(@"AsyncSocket %p couldn't open write stream,", self);
        pass = NO;
    }
    
    if(!pass) {
        if(errPtr) *errPtr = [self getStreamError];
    }
    return pass;
}

/**
 * Called when read or write streams open.
 * When the socket is connected and both streams are open, consider the AsyncSocket instance to be ready.
 **/
- (void)doStreamOpen {
    if((_theFlags & kDidCompleteOpenForRead) && (_theFlags & kDidCompleteOpenForWrite)) {
        NSError *err = nil;
        
        // get the socket
        if(![self setSocketFromStreamsAndReturnError:&err]) {
            NSLog(@"AsyncSocket %p counldn't get socket from streams, %@.Disconnecting.", self, err);
            [self closeWithError:err];
            return;
        }
        
        // Stop the connection attempt timeout timer
        [self endConnectTimout];
        
        if([_theDelegate respondsToSelector:@selector(onSocket:didConnectToHost:port:)]) {
            [_theDelegate onSocket:self didConnectToHost:[self connectedHost] port:[self connectedPort]];
        }
        
        // Immediately deal with any already-queued requests.
        [self maybeDequeueRead];
        [self maybeDequeueWrite];
    }
}

- (BOOL)setSocketFromStreamsAndReturnError:(NSError **)errPtr {
    // Get the CFSocketNativeHandle from _theReadStream
    CFSocketNativeHandle native;
    CFDataRef nativeProp = CFReadStreamCopyProperty(_theReadStream, kCFStreamPropertySocketNativeHandle);
    if(NULL == nativeProp) {
        if(errPtr) *errPtr = [self getStreamError];
        return NO;
    }
    
    CFIndex nativePropLen = CFDataGetLength(nativeProp);
    CFIndex nativeLen = (CFIndex)sizeof(native);
    
    CFIndex len = MIN(nativePropLen, nativeLen);
    
    CFDataGetBytes(nativeProp, CFRangeMake(0, len), (UInt8 *)&native);
    CFRelease(nativeProp);
    
    CFSocketRef theSocket = CFSocketCreateWithNative(kCFAllocatorDefault, native, 0, NULL, NULL);
    if(NULL == theSocket) {
        if(errPtr) *errPtr = [self getSocketError];
        return NO;
    }
    
    if(_theNativeSocket4 > 0) {
        _theSocket4 =theSocket;
        return YES;
    }
    
    if(_theNativeSocket6 > 0) {
        _theSocket6 = theSocket;
        return YES;
    }
    
    CFDataRef peeraddr = CFSocketCopyPeerAddress(theSocket);
    if(NULL == peeraddr) {
        NSLog(@"AsyncSocket couldn't determine IP version of socket");
        CFRelease(theSocket);
        if(errPtr) *errPtr = [self getSocketError];
        return NO;
    }
    
    struct sockaddr *sa = (struct sockaddr *)CFDataGetBytePtr(peeraddr);
    if(sa->sa_family == AF_INET) {
        _theSocket4 = theSocket;
        _theNativeSocket4 = native;
    }
    else {
        _theSocket6 = theSocket;
        _theNativeSocket6 = native;
    }
    
    CFRelease(peeraddr);
    
    return YES;
}

#pragma mark Disconnect Implementation
// sends error message and disconnects
- (void)closeWithError:(NSError *)err {
    _theFlags |= kClosingWithError;
    
    if(_theFlags & kDidStartDelegate) {
        // try to savage what data we can.
        [self recoverUnreadData];
        
        // let the delegate know, so it can try to recover if it liskes
        if([_theDelegate respondsToSelector:@selector(onSocket:willDisconnectWithError:)]) {
            [_theDelegate onSocket:self willDisconnectWithError:err];
        }
    }
    
    [self close];
}

// Prepare partially read data for recovery.
- (void)recoverUnreadData {
    if(_theCurrentRead != nil) {
        // We never finished the current read.
        // Check to see if it's a normal read packet (not AsyncSpecialPacket) and if it had read anything yet.
        
        if([_theCurrentRead isKindOfClass:[AsyncReadPacket class]] && (_theCurrentRead->_bytesDone > 0)) {
            // we need to move its data into the front of the partial read buffer.
            void *buffer = [_theCurrentRead->_buffer mutableBytes] + _theCurrentRead->_startOffset;
            [_partialReadBuffer replaceBytesInRange:NSMakeRange(0, 0) withBytes:buffer length:_theCurrentRead->_bytesDone];
        }
    }
    
    [self emptyQueues];
}

- (void)emptyQueues {
//    if(_theCurrentRead != nil) [self end]
}

- (void)close {

}

- (void)disconnect {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    [self close];
}

#pragma mark Reading
- (void)readDataWithTimeout:(NSTimeInterval)timeout tag:(long)tag {
    [self readDataWithTimeout:timeout buffer:nil bufferOffset:0 tag:tag];
}

- (void)readDataWithTimeout:(NSTimeInterval)timeout buffer:(NSMutableData *)buffer bufferOffset:(NSUInteger)offset tag:(long)tag {
    [self readDataWithTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}

- (void)readDataWithTimeout:(NSTimeInterval)timeout buffer:(NSMutableData *)buffer bufferOffset:(NSUInteger)offset maxLength:(NSUInteger)length tag:(long)tag {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    if(offset > buffer.length) return;
    if(_theFlags & kForbidReadsWrites) return;
    
    AsyncReadPacket *packet = [[AsyncReadPacket alloc] initWithData:buffer startOffset:offset maxLength:length timeout:timeout readLength:0 terminator:nil tag:tag];
    [_theReadQueue addObject:packet];
    [self scheduleDequeueRead];
}

- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout tag:(long)tag {
    [self readDataToLength:length withTimeout:timeout buffer:nil bufferOffset:0 tag:tag];
}

- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout buffer:(NSMutableData *)buffer bufferOffset:(NSUInteger)offset tag:(long)tag {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    if(length == 0) return;
    if(offset > buffer.length) return;
    if(_theFlags & kForbidReadsWrites) return;
    
    AsyncReadPacket *packet = [[AsyncReadPacket alloc] initWithData:buffer startOffset:offset maxLength:0 timeout:timeout readLength:length terminator:nil tag:tag];
    [_theReadQueue addObject:packet];
    [self scheduleDequeueRead];
}

- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag {
    [self readDataToData:data withTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}

- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout buffer:(NSMutableData *)buffer bufferOffset:(NSUInteger)offset tag:(long)tag {
    [self readDataToData:data withTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}

- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout maxLength:(NSUInteger)length tag:(long)tag {
    [self readDataToData:data withTimeout:timeout buffer:nil bufferOffset:0 maxLength:length tag:tag];
}

- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout buffer:(NSMutableData *)buffer bufferOffset:(NSUInteger)offset maxLength:(NSUInteger)length tag:(long)tag {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    if(data == nil || data.length == 0) return;
    if(offset > buffer.length) return;
    if(length > 0 && length < data.length) return;
    if(_theFlags & kForbidReadsWrites) return;
    
    AsyncReadPacket *packet = [[AsyncReadPacket alloc] initWithData:buffer startOffset:offset maxLength:length timeout:timeout readLength:0 terminator:data tag:tag];
    [_theReadQueue addObject:packet];
    [self scheduleDequeueRead];
}

/**
 * Puts a maybeDequeueRead on the run loop.
 * An assumption here is that selectors will be performed consecutively within their priority.
 **/
- (void)scheduleDequeueRead {
    if((_theFlags & kDequeueReadScheduled) == 0) {
        _theFlags |= kDequeueReadScheduled;
        [self performSelector:@selector(maybeDequeueRead) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    }
}

/**
 * This method starts a new read, if needed.
 * It is called when a user requests a read,
 * or when a stream opens that may have requested reads sitting in the queue, etc.
 **/
- (void)maybeDequeueRead {
    // unset the flag indicating a call to this method is scheduled
    _theFlags &= ~kDequeueReadScheduled;
    
    //if we're not currently processing a read AND we hava an available read stream.
    if(_theCurrentRead == nil && _theReadStream != NULL) {
        if(_theReadQueue.count > 0) {
            // dequeue the next object in the write queue
            _theCurrentRead = [_theReadQueue objectAtIndex:0];
            [_theReadQueue removeObjectAtIndex:0];
            if([_theReadQueue isKindOfClass:[AsyncSpecialPacket class]]) {
                // Attempt to start TLS
                _theFlags |= kStartingReadTLS;
                // This method won't do anything unless both kStartingReadTLS and kStartingWriteTLS are set
                [self maybeStartTLS];
            }
            else {
                // start time-out timer
                if(_theCurrentRead->_timeout > 0.0) {
                    _theReadTimer = [NSTimer timerWithTimeInterval:_theCurrentRead->_timeout target:self selector:@selector(doReadTimeout:) userInfo:nil repeats:NO];
                    [self runLoopAddTimer:_theReadTimer];
                }
                
                // Immediately read, if possible
                [self doBytesAvailable];
            }
        }
        else if(_theFlags & kDisconnectAfterReads) {
            if(_theFlags & kDisconnectAfterWrites) {
                if(_theWriteQueue.count == 0 && _theCurrentWrite == nil) {
                    [self disconnect];
                }
            }
            else
                [self disconnect];
        }
    }
}

/**
 * Call this method in doBytesAvailable instead of CFReadStreamHasBytesAvailable().
 * This method supports pre-buffering properly as well as the kSocketHasBytesAvailable flag.
 **/
- (BOOL)hasBytesAvailable {
    if((_theFlags & kSocketHasBytesAvailable) || (_partialReadBuffer.length > 0)) {
        return YES;
    }
    else
        return CFReadStreamHasBytesAvailable(_theReadStream);
}

/**
 * Call this method in doBytesAvailable instead of CFReadStreamRead().
 * This method support pre-buffering properly.
 **/
- (CFIndex)readIntoBuffer:(void *)buffer maxLength:(NSUInteger)length {
    if(_partialReadBuffer.length > 0) {
        // determine the maximum amount of data to read
        NSUInteger bytesToRead = MIN(length, _partialReadBuffer.length);
        
        // copy the bytes from the partial read buffer
        memcpy(buffer, [_partialReadBuffer bytes], (size_t)bytesToRead);
        
        //remove the copied bytes from the partial read buffer
        [_partialReadBuffer replaceBytesInRange:NSMakeRange(0, bytesToRead) withBytes:NULL length:0];
        
        return (CFIndex)bytesToRead;
    }
    else {
        // unset the has-bytes-available flag
        _theFlags &= ~kSocketHasBytesAvailable;
        
        return CFReadStreamRead(_theReadStream, (UInt8 *)buffer, length);
    }
}

- (void)doBytesAvailable {
    // if data is available on the stream, but there is no read request, then we don't need to process the data yet.
    // also. if there is a read request but no read stream setup, we can't process any data yet.
    if(_theCurrentRead == nil || _theReadStream == NULL)  return;
    
    // Note: this method is not called if _theCurrentRead is an AsyncSpecialPacket (startTLSPacket)
    
    NSUInteger totalBytesRead = 0;
    
    BOOL done = NO;
    BOOL socketError = NO;
    BOOL maxoutError = NO;
    
    while (!done && !socketError && !maxoutError && [self hasBytesAvailable]) {
        BOOL didPreBuffer = NO;
        BOOL didReadFromPreBuffer = NO;
        
        // there are 3 types of read packets;
        /*
         1.read all available data
         2.read a specific length of data
         3.read up to a partucular terminator.
         */
        
        NSUInteger bytesToRead;
        if(_theCurrentRead->_term != nil) {
            // Read type #3 - read up to a terminator
            //
            // If pre-buffering is enabled we'll read a chunk and search for the terminator.
            // If the terminator is found, overflow data will be placed in the partialReadBuffer for the next read.
            //
            // If pre-buffering is disabled we'll be forced to read only a few bytes.
            // Just enough to ensure we don't go past our term or over our max limit.
            //
            // If we already have data pre-buffered, we can read directly from it.
            
            if(_partialReadBuffer.length > 0) {
                didReadFromPreBuffer = YES;
                bytesToRead = [_theCurrentRead readLengthForTermWithPreBuffer:_partialReadBuffer found:&done];
            }
            else {
                if(_theFlags & kEnablePreBuffering) {
                    didPreBuffer = YES;
                    bytesToRead = [_theCurrentRead prebufferReadLengthForTerm];
                }
                else {
                    bytesToRead = [_theCurrentRead readLengthForNonTerm];
                }
            }
        }
        else {
            // read type #1 or #2
            bytesToRead = [_theCurrentRead readLengthForNonTerm];
        }
        
        // Make sure we have enough room in the buffer for our read.
        NSUInteger buffSize = _theCurrentRead->_buffer.length;
        NSUInteger buffSpace = buffSize - _theCurrentRead->_startOffset - _theCurrentRead->_bytesDone;
        
        if(bytesToRead > buffSpace) {
            NSUInteger buffInc = bytesToRead - buffSpace;
            
        [_theCurrentRead->_buffer increaseLengthBy:buffInc];
        }
        
        // read data into packet buffer
        
        void *buffer = [_theCurrentRead->_buffer mutableBytes] + _theCurrentRead->_startOffset;
        void *subBuffer = buffer + _theCurrentRead->_bytesDone;
        
        CFIndex result = [self readIntoBuffer:subBuffer maxLength:bytesToRead];
        
        // check results
        if(result < 0) socketError = YES;
        else {
            CFIndex bytesRead = result;
            
            //Update total amount read for the current read
            _theCurrentRead->_bytesDone += bytesRead;
            
            // is Packet done?
            if(_theCurrentRead->_readLength > 0) {
                // read type #2 - read a specific length of data
                done = (_theCurrentRead->_bytesDone == _theCurrentRead->_readLength);
            }
            else if(_theCurrentRead->_term != nil) {
                // read type #3 - read up to a terminator
                if(didPreBuffer) {
                    // search for the terminating sequence within the big chunk we just read.
                    NSInteger overflow = [_theCurrentRead searchForTermAfterPreBuffering:result];
                    
                    if(overflow > 0) {
                        // Copy excess data into _partialReadBuffer
                        void *overflowBuffer = buffer + _theCurrentRead->_bytesDone - overflow;
                        
                        [_partialReadBuffer appendBytes:overflowBuffer length:overflow];
                        
                        // update the _byteDone variable.
                        _theCurrentRead->_bytesDone -= overflow;
                        
                        // note: the completeCurrentRead method will trim the buffer for us.
                    }
                    
                    done = (overflow >= 0);
                }
                else if(didReadFromPreBuffer) {
                    // our 'done' variable was updated via the readLengthForTermWithPreBuffer:found: method
                }
                else {
                    // search for the terminating sequence at the end of the buffer
                    
                    NSUInteger termlen = _theCurrentRead->_term.length;
                    
                    if(_theCurrentRead->_bytesDone >= termlen) {
                        void *bufferEnd = buffer + (_theCurrentRead->_bytesDone - termlen);
                        
                        const void *seq = [_theCurrentRead->_term bytes];
                        done = (memcmp(bufferEnd, seq, termlen) == 0);
                    }
                }
                
                if(!done && _theCurrentRead->_maxLength > 0) {
                    // we're not done and there's a set maxLength.
                    // have we readched that maxLength yet?
                    if(_theCurrentRead->_bytesDone >= _theCurrentRead->_maxLength) {
                        maxoutError = YES;
                    }
                }
            }
            else {
                // Read type #1 - read all available data
                // we're done when:
                // we reach maxLength (if there is a max)
                // all readable is read (see below)
                
                if(_theCurrentRead->_maxLength > 0) {
                    done = _theCurrentRead->_bytesDone >= _theCurrentRead->_maxLength;
                }
            }
        }
    }
    
    if(_theCurrentRead->_readLength <= 0 && _theCurrentRead->_term == nil) {
        // Read type #1 - read all available data
        
        if(_theCurrentRead->_bytesDone > 0) {
            // Ran out of bytes, so the "read-all-available-data" type packet is done

            done = YES;
        }
    }
    
    if(done) {
        [self completeCurrentRead];
        if(!socketError) [self scheduleDequeueRead];
    }
    else if(totalBytesRead > 0) {
        // we're not done with the readToLength or readToData yet. but we have read in some bytes.
        if([_theDelegate respondsToSelector:@selector(onSocket:didReadPartialDataOfLength:tag:)]) {
            [_theDelegate onSocket:self didReadPartialDataOfLength:totalBytesRead tag:_theCurrentRead->_tag];
        }
    }
    
    if(socketError) {
        CFStreamError err = CFReadStreamGetError(_theReadStream);
        [self closeWithError:[self errorFromCFStreamError:err]];
        return;
    }
    
    if(maxoutError) {
        [self closeWithError:[self getReadMaxedOutError]];
        
        return;
    }
}

// ends current read and calls delegate.
- (void)completeCurrentRead {
    NSAssert(_theCurrentRead, @"Trying to complete current read when there is no current read.");
    
    NSData *result;
    if(_theCurrentRead->_bufferOwner) {
        // We created the buffer on behalf of the user.
        // Trim our buffer to be the proper size.
        [_theCurrentRead->_buffer setLength:_theCurrentRead->_bytesDone];
        
        result = _theCurrentRead->_buffer;
    }
    else {
        // We did NOT create the buffer.
        // The buffer is owned by the caller.
        // Only trim the buffer if we had to increase its size.
        
        if(_theCurrentRead->_buffer.length > _theCurrentRead->_originalBufferLength) {
            NSUInteger readSize = _theCurrentRead->_startOffset + _theCurrentRead->_bytesDone;
            NSUInteger origSize = _theCurrentRead->_originalBufferLength;
            
            NSUInteger buffSize = MAX(readSize, origSize);
            [_theCurrentRead->_buffer setLength:buffSize];
        }
        
        void *buffer = [_theCurrentRead->_buffer mutableBytes] + _theCurrentRead->_startOffset;
        
        result = [NSData dataWithBytesNoCopy:buffer length:_theCurrentRead->_bytesDone freeWhenDone:NO];
    }
    
    if([_theDelegate respondsToSelector:@selector(onSocket:didReadData:withTag:)]) {
        [_theDelegate onSocket:self didReadData:result withTag:_theCurrentRead->_tag];
    }
    
    // Caller may have disconnected in the above delegate method
    if(_theCurrentRead != nil) {
        [self endCurrentRead];
    }
}
//Ends current read.
- (void)endCurrentRead {
    NSAssert(_theCurrentRead, @"Trying to end current read when there is no current read.");
    
    [_theReadTimer invalidate], _theReadTimer = nil;
    _theCurrentRead = nil;
}

- (void)doReadTimeout:(__unused NSTimer *)timer {
#pragma unused(timer)
    NSTimeInterval timeoutExtension = 0.0;
    
    if([_theDelegate respondsToSelector:@selector(onSocket:shouldTimeoutReadWithTag:elapsed:bytesDone:)]) {
        timeoutExtension = [_theDelegate onSocket:self shouldTimeoutReadWithTag:_theCurrentRead->_tag elapsed:_theCurrentRead->_timeout bytesDone:_theCurrentRead->_bytesDone];
    }
    
    if(timeoutExtension > 0.0) {
        _theCurrentRead->_timeout += timeoutExtension;
        
        _theReadTimer = [NSTimer timerWithTimeInterval:timeoutExtension target:self selector:@selector(doReadTimeout:) userInfo:nil repeats:NO];
        [self runLoopAddTimer:_theReadTimer];
    }
    else {
        [self closeWithError:[self getReadTimeoutError]];
    }
}

#pragma mark Writing

- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    if(data == nil || data.length == 0) return;
    if(_theFlags & kForbidReadsWrites) return;
    
    AsyncWritePacket *packet = [[AsyncWritePacket alloc] initWithData:data timeout:timeout tag:tag];
    
    [_theWriteQueue addObject:packet];
    [self scheduleDequeueWrite];
}

- (void)scheduleDequeueWrite {
    if((_theFlags & kDequeueWriteScheduled) == 0) {
        _theFlags |= kDequeueWriteScheduled;
        [self performSelector:@selector(maybeDequeueWrite) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    }
}

/**
 * Conditionally starts a new write.
 *
 * IF there is not another write in process
 * AND there is a write queued
 * AND we have a write stream available
 *
 * This method also handles auto-disconnect post read/write completion.
 **/
- (void)maybeDequeueWrite {
    // unset the flag indicating a call to this method is scheduled
    _theFlags &= ~kDequeueWriteScheduled;
    
    // if we're not currently processing a write and we have an available write stream
    if(_theCurrentWrite==nil && _theWriteStream != NULL) {
        if(_theWriteQueue.count > 0) {
            //dequeue the next object in the write queue
            _theCurrentWrite = [_theWriteQueue objectAtIndex:0];
            [_theWriteQueue removeObjectAtIndex:0];
            
            if([_theCurrentWrite isKindOfClass:[AsyncSpecialPacket class]]) {
                // attempt to start tls
                _theFlags |= kStartingWriteTLS;
                //this method won't do anything unless both kStartingReadTLS and kStartingWriteTLS are set
                [self maybeStartTLS];
            }
            else {
                // start time-out timer
                if(_theCurrentWrite->_timeout >= 0.0) {
                    _theWriteTimer = [NSTimer timerWithTimeInterval:_theCurrentWrite->_timeout target:self selector:@selector(doWriteTimeout:) userInfo:nil repeats:NO];
                    [self runLoopAddTimer:_theWriteTimer];
                }
                
                // immediately write, if possible
                [self doSendBytes];
            }
        }
        else if(_theFlags & kDisconnectAfterWrites) {
            if(_theFlags & kDisconnectAfterReads) {
                if(_theReadQueue.count == 0 && _theCurrentRead == nil) {
                    [self disconnect];
                }
            }
            else {
                [self disconnect];
            }
        }
    }
}

/**
 * Call this method in doSendBytes instead of CFWriteStreamCanAcceptBytes().
 * This method supports the kSocketCanAcceptBytes flag.
 **/
- (BOOL)canAcceptBytes {
    if(_theFlags & kSocketCanAcceptBytes) {
        return YES;
    }
    else
        return CFWriteStreamCanAcceptBytes(_theWriteStream);
}

- (void)doSendBytes {
    if(_theCurrentWrite == nil || _theWriteStream == NULL) {
        return;
    }
    
    // note: This method is not called if _theCurrentWrite is an AsyncSpecialPacket (startTLS packet)
    NSUInteger totalBytesWritten = 0;
    
    BOOL done = NO;
    BOOL error = NO;
    
    while(!done && !error && [self canAcceptBytes]) {
        // figure out what to write
        NSUInteger bytesRemaining = _theCurrentWrite->_buffer.length - _theCurrentWrite->_bytesDone;
        NSUInteger bytesToWrite = (bytesRemaining < WRITE_CHUNKSIZE) ? bytesRemaining : WRITE_CHUNKSIZE;
        
        UInt8 *writestart = (UInt8 *)([_theCurrentWrite->_buffer bytes] + _theCurrentWrite->_bytesDone);
        
        // write
        CFIndex result = CFWriteStreamWrite(_theWriteStream, writestart, bytesToWrite);
        
        // unset the "can accept bytes" flags
        _theFlags &= ~kSocketCanAcceptBytes;
        
        // Check results
        if(result < 0) error = YES;
        else {
            CFIndex bytesWritten = result;
            
            // update total amount read for the current write
            _theCurrentWrite->_bytesDone += bytesWritten;
            
            // update total amount written in this method invacation
            totalBytesWritten += bytesWritten;
            
            // is packet done?
            done = (_theCurrentWrite->_buffer.length == _theCurrentWrite->_bytesDone);
        }
    }
    
    if(done) {
        [self completeCurrentWrite];
        [self scheduleDequeueWrite];
    }
    else if(error) {
        CFStreamError err = CFWriteStreamGetError(_theWriteStream);
        [self closeWithError:[self errorFromCFStreamError:err]];
        return;
    }
    else if(totalBytesWritten > 0) {
        // we're not done with the entire write, but we have written some bytes
        if([_theDelegate respondsToSelector:@selector(onSocket:didWritePartialDataOfLength:tag:)]) {
            [_theDelegate onSocket:self didWritePartialDataOfLength:totalBytesWritten tag:_theCurrentWrite->_tag];
        }
    }
}

// ends current write and class delegate
- (void)completeCurrentWrite {
    NSAssert(_theCurrentWrite, @"Trying to complete current write when there is no current write.");
    
    if([_theDelegate respondsToSelector:@selector(onSocket:didWriteDataWithTag:)]) {
        [_theDelegate onSocket:self didWriteDataWithTag:_theCurrentWrite->_tag];
    }
    
    if(_theCurrentWrite != nil) [self endCurrentWrite]; // caller may have disconnected.
}

// ends current write.
- (void)endCurrentWrite {
    NSAssert(_theCurrentWrite, @"Trying to complete current write when there is no current write.");
    
    [_theWriteTimer invalidate], _theWriteTimer = nil;
    _theCurrentWrite = nil;
}

- (void)doWriteTimeout:(__unused NSTimer *)timer {
#pragma unused(timer)
    
    NSTimeInterval timeoutExtension = 0.0;
    
    if([_theDelegate respondsToSelector:@selector(onSocket:shouldTimeoutWriteWithTag:elapsed:bytesDone:)]) {
        timeoutExtension = [_theDelegate onSocket:self shouldTimeoutWriteWithTag:_theCurrentWrite->_tag elapsed:_theCurrentWrite->_timeout bytesDone:_theCurrentWrite->_bytesDone];
    }
    
    if(timeoutExtension > 0.0) {
        _theCurrentWrite->_timeout += timeoutExtension;
        
        _theWriteTimer = [NSTimer timerWithTimeInterval:timeoutExtension target:self selector:@selector(doWriteTimeout:) userInfo:nil repeats:NO];
        
        [self runLoopAddTimer:_theWriteTimer];
    }
    else [self closeWithError:[self getWriteTimeoutError]];
}

#pragma mark Security
- (void)startTLS:(NSDictionary *)tlsSettings {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    if(tlsSettings == nil) {
        // Passing nil/NULL to CFReadStreamSetProperty will appear to work the same as passing an empty dictionary.
        // but causes problems if we later try to fetch the remote host's certificate.
        //
        // To be exact, it causes the following to return NULL instead of the normal result:
        // CFReadStreamCopyProperty(readStream, kCFStreamPropertySSLPeerCertificates)
        //
        // So we use an empty dictionary instead, which works perfectly.
            tlsSettings = [NSDictionary dictionary];
    }
    
    AsyncSpecialPacket *packet = [[AsyncSpecialPacket alloc] initWithTLSSettings:tlsSettings];
    
    [_theReadQueue addObject:packet];
    [self scheduleDequeueRead];
    
    [_theWriteQueue addObject:packet];
    [self scheduleDequeueWrite];
}

- (void)maybeStartTLS {
    // We can't start TLS until:
    // - All queued reads prior to the user calling StartTLS are complete
    // - All queued writes prior to the user calling StartTLS are complete
    //
    // We'll know these conditions are met when both kStartingReadTLS and kStartingWriteTLS are set
    if((_theFlags & kStartingReadTLS) && (_theFlags & kStartingWriteTLS)) {
        AsyncSpecialPacket *tlsPacket = (AsyncSpecialPacket *)_theCurrentRead;
        
        BOOL didStartOnReadStream = CFReadStreamSetProperty(_theReadStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)tlsPacket->_tlsSettings);
        BOOL didStartOnWriteStream = CFWriteStreamSetProperty(_theWriteStream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)tlsPacket->_tlsSettings);
        
        if(!didStartOnReadStream || !didStartOnWriteStream) {
            [self closeWithError:[self getSocketError]];
        }
    }
}

- (void)onTLSHandshakeSuccessful {
    if((_theFlags & kStartingReadTLS) && (_theFlags & kStartingWriteTLS)) {
        _theFlags &= ~kStartingReadTLS;
        _theFlags &= ~kStartingWriteTLS;
        
        if([_theDelegate respondsToSelector:@selector(onSocketDidSecure:)]) {
            [_theDelegate onSocketDidSecure:self];
        }
        
        [self endCurrentRead];
    }
}

#pragma mark Errors
- (NSError *)getErrnoError {
    NSString *errorMsg = [NSString stringWithUTF8String:strerror(errno)];
    NSDictionary *info = [NSDictionary dictionaryWithObject:errorMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:info];
}

- (NSError *)getSocketError {
    NSString *errMsg = NSLocalizedStringWithDefaultValue(@"AsyncSocketCFSocketError", @"AsyncSocket", [NSBundle mainBundle], @"General CFSocket error", nil);
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncSocketErrorDomain code:AsyncSocketCFSocketError userInfo:info];
}

- (NSError *)getStreamError {
    CFStreamError err;
    if(_theReadStream != NULL) {
        err = CFReadStreamGetError(_theReadStream);
        if(err.error != 0) return [self errorFromCFStreamError:err];
    }
    
    if(_theWriteStream != NULL) {
        err = CFWriteStreamGetError(_theWriteStream);
        if(err.error != 0) return [self errorFromCFStreamError:err];
    }
    
    return nil;
}

//return a standard AsyncSocket abort error.
- (NSError *)getAbortError {
    NSString *errMsg =NSLocalizedStringWithDefaultValue(@"AsyncSocketCanceledError", @"AsyncSocket", [NSBundle mainBundle], @"Connection canceled", nil);
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncSocketErrorDomain code:AsyncSocketCanceledError userInfo:info];
}

- (NSError *)getconnectTimeoutError {
    NSString *errMsg = NSLocalizedStringWithDefaultValue(@"AsyncSocketConnectTimeoutError",
                                                         @"AsyncSocket", [NSBundle mainBundle],
                                                         @"Attempt to connect to host timed out", nil);
    
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncSocketErrorDomain code:AsyncSocketConnectTimeoutError userInfo:info];
}

- (NSError *)getReadMaxedOutError {
    NSString *errMsg = NSLocalizedStringWithDefaultValue(@"AsyncSocketReadMaxedOutError", @"AsyncSocket", [NSBundle mainBundle], @"Read operation reached set maximum length", nil);
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncSocketErrorDomain code:AsyncSocketReadMaxedOutError userInfo:info];
}

- (NSError *)getReadTimeoutError
{
    NSString *errMsg = NSLocalizedStringWithDefaultValue(@"AsyncSocketReadTimeoutError",
                                                         @"AsyncSocket", [NSBundle mainBundle],
                                                         @"Read operation timed out", nil);
    
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncSocketErrorDomain code:AsyncSocketReadTimeoutError userInfo:info];
}

- (NSError *)getWriteTimeoutError
{
    NSString *errMsg = NSLocalizedStringWithDefaultValue(@"AsyncSocketWriteTimeoutError",
                                                         @"AsyncSocket", [NSBundle mainBundle],
                                                         @"Write operation timed out", nil);
    
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncSocketErrorDomain code:AsyncSocketWriteTimeoutError userInfo:info];
}


- (NSError *)errorFromCFStreamError:(CFStreamError)err {
    if(err.domain == 0 && err.error == 0) return nil;
    // cann't use switch; these constatns arn't int literals.
    NSString *domain = @"CFStreamError (unlisted domain)";
    NSString *message = nil;
    
    if(err.domain == kCFStreamErrorDomainPOSIX) {
        domain = NSPOSIXErrorDomain;
    }
    else if(err.domain == kCFStreamErrorDomainMacOSStatus) {
        domain = NSOSStatusErrorDomain;
    }
    else if(err.domain == kCFStreamErrorDomainMach) {
        domain = NSMachErrorDomain;
    }
    else if(err.domain == kCFStreamErrorDomainNetDB) {
        domain = @"kCFStreamErrorDomainNetDB";
        message = [NSString stringWithCString:gai_strerror(err.error) encoding:NSASCIIStringEncoding];
    }
    else if(err.domain == kCFStreamErrorDomainNetServices) {
        domain = @"kCFStreamErrorDomainNetServices";
    }
    else if(err.domain == kCFStreamErrorDomainSOCKS) {
        domain = @"kCFStreamErrorDomainSOCKS";
    }
    else if(err.domain == kCFStreamErrorDomainSystemConfiguration) {
        domain = @"kCFStreamErrorDomainSystemConfiguration";
    }
    else if(err.domain == kCFStreamErrorDomainSSL) {
        domain = @"kCFStreamErrorDomainSSL";
    }
    
    NSDictionary *info = nil;
    if(message != nil) {
        info = [NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    }
    
    return [NSError errorWithDomain:domain code:err.error userInfo:info];
}

#pragma mark Diagnostics
- (BOOL)isDisconnected {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    if(_theNativeSocket4 > 0) return NO;
    if(_theNativeSocket6 > 0) return NO;
    
    if(_theSocket4) return NO;
    if(_theSocket6) return NO;
    
    if(_theReadStream) return NO;
    if(_theWriteStream) return NO;
    
    return YES;
}

- (BOOL)isConnected {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    return [self areStreamsConnected];
}

- (NSString *)connectedHost {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    if(_theSocket4) return [self connectedHostFromCFSocket4:_theSocket4];
    if(_theSocket6) return [self connectedHostFromCFSocket6:_theSocket6];
    
    if(_theNativeSocket4 > 0) {
        return [self connectedHostFromNativeSocket4:_theNativeSocket4];
    }
    if(_theNativeSocket6 > 0) {
        return [self connectedHostFromNativeSocket6:_theNativeSocket6];
    }
    
    return nil;
}

- (UInt16)connectedPort {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    
    return 0;
}

- (NSString *)connectedHostFromNativeSocket4:(CFSocketNativeHandle)theNativeSocket {
    struct sockaddr_in sockaddr4;
    socklen_t sockaddr4len = sizeof(sockaddr4);
    
    if(getpeername(theNativeSocket, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0) {
        return nil;
    }
    
    return [self hostFromAddress4:&sockaddr4];
}

- (NSString *)connectedHostFromNativeSocket6:(CFSocketNativeHandle)theNativeSocket {
    struct sockaddr_in6 sockaddr6;
    socklen_t sockaddr6len = sizeof(sockaddr6);
    
    if(getpeername(theNativeSocket, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0) {
        return nil;
    }
    
    return [self hostFromAddress6:&sockaddr6];
}

- (NSString *)connectedHostFromCFSocket4:(CFSocketRef)theSocket {
    CFDataRef peeraddr;
    NSString *peerstr = nil;
    
    if((peeraddr = CFSocketCopyPeerAddress(theSocket))) {
        struct sockaddr_in *pSockAddr = (struct sockaddr_in *)CFDataGetBytePtr(peeraddr);
        
        peerstr = [self hostFromAddress4:pSockAddr];
        CFRelease(peeraddr);
    }
    
    return peerstr;
}

- (NSString *)connectedHostFromCFSocket6:(CFSocketRef)theSocket {
    CFDataRef peeraddr;
    NSString *peerstr = nil;
    
    if((peeraddr = CFSocketCopyPeerAddress(theSocket))) {
        struct sockaddr_in6 *pSockAddr = (struct sockaddr_in6 *)CFDataGetBytePtr(peeraddr);
        
        peerstr = [self hostFromAddress6:pSockAddr];
        CFRelease(peeraddr);
    }
    
    return peerstr;
}

- (UInt16)localPortFromCFSocket4:(CFSocketRef)theSocket {
    CFDataRef selfaddr;
    UInt16 selfport = 0;
    
    if((selfaddr = CFSocketCopyAddress(theSocket))) {
        struct sockaddr_in *pSockAddr = (struct sockaddr_in *)CFDataGetBytePtr(selfaddr);
        selfport = [self portFromAddress4:pSockAddr];
        CFRelease(selfaddr);
    }
    
    return selfport;
}

- (NSString *)hostFromAddress4:(struct sockaddr_in *)pSockaddr4 {
    char addrBuf[INET_ADDRSTRLEN];
    
    if(inet_ntop(AF_INET, &pSockaddr4->sin_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL) {
        [NSException raise:NSInternalInconsistencyException format:@"Cannot convert IPv4 address to string."];
    }
    
    return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}

- (NSString *)hostFromAddress6:(struct sockaddr_in6 *)pSockaddr6 {
    char addrBuf[INET6_ADDRSTRLEN];
    
    if(inet_ntop(AF_INET6, &pSockaddr6->sin6_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL) {
        [NSException raise:NSInternalInconsistencyException format:@"Cannot convert IPv6 address to string."];
    }
    
    return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}

- (UInt16)portFromAddress4:(struct sockaddr_in *)pSockaddr4 {
    return ntohs(pSockaddr4->sin_port);
}

- (UInt16)portFromAddress6:(struct sockaddr_in6 *)pSockaddr6 {
    return ntohs(pSockaddr6->sin6_port);
}

- (BOOL)areStreamsConnected {
    CFStreamStatus s;
    
    if(_theReadStream != NULL) {
        s = CFReadStreamGetStatus(_theReadStream);
        if(!(s == kCFStreamStatusOpen || s == kCFStreamStatusReading || s == kCFStreamStatusError)) {
            return NO;
        }
    }
    else return NO;
    
    if(_theWriteStream != NULL) {
        s = CFWriteStreamGetStatus(_theWriteStream);
        if(!(s == kCFStreamStatusOpen || s == kCFStreamStatusWriting || s == kCFStreamStatusError)) return NO;
    }
    else return NO;
    
    return YES;
}

- (NSString *)description {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
}

#pragma mark Accessors
- (long)userData {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    return _theUserData;
}

- (void)setUserData:(long)userData {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    _theUserData = userData;
}

- (id<AsyncSocketDelegate>)delegate {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    return _theDelegate;
}

- (void)setDelegate:(id<AsyncSocketDelegate>)delegate {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    _theDelegate = delegate;
}

- (BOOL)canSafelySetDelegate {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    return (_theReadQueue.count == 0 && _theWriteQueue.count == 0 &&
            _theCurrentRead == nil && _theCurrentWrite == nil);
}

- (CFSocketRef)getCFSocket {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    if(_theSocket4) {
        return _theSocket4;
    }
    
    return _theSocket6;
}

- (CFReadStreamRef)getCFReadStream {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    return _theReadStream;
}

- (CFWriteStreamRef)getCFWriteStream {
#if DEBUG_THREAD_SAFETY
    [self checkForThreadSafety];
#endif
    
    return _theWriteStream;
}
@end
