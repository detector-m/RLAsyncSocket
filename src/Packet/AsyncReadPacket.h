//
//  AsyncReadPacket.h
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>

/**
 * The AsyncReadPacket encompasses the instructions for any given read.
 * The content of a read packet allows the code to determine if we're:
 *  - reading to a certain length
 *  - reading to a certain separator
 *  - or simply reading the first chunk of available data
 **/
@interface AsyncReadPacket : NSObject {
@public
    NSMutableData *_buffer;
    NSUInteger _startOffset;
    NSUInteger _bytesDone;
    NSUInteger _maxLength;
    NSTimeInterval _timeout;
    NSUInteger _readLength;
    NSData *_term;
    BOOL _bufferOwner;
    NSUInteger _originalBufferLength;
    long _tag;
}

- (instancetype)initWithData:(NSMutableData *)d
                 startOffset:(NSUInteger)s
                   maxLength:(NSUInteger)m
                     timeout:(NSTimeInterval)t
                  readLength:(NSUInteger)l
                  terminator:(NSData *)e
                         tag:(long)i;
- (NSUInteger)readLengthForNonTerm;
- (NSUInteger)readLengthForTerm;
- (NSUInteger)readLengthForTermWithPreBuffer:(NSData *)preBuffer found:(BOOL *)foundPtr;

- (NSUInteger)prebufferReadLengthForTerm;
- (NSUInteger)searchForTermAfterPreBuffering:(NSUInteger)numBytes;
@end
