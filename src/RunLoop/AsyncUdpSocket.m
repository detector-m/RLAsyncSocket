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

#pragma mark Disconnect
- (void)maybeScheduleClose {

}

#pragma mark Sending
- (void)maybeDequeueSend {
    
}

#pragma mark Receiving
- (void)maybeDequeueReceive {

}

#pragma mark CF Callback
/*
    This is the callback we setup for CFSocket.
    This Method does nothing buf forward the call to it's Objective-C counterpart
 */
static void MyCFSocketCallback(CFSocketRef sref, CFSocketCallBackType type, CFDataRef address, const void *pData, void *pInfo) {

}

#pragma mark Utilities
/*
Attempts to convert the given host/port into and IPv4 and/or IPv6 data structure
 The data structure is of type sockaddr_in for IPv4 and sockaddr_in6 for IPv6.
 
 Returns zero on success, or one of the error codes listed in gai_strerror if an error occurs (as per getaddrinfo).
 */
- (int)convertForBindHost:(NSString *)host port:(UInt16)port intoAddress4:(NSData **)address4 address6:(NSData **)address6 {
    if(host == nil || host.length == 0) {
        // Use ANY address
        struct sockaddr_in nativeAddr;
        nativeAddr.sin_family = AF_INET;
        nativeAddr.sin_port = htons(port);
        nativeAddr.sin_addr.s_addr = htonl(INADDR_ANY);
        nativeAddr.sin_len = sizeof(struct sockaddr_in);
        memset(&(nativeAddr.sin_zero), 0, sizeof(nativeAddr.sin_zero));
        
        struct sockaddr_in6 nativeAddr6;
        nativeAddr6.sin6_family = AF_INET6;
        nativeAddr6.sin6_port = htons(port);
        nativeAddr6.sin6_len = sizeof(struct sockaddr_in6);
        nativeAddr6.sin6_flowinfo = 0;
        nativeAddr6.sin6_addr = in6addr_any;
        nativeAddr6.sin6_scope_id = 0;
        
        // Wrap the native address structures for CFSocketSetAddress.
        if(address4) *address4 = [NSData dataWithBytes:&nativeAddr length:sizeof(nativeAddr)];
        if(address6) *address6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
        
        return 0;
    }
    else if([host isEqualToString:@"localhost"] || [host isEqualToString:@"loopback"]) {
        // Note: getaddrinfo("localhost", ...) fails on 10.5.3
        // Use LOOPBACK address
        struct sockaddr_in nativeAddr;
        nativeAddr.sin_len = sizeof(struct sockaddr_in);
        nativeAddr.sin_family = AF_INET;
        nativeAddr.sin_port = htons(port);
        nativeAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        memset(&(nativeAddr.sin_zero), 0, sizeof(nativeAddr.sin_zero));
        
        struct sockaddr_in6 nativeAddr6;
        nativeAddr6.sin6_len = sizeof(struct sockaddr_in6);
        nativeAddr6.sin6_family = AF_INET6;
        nativeAddr6.sin6_port = htons(port);
        nativeAddr6.sin6_flowinfo = 0;
        nativeAddr6.sin6_addr = in6addr_loopback;
        nativeAddr6.sin6_scope_id = 0;
        
        if(address4) *address4 = [NSData dataWithBytes:&nativeAddr length:sizeof(nativeAddr)];
        if(address6) *address6 = [NSData dataWithBytes:&nativeAddr length:sizeof(nativeAddr6)];
        
        return 0;
    }
    else {
        NSString *portStr = [NSString stringWithFormat:@"%hu", port];
        
#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
        @synchronized (getaddrinfoLock)
#endif
        {
            struct addrinfo hints, *res, *res0;
            
            memset(&hints, 0, sizeof(struct addrinfo));
            hints.ai_family = PF_UNSPEC;
            hints.ai_socktype = SOCK_DGRAM;
            hints.ai_protocol = IPPROTO_UDP;
            hints.ai_flags = AI_PASSIVE;
            
            int error = getaddrinfo(host.UTF8String, portStr.UTF8String, &hints, &res0);
            
            if(error) return error;
            
            for(res=res0; res; res=res->ai_next) {
                if(address4 && !*address4 && (res->ai_family == AF_INET)) {
                    // Found IPv4 address
                    // Wrap the native address structures for CFSocketSetAddress.
                    if(address4) *address4 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
                }
                else if(address6 && !*address6 && (res->ai_family == AF_INET6)) {
                    if(address6) *address6 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
                }
            }
            
            freeaddrinfo(res0);
        }
        
        return 0;
    }
}

