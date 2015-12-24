//
//  AsyncUdpSocket.m
//  RLAsyncSocket
//
//  Created by Riven on 15/12/24.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag(or convert project to ARC).
#endif

#import "AsyncUdpSocket.h"
#import <TargetConditionals.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/ioctl.h>
#import <net/if.h>
#import <netdb.h>

#if TARGET_OS_IPHONE
#import <CFNetwork/CFNetwork.h>
#endif

#import "AsyncUdpSocketDelegate.h"
#import "AsyncSendPacket.h"
#import "AsyncReceivePacekt.h"

#define SENDQUEUE_CAPACITY 5
#define RECEIVEQUEUE_CAPACITY 5

#define DEFAULT_MAX_RECEIVE_BUFFER_SIZE 9216

NSString *const AsyncUdpSocketException = @"AsyncUdpSocketException";
NSString *const AsyncUdpSocketErrorDomain = @"AsyncUdpSocketErrorDomain";

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
// Mutex lock used by all instances of AsyncUdpSocket, to protect getaddrinfo.
// Prior to Mac OS X 10.5 this method was not thread-safe.
static NSString *getaddrinfoLock = @"lock";
#endif

enum AsyncUdpSocketFlags {
    kDidBind = 1<<0, // if set , bind has been called.
    kDidConnect = 1<<1, // if set, connect has been called.
    kSock4CanAcceptBytes = 1 << 2, // if set, we know socket 4 can accept bytes , if unset , it's unknown
    kSock6CanAcceptBytes = 1 << 3, // if set, we know socket 6 can accept bytes, if unset, it's unknown
    kSock4HasBytesAvailable = 1 << 4, // if set, we know socket4 has bytes available. If unset, it's unknow.
    kSock6HasBytesAvailable = 1 << 5,
    
    kForbidSendReceive = 1 << 6, // If set, no new send or receive operations are allowed to be queued.
    kCloseAfterSends = 1 << 7, // If set, close as soon as no more sends are queued.
    kCloseAfterReceives = 1 << 8, // If set, close as soon as no more recieves ar queued.
    kDidClose = 1 << 9, // If set, the socket has been closed, and should not be used anymore.
    
    kDequeueSendScheduled = 1<<10, //If set, a maybeDequeueSend operation is already scheduled.
    kDequeueReceiveScheduled = 1 << 11, //If set, a maybeDequeueReceive operation is already scheduled.
    kFlipFlop = 1 << 12, // Used to alternate between Ipv4 and IPv6 sockets.
};


@implementation AsyncUdpSocket
#pragma mark Life Cycle
//- (void)dealloc {
//    [self close];
//    [NSObject cancelPreviousPerformRequestsWithTarget:_theDelegate selector:@selector(on) object:<#(id)#>]
//}

