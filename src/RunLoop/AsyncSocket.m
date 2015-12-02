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

- (void)close {

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
