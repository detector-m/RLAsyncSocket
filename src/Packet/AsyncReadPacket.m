//
//  AsyncReadPacket.m
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import "AsyncReadPacket.h"

/**
 * The AsyncReadPacket encompasses the instructions for any given read.
 * The content of a read packet allows the code to determine if we're:
 *  - reading to a certain length
 *  - reading to a certain separator
 *  - or simply reading the first chunk of available data
 **/

#define READALL_CHUNKSIZE	256         // Incremental increase in buffer size
@implementation AsyncReadPacket
- (instancetype)initWithData:(NSMutableData *)d startOffset:(NSUInteger)s maxLength:(NSUInteger)m timeout:(NSTimeInterval)t readLength:(NSUInteger)l terminator:(NSData *)e tag:(long)i {
    if((self = [super init])) {
        if(d) {
            _buffer = d;
            _startOffset = s;
            _bufferOwner = NO;
            _originalBufferLength = d.length;
        }
        else {
            if(l > 0) {
                _buffer = [[NSMutableData alloc] initWithLength:l];
            }
            else _buffer = [[NSMutableData alloc] initWithLength:0];
            
            _startOffset = 0;
            _bufferOwner = YES;
            _originalBufferLength = 0;
        }
        
        _bytesDone = 0;
        _maxLength = m;
        _timeout =t;
        _readLength = l;
        _term = [e copy];
        _tag = i;
    }
    
    return self;
}

/**
 * For read packets without a set terminator, returns the safe length of data that can be read
 * without exceeding the maxLength, or forcing a resize of the buffer if at all possible.
 **/
- (NSUInteger)readLengthForNonTerm {
    NSAssert(_term == nil, @"This method does not apply to term reads");
    
    if(_readLength > 0) {
        // read a specific length of data
        
        return _readLength - _bytesDone;
    }
    else {
        // read all available data
        NSUInteger result = READALL_CHUNKSIZE;
        if(_maxLength > 0) {
            result = MIN(result, (_maxLength - _bytesDone));
        }
        
        if(!_bufferOwner) {
            // we did not create the buffer.
            // it is owned by the caller.
            // avoid resizing the buffer if at all possible.
            if(_buffer.length == _originalBufferLength) {
                NSUInteger buffSize = _buffer.length;
                NSUInteger buffSpace = buffSize - _startOffset - _bytesDone;
                if(buffSpace > 0) {
                    result = MIN(result, buffSpace);
                }
            }
        }
        return result;
    }
}
/**
 * For read packets with a set terminator, returns the safe length of data that can be read
 * without going over a terminator, or the maxLength, or forcing a resize of the buffer if at all possible.
 *
 * It is assumed the terminator has not already been read.
 **/
- (NSUInteger)readLengthForTerm {
    NSAssert(_term != nil, @"This method does not apply to non-term reads");
    // What we're going to do is look for a partial sequence of the terminator at the end of the buffer.
    // If a partial sequence occurs, then we must assume the next bytes to arrive will be the rest of the term,
    // and we can only read that amount.
    // Otherwise, we're safe to read the entire length of the term.
    
    NSUInteger termLength = _term.length;
    
    // Shortcuts
    if(_bytesDone == 0) return termLength;
    if(termLength == 1) return termLength;
    
    // i = index within buffer at which to check data
    //j=length of term to check against
    NSUInteger i, j;
    if(_bytesDone >= termLength) {
        i = _bytesDone - termLength + 1;
        j = termLength - 1;
    }
    else {
        i = 0;
        j = _bytesDone;
    }
    
    NSUInteger result = termLength;
    
    void *buf = [_buffer mutableBytes];
    const void *termBuf = [_term bytes];
    
    while (i<_bytesDone) {
        void *subbuf = buf + _startOffset + i;
        if(memcmp(subbuf, termBuf, j) == 0) {
            result = termLength - j;
            break;
        }
        
        i++;
        j--;
    }
    
    if(_maxLength > 0) {
        result = MIN(result, _maxLength - _bytesDone);
    }
    
    if(!_bufferOwner) {
        if(_buffer.length == _originalBufferLength) {
            NSUInteger buffSize = _buffer.length;
            NSUInteger buffSpace = buffSize - _startOffset - _bytesDone;
            
            if(buffSpace > 0)
                result = MIN(result, buffSpace);
        }
    }
    
    return result;
}

/**
 * For read packets with a set terminator,
 * returns the safe length of data that can be read from the given preBuffer,
 * without going over a terminator or the maxLength.
 *
 * It is assumed the terminator has not already been read.
 **/
