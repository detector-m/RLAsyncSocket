//
//  AsyncWritePacket.m
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import "AsyncWritePacket.h"

/**
 * The AsyncWritePacket encompasses the instructions for any given write.
 **/
@implementation AsyncWritePacket
- (instancetype)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i {
    if((self = [super init])) {
        _buffer = d;
        _timeout = t;
        _tag = i;
        _bytesDone = 0;
    }
    
    return self;
}
@end