/*
    Attempts to convert the given host/port into and IPv4 and/or IPv6 data structure.
    The data structure is of type sockaddr_in for IPv4 and sockaddr_in6 for IPv6.
 
    Returns zero on success, or one of the error codes listed in gai_strerror if an error occurs (as per getaddrinfo).
 */
- (int)convertForSendHost:(NSString *)host port:(UInt16)port intoAddress4:(NSData **)address4 address6:(NSData **)address6 {
    if(host == nil || host.length == 0) {
        // we're not binding. so what are we supposed to do with this?
        return EAI_NONAME;
    }
    else if([host isEqualToString:@"localhost"] || [host isEqualToString:@"loopback"]) {
        struct sockaddr_in nativeAddr;
        nativeAddr.sin_len = sizeof(struct sockaddr_in);
        nativeAddr.sin_family = AF_INET;
        nativeAddr.sin_port = htons(port);
        nativeAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        memset(&(nativeAddr.sin_zero), 0, sizeof(nativeAddr.sin_zero));
        
        struct sockaddr_in6 nativeAddr6;
        nativeAddr6.sin6_len = sizeof(struct sockaddr_in6);
        nativeAddr6.sin6_family = AF_INET6;
        nativeAddr6.sin6_port = htons(port);
        nativeAddr6.sin6_flowinfo = 0;
        nativeAddr6.sin6_addr = in6addr_loopback;
        nativeAddr6.sin6_scope_id = 0;
        
        if(address4) *address4 = [NSData dataWithBytes:&nativeAddr length:sizeof(nativeAddr)];
        if(address6) *address6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
        
        return 0;
    }
    else {
        NSString *portStr = [NSString stringWithFormat:@"%hu", port];
        
#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
        @synchronized(getaddrinfoLock)
#endif
        {
            struct addrinfo hints, *res, *res0;
            
            memset(&hints, 0, sizeof(hints));
            hints.ai_family = PF_UNSPEC;
            hints.ai_socktype = SOCK_DGRAM;
            hints.ai_protocol = IPPROTO_UDP;
            
            int error = getaddrinfo(host.UTF8String, portStr.UTF8String, &hints, &res0);

            if(error) return error;
            
            for(res=res0; res; res=res->ai_next) {
                if(address4 && !*address4 && (res->ai_family == AF_INET)) {
                    if(address4) *address4 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
                }
                else if(address6 && !*address6 && (res->ai_family == AF_INET6)) {
                    if(address6) *address6 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
                }
            }
            
            freeaddrinfo(res0);
        }
        
        return 0;
    }
}

- (NSString *)addressHost4:(struct sockaddr_in *)pSockaddr4 {
    char addrBuf[INET_ADDRSTRLEN];
    
    if(inet_ntop(AF_INET, &pSockaddr4->sin_addr, addrBuf, sizeof(addrBuf)) == NULL) {
        [NSException raise:NSInternalInconsistencyException format:@"Cannot convert address to string."];
    }
    
    return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}

- (NSString *)addressHost6:(struct sockaddr_in6 *)pSockaddr6 {
    char addrBuf[INET6_ADDRSTRLEN];
    
    if(inet_ntop(AF_INET6, &pSockaddr6->sin6_addr, addrBuf, sizeof(addrBuf)) == NULL) {
        [NSException raise:NSInternalInconsistencyException format:@"Cannot convert address to string."];
    }
    
    return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}

