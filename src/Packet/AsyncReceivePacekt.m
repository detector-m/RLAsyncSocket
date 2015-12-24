//
//  AsyncReceivePacekt.m
//  RLAsyncSocket
//
//  Created by Riven on 15/12/24.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import "AsyncReceivePacekt.h"

@implementation AsyncReceivePacekt
- (instancetype)initWithTimeout:(NSTimeInterval)t tag:(long)i {
    if(self = [super init]) {
        _buffer = nil;
        _host = nil;
        _port = 0;
        
        _timeout = t;
        _tag = i;
    }
    
    return self;
}
@end
