//
//  AsyncSendPacket.m
//  RLAsyncSocket
//
//  Created by Riven on 15/12/24.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import "AsyncSendPacket.h"

@implementation AsyncSendPacket
- (instancetype)initWithData:(NSData *)d address:(NSData *)a timeout:(NSTimeInterval)t tag:(long)i {
    if(self = [super init]) {
        _buffer = d;
        _address = a;
        _timeout = t;
        _tag = t;
    }
    
    return self;
}
@end
