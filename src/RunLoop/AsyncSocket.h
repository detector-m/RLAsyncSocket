//
//  AsyncSocket.h
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AsyncSocketDelegate.h"

@class AsyncReadPacket;
@class AsyncWritePacket;

extern NSString *const AsyncSocketException;
extern NSString *const AsyncSocketErrorDomain;

typedef NS_ENUM(NSInteger, AsyncSocketError) {
    AsyncSocketCFSocketError = kCFSocketError,
    AsyncSocketNoError = 0,
    AsyncSocketCanceledError,
    AsyncSocketConnectTimeoutError,
    AsyncSocketReadMaxedOutError,
    AsyncSocketReadTimeoutError,
    AsyncSocketWriteTimeoutError
};

@interface AsyncSocket : NSObject {
    CFSocketNativeHandle _theNativeSocket4;
    CFSocketNativeHandle _theNativeSocket6;
    
    CFSocketRef _theSocket4;
    CFSocketRef _theSocket6;
    
    CFReadStreamRef _theReadStream;
    CFWriteStreamRef _theWriteStream;
    
    CFRunLoopSourceRef _theSource4;
    CFRunLoopSourceRef _theSource6;
    CFRunLoopRef _theRunLoop;
    CFSocketContext _theContext;
    NSArray *_theRunLoopModes;
    
    NSTimer *_theConnectTimer;
    
    NSMutableArray *_theReadQueue;
    AsyncReadPacket *_theCurrentRead;
    NSTimer *_theReadTimer;
    NSMutableData *_partialReadBuffer;
    
    NSMutableArray *_theWriteQueue;
    AsyncWritePacket *_theCurrentWrite;
    NSTimer *_theWriteTimer;
    
    id<AsyncSocketDelegate> _theDelegate;
    UInt16 _theFlags;
    
    long _theUserData;
}

- (instancetype)initWithDelegate:(id<AsyncSocketDelegate>)delegate;
- (instancetype)initWithDelegate:(id<AsyncSocketDelegate>)delegate userData:(long)userData;

- (NSString *)description;
@end

@interface AsyncSocket (ClassMethods)
// return line separators
+ (NSData *)CRLFData;

@end
