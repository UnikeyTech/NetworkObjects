//
//  ClientStore.h
//  NetworkObjectsClient
//
//  Created by Alsey Coleman Miller on 11/11/13.
//  Copyright (c) 2013 CDA. All rights reserved.
//

#import <Foundation/Foundation.h>
@import CoreData;

@class NOAPI, NOAPIStore, User;

@interface ClientStore : NSObject

+ (ClientStore *)sharedStore;

#pragma mark

@property (readonly) NOAPI *api;

@property (readonly) NOAPIStore *apiStore;

@property (readonly) NSManagedObjectContext *context;

@property (readonly) User *user;

-(void)loginWithCompletion:(void (^)(NSError *error))completionBlock;


@end
