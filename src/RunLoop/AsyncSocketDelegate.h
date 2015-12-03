//
//  AsyncSocketDelegate.h
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>
@class AsyncSocket;

@protocol AsyncSocketDelegate <NSObject>
@optional
- (void)onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)err;
- (void)onSocketDidDisconnect:(AsyncSocket *)sock;

- (void)onSocket:(AsyncSocket *)sock didAcceptNewSocket:(AsyncSocket *)newSocket;

- (NSRunLoop *)onSocket:(AsyncSocket *)sock wantsRunLoopForNewSocket:(AsyncSocket *)newSocket;

- (BOOL)onSocketWillConnect:(AsyncSocket *)sock;
- (void)onSocket:(AsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port;

- (void)onSocket:(AsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag;
- (void)onSocket:(AsyncSocket *)sock didReadPartialDataOfLength:(NSUInteger)partialLength tag:(long)tag;

- (void)onSocket:(AsyncSocket *)sock didWriteDataWithTag:(long)tag;
- (void)onSocket:(AsyncSocket *)sock didWritePartialDataOfLength:(NSUInteger)partialLength tag:(long)tag;

- (NSTimeInterval)onSocket:(AsyncSocket *)sock shouldTimeoutReadWithTag:(long)tag elapsed:(NSTimeInterval)elapsed bytesDone:(NSUInteger)length;

- (NSTimeInterval)onSocket:(AsyncSocket *)sock shouldTimeoutWriteWithTag:(long)tag elapsed:(NSTimeInterval)elapsed bytesDone:(NSUInteger)length;

- (void)onSocketDidSecure:(AsyncSocket *)sock;
@end
