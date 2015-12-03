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

#pragma mark - thread-safety
- (void)checkForThreadSafety {
    if(_theRunLoop && (_theRunLoop != CFRunLoopGetCurrent())) {
        [NSException raise:AsyncSocketException format:@"Attempting to access AsyncSocket instance from incorrect thread."];
    }
}

#pragma mark - progress
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

#pragma mark - run loop
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

#pragma makr - configuration
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
#pragma mark Socekt Implementation

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

- (BOOL)openStreamsAndReturnError:(NSError **)errPtr {
    return YES;
}
#pragma mark Disconnect Implementation
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



#pragma mark errors
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