- (NSString *)addressHost:(struct sockaddr *)pSockaddr {
    if(pSockaddr->sa_family == AF_INET)
        return [self addressHost4:(struct sockaddr_in *)pSockaddr];
    else
        return [self addressHost6:(struct sockaddr_in6 *)pSockaddr];
}

#pragma mark Socket Implementation
/*
    Binds the underlying socket(s) to the given port.
    The socket(s) will be able to receive data on an interface
    
 * On success, return YES.
 *  Otherwise returns NO, and sets errPtr. If you don't care about the error, you can pass nil for errPtr.
 */
- (BOOL)bindToPort:(UInt16)port error:(NSError **)errPtr {
    return [self bindToAddress:nil port:port error:errPtr];
}

/*
    Binds the underlying socket(s) to the given address and port.
    The socket(s) will be able to receive data only on the given interface.
 
    To receive data on any interface, pass nil or "".
    To receive data only on the loopback interface, pass "localhost" or "loopback".
 
 *  On success, return YES.
 *  Otherwise returns NO, and sets errPtr. If you don't care about the error, you can pass nil for errPtr.
 */
- (BOOL)bindToAddress:(NSString *)host port:(UInt16)port error:(NSError **)errPtr {
    if(_theFlages & kDidClose) {
        [NSException raise:AsyncUdpSocketException format:@"The socket is closed."];
    }
    if(_theFlages & kDidBind) {
        [NSException raise:AsyncUdpSocketException format:@"Cannot bind a socket more than once."];
    }
    if(_theFlages & kDidConnect) {
        [NSException raise:AsyncUdpSocketException format:@"Cannot bind after connecting. If needed, bind first, then connect."];
    }
    
    // Convert the given host/port native address tructures for CFSocketSetAddress
    NSData *address4 = nil, *address6 = nil;
    
    int gai_error = [self convertForBindHost:host port:port intoAddress4:&address4 address6:&address6];
    if(gai_error) {
        if(errPtr) {
            NSString *errMsg = [NSString stringWithCString:gai_strerror(gai_error) encoding:NSASCIIStringEncoding];
            NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
            
            *errPtr = [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:gai_error userInfo:info];
        }
        
        return NO;
    }
    
    NSAssert((address4 || address6), @"address4 and address6 are nil");
    
    // Set the SO_REUSEADDR flags
    int reuseOn = 1;
    if(_theSocket4)
        setsockopt(CFSocketGetNative(_theSocket4), SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
    if(_theSocket6)
        setsockopt(CFSocketGetNative(_theSocket6), SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
    
    // bind the sockets
    if(address4) {
        if(_theSocket4) {
            CFSocketError error = CFSocketSetAddress(_theSocket4, (__bridge CFDataRef)address4);
            if(kCFSocketSuccess != error) {
                if(errPtr) *errPtr = [self getSocketError];
                return NO;
            }
            
            if(!address6) {
                // Using IPv4 only
                [self closeSocket6];
            }
        }
        else if(!address6) {
            if(errPtr) *errPtr = [self getIPv4UnavailableError];
            return NO;
        }
    }
    
    if(address6) {
        //Note: the iphone doesnot currently support IPv6
        if(_theSocket6) {
            CFSocketError error = CFSocketSetAddress(_theSocket6, (__bridge CFDataRef)address6);
            if(error != kCFSocketSuccess) {
                if(errPtr) *errPtr = [self getSocketError];
                return NO;
            }
            
            if(!address4) [self closeSocket4];
        }
        else if(!address4) {
            if(errPtr) *errPtr = [self getIPv6UnavailableError];
            return NO;
        }
    }
    
    _theFlages |= kDidBind;
    return YES;
}

/*
    Connects the underlying UDP socket to the given host and port.
    If an IPv4 address is resolved, the IPv4 socket is connected, and the IPv6 is invalidated and released.
    If an IPv6 address is resolved, the IPv6 socket is connected, and the IPv4 socket is invalidated and released.
 
 *  On success, return YES.
 *  Otherwise returns NO, and sets errPtr. If you don't care about the error, you can pass nil for errPtr.
 */
- (BOOL)connectToHost:(NSString *)host onPort:(UInt16)port error:(NSError **)errPtr {
    if(_theFlages & kDidClose) {
        [NSException raise:AsyncUdpSocketException format:@"The socket is closed."];
    }
    if(_theFlages & kDidConnect) {
        [NSException raise:AsyncUdpSocketException format:@"Cannot connect a socket more than once."];
    }
    
    // Convert the given host/port native address structures for CFSocketSetAddress
    NSData *address4 = nil, *address6 = nil;
    
    int error = [self convertForSendHost:host port:port intoAddress4:&address4 address6:&address6];
    if(error) {
        if(errPtr) {
            NSString *errMsg = [NSString stringWithCString:gai_strerror(errno) encoding:NSASCIIStringEncoding];
            NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
            
            *errPtr = [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:error userInfo:info];
        }
        
        return NO;
    }
    
    NSAssert((address4 || address6), @"address4 and address6 are nil");

    //We only want to connect via a single interface.
    //IPv4 is currently preferred, but this may change in the future.
    CFSocketError sockErr;
    if(address4) {
        if(_theSocket4) {
            sockErr = CFSocketConnectToAddress(_theSocket4, (__bridge CFDataRef)address4, (CFTimeInterval)0.0);
            if(sockErr != kCFSocketSuccess) {
                if(errPtr) *errPtr = [self getSocketError];
                return NO;
            }
            
            _theFlages |= kDidConnect;
            
            // We're connected to an IPv4 address, so no need for the IPv6 socket
            [self closeSocket6];
            return YES;
        }
        else if(!address6) {
            if(errPtr) *errPtr = [self getIPv4UnavailableError];
            return NO;
        }
    }
    
    if(address6) {
        if(_theSocket6) {
            sockErr = CFSocketConnectToAddress(_theSocket6, (__bridge CFDataRef)address6, (CFTimeInterval)0.0);
            if(kCFSocketSuccess != sockErr) {
                if(errPtr) *errPtr = [self getSocketError];
                return NO;
            }
            
            _theFlages |= kDidConnect;
            
            [self closeSocket4];
            return YES;
        }
        else {
            if(errPtr) *errPtr = [self getIPv6UnavailableError];
            return NO;
        }
    }
    
    //It should not be possible to get to this point because either address4 or address6 was non-nil.
    if(errPtr) *errPtr = nil;
    return NO;
}

/*
    Connects the underlying UDP socket to the remote address. If the address is an IPv4 address, the IPv4 socket is connected, and the IPv6 socket is invalidated and released.
 
    If the address is an IPv6 address, the IPv6 socket is connected, and the IPv4 socket is invalidated and released.
 
    The address is a native address structure, as may be returned from API's such as Bonjour.
    An address may be created manually by simply wrapping a sockaddr_in or sockaddr_in6 in an NSData object.
 
 *  On success, returns YES.
 *  Otherwise returns NO, and sets errPtr. If you don't care about the error, you can pass nil for errPtr.
 */
- (BOOL)connectToAddress:(NSData *)remoteAddr error:(NSError **)errPtr {
    if(_theFlages & kDidClose) {
        [NSException raise:AsyncUdpSocketException format:@"The socket is closed."];
    }
    if(_theFlages & kDidConnect)
        [NSException raise:AsyncUdpSocketException format:@"Can't connect a socket more than once."];
    
    CFSocketError sockErr;
    
    // Is remoteAddr an IPv4 address?
    if(remoteAddr.length == sizeof(struct sockaddr_in)) {
        if(_theSocket4) {
            sockErr = CFSocketConnectToAddress(_theSocket4, (__bridge CFDataRef)remoteAddr, (CFTimeInterval)0.0);
            if(sockErr != kCFSocketError) {
                if(errPtr) *errPtr = [self getSocketError];
                return NO;
            }
            
            _theFlages |= kDidConnect;
            
            //We're connected to an IPv4 address, so no need for the IPv6 socket
            [self closeSocket6];
            
            return YES;
        }
        else {
            if(errPtr) *errPtr = [self getIPv4UnavailableError];
            return NO;
        }
    }
    
    // Is remoteAddr an IPv6 address?
    if(remoteAddr.length == sizeof(struct sockaddr_in6)) {
        if(_theSocket6) {
            sockErr = CFSocketConnectToAddress(_theSocket6, (__bridge CFDataRef)remoteAddr, (CFTimeInterval)0.0);
            if(sockErr != kCFSocketSuccess) {
                if(errPtr) *errPtr = [self getSocketError];
                return NO;
            }
            _theFlages |= kDidConnect;
            
            [self closeSocket4];
            
            return YES;
        }
        else {
            if(errPtr) *errPtr = [self getIPv6UnavailableError];
            return NO;
        }
    }
    
    // The remoteAddr was invalid
    if(errPtr) {
        NSString *errMsg = @"remoteAddr parameter is not a valid address";
        
        NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
        
        *errPtr = [NSError errorWithDomain:AsyncUdpSocketErrorDomain code:AsyncUdpSocketBadParameter userInfo:info];
    }
    
    return NO;
}

#pragma mark Disconnect Implementation
- (void)emptyQueues {
//    if(_theCurrentSend) [self ]
}

- (void)closeSocket4 {
    if(_theSocket4 != NULL) {
        CFSocketInvalidate(_theSocket4);
        CFRelease(_theSocket4), _theSocket4 = NULL;
    }
    
    if(_theSource4 != NULL) {
        [self runLoopRemoveSource:_theSource4];
        CFRelease(_theSource4), _theSource4 = NULL;
    }
}

- (void)closeSocket6 {
    if(_theSocket6) {
        CFSocketInvalidate(_theSocket6);
        CFRelease(_theSocket6), _theSocket6 = NULL;
    }
    
    if(_theSource6) {
        [self runLoopRemoveSource:_theSource6];
        CFRelease(_theSource6), _theSource6 = NULL;
    }
}



#pragma mark Errors
//Returns a standard error object for the current errno value.
//Errno is used for low-level BSD socket errors.
- (NSError *)getErrnoError {
    NSString *errorMsg = [NSString stringWithUTF8String:strerror(errno)];
    NSDictionary *info = [NSDictionary dictionaryWithObject:errorMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:info];
}

/*Returns a standard error message for a CFSocket error.
   Unfortunately, CFSocket offers no feedback on feedback on its errors.
 */
- (NSError *)getSocketError {
    NSString *errMsg = @"Genneral CFSocket error";
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncUdpSocketErrorDomain code:AsyncUdpSocketCFSocketError userInfo:info];
}

- (NSError *)getIPv4UnavailableError {
    NSString *errMsg = @"IPv4 is unavailable due to binding/connectiong using IPv6 only";
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncUdpSocketErrorDomain code:AsyncUdpSocketIPv4Unavailable userInfo:info];
}