- (NSUInteger)readLengthForTermWithPreBuffer:(NSData *)preBuffer found:(BOOL *)foundPtr {
    NSAssert(_term != nil, @"This method does not apply to non-term reads");
    NSAssert(preBuffer.length > 0, @"Invoked with empty pre buffer!");
    
    // We know that the terminator, as a whole, doesn't exist in our own buffer.
    // But it is possible that a portion of it exists in our buffer.
    // So we're going to look for the terminator starting with a portion of our own buffer.
    //
    // Example:
    //
    // term length      = 3 bytes
    // bytesDone        = 5 bytes
    // preBuffer length = 5 bytes
    //
    // If we append the preBuffer to our buffer,
    // it would look like this:
    //
    // ---------------------
    // |B|B|B|B|B|P|P|P|P|P|
    // ---------------------
    //
    // So we start our search here:
    //
    // ---------------------
    // |B|B|B|B|B|P|P|P|P|P|
    // -------^-^-^---------
    //
    // And move forwards...
    //
    // ---------------------
    // |B|B|B|B|B|P|P|P|P|P|
    // ---------^-^-^-------
    //
    // Until we find the terminator or reach the end.
    // 
    // ---------------------
    // |B|B|B|B|B|P|P|P|P|P|
    // ---------------^-^-^-

    BOOL found = NO;
    
    NSUInteger termLength = _term.length;
    NSUInteger preBufferLength = preBuffer.length;
    
    if(_bytesDone + preBufferLength < termLength) {
        // not enough data for a full term sequence yet
        return preBufferLength;
    }
    
    NSUInteger maxPreBufferLength;
    if(_maxLength > 0) {
        maxPreBufferLength = MIN(preBufferLength, (_maxLength - _bytesDone));
        //note: _maxLength >= _termLength
    }
    else {
        maxPreBufferLength = preBufferLength;
    }
    
    Byte seq[termLength];
    const void *termBuf = [_term bytes];
    
    NSUInteger bufLen = MIN(_bytesDone, termLength-1);
    void *buf = [_buffer mutableBytes] + _startOffset + _bytesDone - bufLen;
    
    NSUInteger preLen = termLength - bufLen;
    void *pre = (void *)[preBuffer bytes];

    NSUInteger loopCount = bufLen + maxPreBufferLength - termLength + 1; // Plus one. See example above.
    
    NSUInteger result = preBufferLength;
    
    NSUInteger i;
    for(i=0; i<loopCount; i++) {
        if(bufLen > 0) {
            // combining bytes from buffer and preBuffer
            memcpy(seq, buf, bufLen);
            memcpy(seq+bufLen, pre, preLen);
            
            if(memcmp(seq, termBuf, termLength) == 0) {
                result = preLen;
                found = YES;
                break;
            }
            
            buf++;
            bufLen--;
            preLen++;
        }
        else {
            // comparing directly from prebuffer
            if(memcmp(pre, termBuf, termLength) == 0) {
                NSUInteger preOffset = pre - [preBuffer bytes]; // pointer arithmetic
                
                result = preOffset + termLength;
                found = YES;
                break;
            }
            
            pre++;
        }
    }
    
    // there is no need to avoid resizing the buffer in this particular situation
    
    if(foundPtr) *foundPtr = found;
    
    return result;
}

/**
 * Assuming pre-buffering is enabled, returns the amount of data that can be read
 * without going over the maxLength.
 **/
- (NSUInteger)prebufferReadLengthForTerm {
    NSAssert(_term != nil, @"This method does not apply to non-term reads");
    
    NSUInteger result = READALL_CHUNKSIZE;
    
    if(_maxLength > 0) {
        result = MIN(result, (_maxLength - _bytesDone));
    }
    
    if(!_bufferOwner) {
        if(_buffer.length == _originalBufferLength) {
            NSUInteger buffSize = _buffer.length;
            NSUInteger buffSpace = buffSize - _startOffset - _bytesDone;
            
            if(buffSpace > 0) {
                result = MIN(result, buffSpace);
            }
        }
    }
    
    return result;
}

/**
 * For read packets with a set terminator, scans the packet buffer for the term.
 * It is assumed the terminator had not been fully read prior to the new bytes.
 *
 * If the term is found, the number of excess bytes after the term are returned.
 * If the term is not found, this method will return -1.
 *
 * Note: A return value of zero means the term was found at the very end.
 **/
- (NSUInteger)searchForTermAfterPreBuffering:(NSUInteger)numBytes {
    NSAssert(_term != nil, @"This method does not apply to non-term reads");
    NSAssert(_bytesDone >= numBytes, @"Invoked with invalid numBytes");
    
    // We try to start the search such that the first new byte read matches up with the last byte of the term.
    // We continue searching forward after this until the term no longer fits into the buffer.
    NSUInteger termLength = _term.length;
    const void *termBuffer = [_term bytes];
    
    //Remember: This method is called after the bytesDone variable has been updated.
    NSUInteger prevBytesDone = _bytesDone - numBytes;
    
    NSUInteger i;
    if(prevBytesDone >= termLength) {
        i = prevBytesDone - termLength + 1;
    }
    else i=0;
    
    while((i+termLength) <= _bytesDone) {
        void *subBuffer = [_buffer mutableBytes] + _startOffset + i;
        
        if(memcmp(subBuffer, termBuffer, termLength) == 0) {
            return _bytesDone - (i+termLength);
        }
        
        i++;
    }
    
    return -1;
}
@end
