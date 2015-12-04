//
//  AsyncSpecialPacket.m
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import "AsyncSpecialPacket.h"

/**
 * The AsyncSpecialPacket encompasses special instructions for interruptions in the read/write queues.
 * This class my be altered to support more than just TLS in the future.
 **/
@implementation AsyncSpecialPacket
- (instancetype)initWithTLSSettings:(NSDictionary *)settings {
    if((self = [super init])) {
        _tlsSettings = [settings copy];
    }
    
    return self;
}
@end