- (NSError *)getIPv6UnavailableError {
    NSString *errMsg = @"IPv6 is unavailable due to bing/connecting using IPv4 or is not supported on this platform";
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncUdpSocketErrorDomain code:AsyncUdpSocketIPv6Unavailable userInfo:info];
}

- (NSError *)getSendTimeoutError {
    NSString *errMsg = @"Send operation timed out";
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncUdpSocketErrorDomain code:AsyncUdpSocketSendTimeoutError userInfo:info];
}

- (NSError *)getReceiveTimeoutError {
    NSString *errMsg = @"Receive operation timed out";
    NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
    
    return [NSError errorWithDomain:AsyncUdpSocketErrorDomain code:AsyncUdpSocketReceiveTimeoutError userInfo:info];
}

#pragma mark Configuration
- (UInt32)maxReceiveBufferSize {
    return _maxReceiveBufferSize;
}

- (void)setMaxReceiveBufferSize:(UInt32)max {
    _maxReceiveBufferSize = max;
}

// See the header file for a full explanation of this method
- (BOOL)moveToRunLoop:(NSRunLoop *)runLoop {
    NSAssert((_theRunLoop==NULL) || (_theRunLoop == CFRunLoopGetCurrent()), @"moveToRunLoop must be called from within the current RunLoop!");
    
    if(runLoop == nil) return NO;
    if(_theRunLoop == [runLoop getCFRunLoop]) return YES;
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _theFlages &= ~kDequeueSendScheduled;
    _theFlages &= ~kDequeueReceiveScheduled;
    
    if(_theSource4) [self runLoopRemoveSource:_theSource4];
    if(_theSource6) [self runLoopRemoveSource:_theSource6];
    
    if(_theSendTimer) [self runLoopRemoveTimer:_theSendTimer];
    if(_theReceiveTimer) [self runLoopRemoveTimer:_theReceiveTimer];
    
    _theRunLoop = [runLoop getCFRunLoop];
    
    if(_theSendTimer) [self runLoopAddTimer:_theSendTimer];
    if(_theReceiveTimer) [self runLoopAddTimer:_theReceiveTimer];
    
    if(_theSource4) [self runLoopAddSource:_theSource4];
    if(_theSource6) [self runLoopAddSource:_theSource6];
    
    [runLoop performSelector:@selector(maybeDequeueSend) target:self argument:nil order:0 modes:_theRunLoopModes];
    [runLoop performSelector:@selector(maybeDequeueReceive) target:self argument:nil order:0 modes:_theRunLoopModes];
    [runLoop performSelector:@selector(maybeScheduleClose) target:self argument:nil order:0 modes:_theRunLoopModes];
    
    return YES;
}