- (instancetype)initWithDelegate:(id<AsyncUdpSocketDelegate>)delegate userData:(long)userData enableIPv4:(BOOL)enableIPv4 enableIPv6:(BOOL)enableIPv6 {
    if(self = [super init]) {
        _theFlages = 0;
        _theDelegate = delegate;
        _theUserData = userData;
        _maxReceiveBufferSize = DEFAULT_MAX_RECEIVE_BUFFER_SIZE;
        
        _theSendQueue = [[NSMutableArray alloc] initWithCapacity:SENDQUEUE_CAPACITY];
        _theCurrentSend = nil;
        _theSendTimer = nil;
        
        _theReceiveQueue = [[NSMutableArray alloc] initWithCapacity:RECEIVEQUEUE_CAPACITY];
        _theCurrentReceive = nil;
        _theReceiveTimer = nil;
        
        // Socket context
        _theContext.version = 0;
        _theContext.info = (__bridge void *)self;
        _theContext.retain = nil;
        _theContext.release = nil;
        _theContext.copyDescription = nil;
        
        // create the sockets
        _theSocket4 = NULL;
        _theSocket6 = NULL;
        
        if(enableIPv4) {
            _theSocket4 = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_DGRAM, IPPROTO_UDP, kCFSocketReadCallBack | kCFSocketWriteCallBack, (CFSocketCallBack)&MyCFSocketCallback, &_theContext);
        }
        if(enableIPv6) {
            _theSocket6 = CFSocketCreate(kCFAllocatorDefault, PF_INET6, SOCK_DGRAM, IPPROTO_UDP, kCFSocketReadCallBack | kCFSocketWriteCallBack, (CFSocketCallBack)&MyCFSocketCallback, &_theContext);
        }
        
        // Disable continuous callbacks for read and write.
        // If we don't do this, this socket(s) will just sit there firing read callbacks
        // at us hundreds of times a second if we don't immediately read the available data.
        if(_theSocket4) {
            CFSocketSetSocketFlags(_theSocket4, kCFSocketCloseOnInvalidate);
        }
        if(_theSocket6)
            CFSocketSetSocketFlags(_theSocket6, kCFSocketCloseOnInvalidate);
        
        /*Prevent sendto calls from sending SIGPIPE signal when socket has been shutdown for writing.
            sendto will instead let us handle errors as usual by 
            returning -1.
         */
        int noSigPipe = 1;
        if(_theSocket4)
            setsockopt(CFSocketGetNative(_theSocket4), SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        if(_theSocket6)
            setsockopt(CFSocketGetNative(_theSocket6), SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        
        // get the CFRunLoop to which the socket should be attached.
        _theRunLoop = CFRunLoopGetCurrent();
        
        // Set default run loop modes
        _theRunLoopModes = [NSArray arrayWithObject:NSDefaultRunLoopMode];
        
        // Attach the sockets to the run loop
        if(_theSocket4) {
            _theSource4 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _theSocket4, 0);
            [self runLoopAddSource:_theSource4];
        }
        if(_theSocket6) {
            _theSource6 = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _theSocket6, 0);
            [self runLoopAddSource:_theSource6];
        }
        
        _cachedLocalPort = 0;
        _cachedConnectedPort = 0;
    }
    
    return self;
}

- (instancetype)init {
    return [self initWithDelegate:nil userData:0 enableIPv4:YES enableIPv6:YES];
}

- (instancetype)initWithDelegate:(id<AsyncUdpSocketDelegate>)delegate {
    return [self initWithDelegate:delegate userData:0 enableIPv4:YES enableIPv6:YES];
}

- (instancetype)initWithDelegate:(id<AsyncUdpSocketDelegate>)delegate userData:(long)userData {
    return [self initWithDelegate:delegate userData:userData enableIPv4:YES enableIPv6:YES];
}

- (instancetype)initIPv4 {
    return [self initWithDelegate:nil userData:0 enableIPv4:YES enableIPv6:NO];
}

- (instancetype)initIPv6 {
    return [self initWithDelegate:nil userData:0 enableIPv4:NO enableIPv6:YES];
}

#pragma mark Run Loop
- (void)runLoopAddSource:(CFRunLoopSourceRef)source {
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFRunLoopAddSource(_theRunLoop, source, (__bridge  CFStringRef)runLoopMode);
    }
}

- (void)runLoopRemoveSource:(CFRunLoopSourceRef)source {
    for(NSString *runLoopMode in _theRunLoopModes) {
        CFRunLoopRemoveSource(_theRunLoop, source, (__bridge CFStringRef)runLoopMode);
    }
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

#pragma mark CF Callback
/*
    This is the callback we setup for CFSocket.
    This Method does nothing buf forward the call to it's Objective-C counterpart
 */
static void MyCFSocketCallback(CFSocketRef sref, CFSocketCallBackType type, CFDataRef address, const void *pData, void *pInfo) {

}

#pragma mark Accessors
- (id<AsyncUdpSocketDelegate>)delegate {
    return _theDelegate;
}

- (void)setDelegate:(id<AsyncUdpSocketDelegate>)delegate {
    _theDelegate = delegate;
}

- (long)useData {
    return _theUserData;
}

- (void)setUserData:(long)userData {
    _theUserData = userData;
}


@end
