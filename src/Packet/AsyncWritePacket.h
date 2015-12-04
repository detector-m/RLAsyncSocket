//
//  AsyncWritePacket.h
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>

/**
 * The AsyncWritePacket encompasses the instructions for any given write.
 **/
@interface AsyncWritePacket : NSObject {
@public
    NSData *_buffer;
    NSUInteger _bytesDone;
    NSTimeInterval _timeout;
    long _tag;
}

- (instancetype)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i;
@end
