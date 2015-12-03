//
//  AsyncSpecialPacket.h
//  RLAsyncSocket
//
//  Created by Riven on 15-12-2.
//  Copyright (c) 2015年 Riven. All rights reserved.
//

#import <Foundation/Foundation.h>


/**
 * The AsyncSpecialPacket encompasses special instructions for interruptions in the read/write queues.
 * This class my be altered to support more than just TLS in the future.
 **/
@interface AsyncSpecialPacket : NSObject {
@public
    NSDictionary *tlsSettings;
}

@end
