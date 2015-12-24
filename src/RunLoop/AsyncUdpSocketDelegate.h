//
//  AsyncUdpSocketDelegate.h
//  RLAsyncSocket
//
//  Created by Riven on 15/12/24.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AsyncUdpSocket;

@protocol AsyncUdpSocketDelegate <NSObject>
@optional
- (void)onUdpSocket:(AsyncUdpSocket *)sock didSendDataWithTag:(long)tag;

- (void)onUdpSocket:(AsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error;

- (BOOL)onUdpSocket:(AsyncUdpSocket *)sock didReceiveData:(NSData *)data withTag:(long)tag fromHost:(NSString *)host port:(UInt16)port;

- (void)onUdpSocket:(AsyncUdpSocket *)sock didNotReceiveDataWithTag:(long)tag dueToError:(NSError *)error;

- (void)onUdpSocketDidClose:(AsyncUdpSocket *)sock;
@end
