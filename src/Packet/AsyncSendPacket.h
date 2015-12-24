//
//  AsyncSendPacket.h
//  RLAsyncSocket
//
//  Created by Riven on 15/12/24.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AsyncSendPacket : NSObject {
@public
    NSData *_buffer;
    NSData *_address;
    NSTimeInterval _timeout;
    long _tag;
}

- (id)initWithData:(NSData *)d address:(NSData *)a timeout:(NSTimeInterval)t tag:(long)i;
@end
