//
//  AsyncUdpSocket.h
//  RLAsyncSocket
//
//  Created by Riven on 15/12/24.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol AsyncUdpSocketDelegate;

@class AsyncSendPacket;
@class AsyncReceivePacket;

extern NSString *const AsyncUdpSocketException;
extern NSString *const AsyncUdpSocketErrorDomain;

typedef NS_ENUM(NSInteger, AsyncUdpSocketError)  {
    AsyncUdpSocketCFSocketError = kCFSocketError, // from CFSocketError enum
    AsyncUdpSocketNoError = 0, // never used
    AsyncUdpSocketBadParameter, //used if given a bad parameter (such as an improper address)
    AsyncUdpSocketIPv4Unavailable, //used if you bind/connect using IPv6 only
    AsyncUdpSocketIPv6Unavailable, //used if you bind/connect using IPv4 only
    AsyncUdpSocketSendTimeoutError,
    AsyncUdpSocketReceiveTimeoutError,
};

@interface AsyncUdpSocket : NSObject {
    CFSocketRef _theSocket4;
    CFSocketRef _theSocket6;
    
    CFRunLoopSourceRef _theSource4; // for _theSocket4
    CFRunLoopSourceRef _theSource6; // for _theSocket6
    CFRunLoopRef _theRunLoop;
    CFSocketContext _theContext;
    NSArray *_theRunLoopModes;
    
    NSMutableArray *_theSendQueue;
    AsyncSendPacket *_theCurrentSend;
    NSTimer *_theSendTimer;
    
    NSMutableArray *_theReceiveQueue;
    AsyncReceivePacket *_theCurrentReceive;
    NSTimer *_theReceiveTimer;
    
    id<AsyncUdpSocketDelegate>_theDelegate;
    UInt16 _theFlages;
    
    long _theUserData;
    
    NSString *_cachedLocalHost;
    UInt16 _cachedLocalPort;
    
    NSString *_cachedConnectedHost;
    UInt16 _cachedConnectedPort;
    
    UInt32 _maxReceiveBufferSize;
}

//create new instances of AsyncUdpSocket
- (instancetype)init;
- (instancetype)initWithDelegate:(id<AsyncUdpSocketDelegate>)delegate;
- (instancetype)initWithDelegate:(id<AsyncUdpSocketDelegate>)delegate userData:(long)userData;

- (instancetype)initIPv4;
- (instancetype)initIPv6;

@end
