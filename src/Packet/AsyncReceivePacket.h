//
//  AsyncReceivePacekt.h
//  RLAsyncSocket
//
//  Created by Riven on 15/12/24.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AsyncReceivePacket : NSObject {
@public
    NSData *_buffer;
    NSString *_host;
    UInt16 _port;
    NSTimeInterval _timeout;
    long _tag;
}

- (instancetype)initWithTimeout:(NSTimeInterval)t tag:(long)i;
@end