/*
 See the header file for a full explanation of this method.
 */

- (BOOL)setRunLoopModels:(NSArray *)runLoopModes {
    NSAssert((_theRunLoop == NULL) || (_theRunLoop == CFRunLoopGetCurrent()), @"setRunLoopModes must be called from within the current RunLoop!");
    
    if([runLoopModes count] == 0) return NO;
    if([_theRunLoopModes isEqualToArray:runLoopModes]) return YES;
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _theFlages &= ~kDequeueSendScheduled;
    _theFlages &= ~kDequeueReceiveScheduled;
    
    if(_theSource4) [self runLoopRemoveSource:_theSource4];
    if(_theSource6) [self runLoopRemoveSource:_theSource6];
    
    if(_theSendTimer) [self runLoopRemoveTimer:_theSendTimer];
    if(_theReceiveTimer) [self runLoopRemoveTimer:_theReceiveTimer];
    
    _theRunLoopModes = [runLoopModes copy];
    
    if(_theSendTimer) [self runLoopAddTimer:_theSendTimer];
    if(_theReceiveTimer) [self runLoopAddTimer:_theReceiveTimer];
    
    if(_theSource4) [self runLoopAddSource:_theSource4];
    if(_theSource6) [self runLoopAddSource:_theSource6];
    
    [self performSelector:@selector(maybeDequeueSend) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    [self performSelector:@selector(maybeDequeueReceive) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    [self performSelector:@selector(maybeScheduleClose) withObject:nil afterDelay:0 inModes:_theRunLoopModes];
    
    return YES;
}

- (NSArray *)runLoopModes {
    return [_theRunLoopModes copy];
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
