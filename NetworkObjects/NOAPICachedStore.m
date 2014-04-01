//
//  NOAPICachedStore.m
//  NetworkObjects
//
//  Created by Alsey Coleman Miller on 11/16/13.
//  Copyright (c) 2013 CDA. All rights reserved.
//

#import "NOAPICachedStore.h"
#import "NSManagedObject+CoreDataJSONCompatibility.h"
#import "NetworkObjectsConstants.h"

NSString *const NOAPICachedStoreDatesCachedOption = @"NOAPICachedStoreDatesCachedOption";

@interface NOAPICachedStore (Cache)

-(NSManagedObject<NOResourceKeysProtocol> *)resource:(NSString *)resourceName
                                              withID:(NSUInteger)resourceID;

-(NSManagedObject<NOResourceKeysProtocol> *)setJSONObject:(NSDictionary *)jsonObject
                                              forResource:(NSString *)resourceName
                                                   withID:(NSUInteger)resourceID;

@end

@interface NOAPICachedStore (DateCached)

-(void)cachedResource:(NSString *)resourceName
       withResourceID:(NSUInteger)resourceID;

-(void)setupDateCached;

@end

@interface NSEntityDescription (Convert)

-(NSDictionary *)jsonObjectFromCoreDataValues:(NSDictionary *)values;

@end

@interface NOAPICachedStore ()

@property NSDictionary *datesCached;

@end

@implementation NOAPICachedStore

#pragma mark - Initialization

-(instancetype)initWithOptions:(NSDictionary *)options
{
    self = [super initWithOptions:options];
    
    if (self) {
        
        self.datesCached = options[NOAPICachedStoreDatesCachedOption];
        
        _context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        
        _context.undoManager = nil;
        
        // initalize _dateCached & _dateCachedOperationQueues based on self.model
        [self setupDateCached];
        
    }
    return self;
}

#pragma mark - Date Cached

-(NSDate *)dateCachedForResource:(NSString *)resourceName
                      resourceID:(NSUInteger)resourceID
{
    // get the operation queue editing for the entity's mutable dicitonary of dates
    NSOperationQueue *operationQueue = _dateCachedOperationQueues[resourceName];
    
    // get the mutable dictionary
    NSMutableDictionary *resourceDatesCached = _datesCached[resourceName];
    
    __block NSDate *date;
    
    [operationQueue addOperations:@[[NSBlockOperation blockOperationWithBlock:^{
        
        date = resourceDatesCached[[NSNumber numberWithInteger:resourceID]];
        
    }]] waitUntilFinished:YES];
    
    return date;
}

#pragma mark - Requests

-(NSURLSessionDataTask *)searchForCachedResourceWithFetchRequest:(NSFetchRequest *)fetchRequest
                                                      URLSession:(NSURLSession *)urlSession
                                                      completion:(void (^)(NSError *, NSArray *))completionBlock
{
    if (!fetchRequest) {
        
        [NSException raise:NSInvalidArgumentException
                    format:@"Must specify a fetch request in order to perform a search"];
        
        return nil;
    }
    
    // entity
    
    NSEntityDescription *entity = fetchRequest.entity;
    
    if (!entity) {
        
        NSAssert(fetchRequest.entityName, @"Must specify an entity");
        
        entity = self.model.entitiesByName[fetchRequest.entityName];
        
        NSAssert(entity, @"Entity specified not found in store's model property");
    }
    
    // build JSON request from fetch request
    
    NSMutableDictionary *jsonObject = [[NSMutableDictionary alloc] init];
    
    // Optional comparison predicate
    
    NSComparisonPredicate *predicate = (NSComparisonPredicate *)fetchRequest.predicate;
    
    if (predicate) {
        
        if (![predicate isKindOfClass:[NSComparisonPredicate class]]) {
            
            [NSException raise:NSInvalidArgumentException
                        format:@"The fetch request's predicate must be of type NSComparisonPredicate"];
            
            return nil;
        }
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchPredicateKeyParameter]] = predicate.leftExpression.keyPath;
        
        // convert value to from Core Data to JSON
        
        id jsonValue = [fetchRequest.entity jsonObjectFromCoreDataValues:@{predicate.leftExpression.keyPath: predicate.rightExpression.constantValue}].allValues.firstObject;
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchPredicateValueParameter]] = jsonValue;
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchPredicateOperatorParameter]] = [NSNumber numberWithInteger:predicate.predicateOperatorType];
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchPredicateOptionParameter]] = [NSNumber numberWithInteger:predicate.options];
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchPredicateModifierParameter]] = [NSNumber numberWithInteger:predicate.comparisonPredicateModifier];
    }
    
    // other fetch parameters
    
    if (fetchRequest.fetchLimit) {
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchFetchLimitParameter]] = [NSNumber numberWithInteger: fetchRequest.fetchLimit];
    }
    
    if (fetchRequest.fetchOffset) {
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchFetchOffsetParameter]] = [NSNumber numberWithInteger:fetchRequest.fetchOffset];
    }
    
    if (fetchRequest.includesSubentities) {
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchIncludesSubentitiesParameter]] = [NSNumber numberWithInteger:fetchRequest.includesSubentities];
    }
    
    // sort descriptors
    
    if (fetchRequest.sortDescriptors.count) {
        
        NSMutableArray *jsonSortDescriptors = [[NSMutableArray alloc] init];
        
        for (NSSortDescriptor *sort in fetchRequest.sortDescriptors) {
            
            [jsonSortDescriptors addObject:@{sort.key: @(sort.ascending)}];
        }
        
        jsonObject[[NSString stringWithFormat:@"%lu", (unsigned long)NOSearchSortDescriptorsParameter]] = jsonSortDescriptors;
    }
    
    return [self searchForResource:entity.name withParameters:jsonObject URLSession:urlSession completion:^(NSError *error, NSArray *results) {
        
        if (error) {
            
            completionBlock(error, nil);
            
            return;
        }
        
        // get results as cached resources
        
        NSMutableArray *cachedResults = [[NSMutableArray alloc] init];
        
        for (NSNumber *resourceID in results) {
            
            NSManagedObject *resource = [self resource:entity.name
                                                withID:resourceID.integerValue];
            
            [cachedResults addObject:resource];
        }
        
        completionBlock(nil, cachedResults);
        
    }];
}


-(NSURLSessionDataTask *)getCachedResource:(NSString *)resourceName
                                resourceID:(NSUInteger)resourceID
                                URLSession:(NSURLSession *)urlSession
                                completion:(void (^)(NSError *, NSManagedObject<NOResourceKeysProtocol> *))completionBlock
{
    return [self getResource:resourceName withID:resourceID URLSession:urlSession completion:^(NSError *error, NSDictionary *resourceDict) {
        
        if (error) {
            
            completionBlock(error, nil);
            
            return;
        }
        
        NSManagedObject<NOResourceKeysProtocol> *resource = [self setJSONObject:resourceDict
                                                                    forResource:resourceName
                                                                         withID:resourceID];
        
        // set date cached
        
        [self cachedResource:resourceName
              withResourceID:resourceID];
        
        // optionally process changes
        
        if (self.shouldProcessPendingChanges) {
            
            [self.context performBlock:^{
                
                [self.context processPendingChanges];
            }];
        }
        
        completionBlock(nil, resource);
    }];
}

-(NSURLSessionDataTask *)createCachedResource:(NSString *)resourceName
                          initialValues:(NSDictionary *)initialValues
                             URLSession:(NSURLSession *)urlSession
                             completion:(void (^)(NSError *, NSManagedObject<NOResourceKeysProtocol> *))completionBlock
{
    NSEntityDescription *entity = self.model.entitiesByName[resourceName];
    
    assert(entity);
    
    // convert those Core Data values to JSON
    NSDictionary *jsonValues = [entity jsonObjectFromCoreDataValues:initialValues];
    
    return [self createResource:resourceName withInitialValues:jsonValues URLSession:urlSession completion:^(NSError *error, NSNumber *resourceID) {
       
        if (error) {
            
            completionBlock(error, nil);
            
            return;
        }
        
        NSManagedObject<NOResourceKeysProtocol> *resource = [self resource:resourceName
                                                                    withID:resourceID.integerValue];
        
        // set values
        for (NSString *key in initialValues) {
            
            id value = initialValues[key];
            
            // Core Data cannot hold NSNull
            
            if (value == [NSNull null]) {
                
                value = nil;
            }
            
            [resource setValue:value
                        forKey:key];
        }
        
        // set date cached
        
        [self cachedResource:resourceName
              withResourceID:resourceID.integerValue];
        
        // optionally process pending changes
        
        if (self.shouldProcessPendingChanges) {
            
            [self.context performBlock:^{
                
                [self.context processPendingChanges];
            }];
        }
        
        completionBlock(nil, resource);
    }];
}

-(NSURLSessionDataTask *)editCachedResource:(NSManagedObject<NOResourceKeysProtocol> *)resource
                              changes:(NSDictionary *)values
                           URLSession:(NSURLSession *)urlSession
                           completion:(void (^)(NSError *))completionBlock
{
    // convert those Core Data values to JSON
    NSDictionary *jsonValues = [resource.entity jsonObjectFromCoreDataValues:values];
    
    // get resourceID
    
    Class entityClass = NSClassFromString(resource.entity.managedObjectClassName);
    
    NSString *resourceIDKey = [entityClass resourceIDKey];
    
    NSNumber *resourceID = [resource valueForKey:resourceIDKey];
    
    return [self editResource:resource.entity.name withID:resourceID.integerValue changes:jsonValues URLSession:urlSession completion:^(NSError *error) {
       
        if (error) {
            
            completionBlock(error);
            
            return;
        }
        
        // set values
        for (NSString *key in values) {
            
            id value = values[key];
            
            // Core Data cannot hold NSNull
            
            if (value == [NSNull null]) {
                
                value = nil;
            }
            
            [resource setValue:value
                        forKey:key];
        }
        
        // optionally process pending changes
        
        if (self.shouldProcessPendingChanges) {
            
            [self.context performBlock:^{
                
                [self.context processPendingChanges];
            }];
        }
        
        completionBlock(nil);
        
    }];
}

-(NSURLSessionDataTask *)deleteCachedResource:(NSManagedObject<NOResourceKeysProtocol> *)resource
                             URLSession:(NSURLSession *)urlSession
           completion:(void (^)(NSError *))completionBlock
{
    // get resourceID
    
    Class entityClass = NSClassFromString(resource.entity.managedObjectClassName);
    
    NSString *resourceIDKey = [entityClass resourceIDKey];
    
    NSNumber *resourceID = [resource valueForKey:resourceIDKey];
    
    return [self deleteResource:resource.entity.name withID:resourceID.integerValue URLSession:urlSession completion:^(NSError *error) {
        
        if (error) {
            
            completionBlock(error);
            
            return;
        }
        
        // delete
        [_context performBlock:^{
           
            [_context deleteObject:resource];
            
            // optionally process pending changes
            
            if (self.shouldProcessPendingChanges) {
                
                [self.context processPendingChanges];
            }
            
            completionBlock(nil);
        }];
    }];
}

-(NSURLSessionDataTask *)performFunction:(NSString *)functionName
                        onCachedResource:(NSManagedObject<NOResourceKeysProtocol> *)resource
                          withJSONObject:(NSDictionary *)jsonObject
                              URLSession:(NSURLSession *)urlSession
                              completion:(void (^)(NSError *, NSNumber *, NSDictionary *))completionBlock
{
    // get resourceID
    
    Class entityClass = NSClassFromString(resource.entity.managedObjectClassName);
    
    NSString *resourceIDKey = [entityClass resourceIDKey];
    
    NSNumber *resourceID = [resource valueForKey:resourceIDKey];
    
    return [self performFunction:functionName
                      onResource:resource.entity.name
                          withID:resourceID.integerValue
                  withJSONObject:jsonObject
                      URLSession:urlSession
                      completion:completionBlock];
}

@end

@implementation NOAPICachedStore (Cache)

-(NSManagedObject<NOResourceKeysProtocol> *)resource:(NSString *)resourceName
                                              withID:(NSUInteger)resourceID;
{
    // look for resource in cache
    
    __block NSManagedObject<NOResourceKeysProtocol> *resource;
    
    [self.context performBlockAndWait:^{
        
        NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:resourceName];
        
        fetchRequest.fetchLimit = 1;
        
        // get entity
        NSEntityDescription *entity = self.model.entitiesByName[resourceName];
        
        Class entityClass = NSClassFromString(entity.managedObjectClassName);
        
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K == %d", [entityClass resourceIDKey], resourceID];
        
        NSError *error;
        
        NSArray *results = [self.context executeFetchRequest:fetchRequest
                                                       error:&error];
        
        if (error) {
            
            [NSException raise:@"Error executing NSFetchRequest"
                        format:@"%@", error.localizedDescription];
            
            return;
        }
        
        resource = results.firstObject;
        
        // create new object if none exists
        if (!resource) {
            
            resource = [NSEntityDescription insertNewObjectForEntityForName:resourceName
                                                     inManagedObjectContext:self.context];
            
            // set resource ID
            entityClass = NSClassFromString(resource.entity.managedObjectClassName);
            
            NSString *resourceIDKey = [entityClass resourceIDKey];
            
            [resource setValue:[NSNumber numberWithInteger:resourceID]
                        forKey:resourceIDKey];
            
        }
    }];
    
    return resource;
}

-(NSManagedObject<NOResourceKeysProtocol> *)setJSONObject:(NSDictionary *)resourceDict
                                              forResource:(NSString *)resourceName
                                                   withID:(NSUInteger)resourceID
{
    // update cache...
    
    NSManagedObject<NOResourceKeysProtocol> *resource = [self resource:resourceName
                                                                withID:resourceID];
    
    // set values...
    
    NSEntityDescription *entity = self.model.entitiesByName[resourceName];
    
    for (NSString *attributeName in entity.attributesByName) {
        
        for (NSString *key in resourceDict) {
            
            // found matching key (will only run once because dictionaries dont have duplicates)
            if ([key isEqualToString:attributeName]) {
                
                id jsonValue = [resourceDict valueForKey:key];
                
                id newValue = [resource attributeValueForJSONCompatibleValue:jsonValue
                                                                forAttribute:attributeName];
                
                id value = [resource valueForKey:key];
                
                NSAttributeDescription *attribute = entity.attributesByName[attributeName];
                
                // check if new values are different from current values...
                
                BOOL isNewValue = YES;
                
                // if both are nil
                if (!value && !newValue) {
                    
                    isNewValue = NO;
                }
                
                else {
                    
                    if (attribute.attributeType == NSStringAttributeType) {
                        
                        if ([value isEqualToString:newValue]) {
                            
                            isNewValue = NO;
                        }
                    }
                    
                    if (attribute.attributeType == NSDecimalAttributeType ||
                        attribute.attributeType == NSInteger16AttributeType ||
                        attribute.attributeType == NSInteger32AttributeType ||
                        attribute.attributeType == NSInteger64AttributeType ||
                        attribute.attributeType == NSDoubleAttributeType ||
                        attribute.attributeType == NSBooleanAttributeType ||
                        attribute.attributeType == NSFloatAttributeType) {
                        
                        if ([value isEqualToNumber:newValue]) {
                            
                            isNewValue = NO;
                        }
                    }
                    
                    if (attribute.attributeType == NSDateAttributeType) {
                        
                        if ([value isEqualToDate:newValue]) {
                            
                            isNewValue = NO;
                        }
                    }
                    
                    if (attribute.attributeType == NSBinaryDataAttributeType) {
                        
                        if ([value isEqualToData:newValue]) {
                            
                            isNewValue = NO;
                        }
                    }
                }
                
                // only set newValue if its different from the current value
                
                if (isNewValue) {
                    
                    [resource setValue:newValue
                                forKey:attributeName];
                }
                
                break;
            }
        }
    }
    
    for (NSString *relationshipName in entity.relationshipsByName) {
        
        NSRelationshipDescription *relationship = entity.relationshipsByName[relationshipName];
        
        for (NSString *key in resourceDict) {
            
            // found matching key (will only run once because dictionaries dont have duplicates)
            if ([key isEqualToString:relationshipName]) {
                
                // destination entity
                NSEntityDescription *destinationEntity = relationship.destinationEntity;
                
                // to-one relationship
                if (!relationship.isToMany) {
                    
                    // get the resource ID
                    NSNumber *destinationResourceID = [resourceDict valueForKey:relationshipName];
                    
                    NSManagedObject<NOResourceKeysProtocol> *destinationResource = [self resource:destinationEntity.name withID:destinationResourceID.integerValue];
                    
                    // dont set value if its the same as current value
                    
                    if (destinationResource != [resource valueForKey:relationshipName]) {
                        
                        [resource setValue:destinationResource
                                    forKey:key];
                    }
                }
                
                // to-many relationship
                else {
                    
                    // get the resourceIDs
                    NSArray *destinationResourceIDs = [resourceDict valueForKey:relationshipName];
                    
                    NSSet *currentValues = [resource valueForKey:relationshipName];
                    
                    NSMutableSet *destinationResources = [[NSMutableSet alloc] init];
                    
                    for (NSNumber *destinationResourceID in destinationResourceIDs) {
                        
                        NSManagedObject *destinationResource = [self resource:destinationEntity.name withID:destinationResourceID.integerValue];
                        
                        [destinationResources addObject:destinationResource];
                    }
                    
                    // set new relationships if they are different from current values
                    if (![currentValues isEqualToSet:destinationResources]) {
                        
                        [resource setValue:destinationResources
                                    forKey:key];
                    }
                    
                }
                
                break;
                
            }
        }
    }
    
    return resource;
}

@end

@implementation NSEntityDescription (Convert)

-(NSDictionary *)jsonObjectFromCoreDataValues:(NSDictionary *)values
{
    NSMutableDictionary *jsonObject = [[NSMutableDictionary alloc] init];
    
    // convert values...
    
    for (NSString *attributeName in self.attributesByName) {
        
        for (NSString *key in values) {
            
            // found matching key (will only run once because dictionaries dont have duplicates)
            if ([key isEqualToString:attributeName]) {
                
                id value = [values valueForKey:key];
                
                id jsonValue = [self JSONCompatibleValueForAttributeValue:value
                                                             forAttribute:key];
                
                jsonObject[key] = jsonValue;
                
                break;
            }
        }
    }
    
    for (NSString *relationshipName in self.relationshipsByName) {
        
        NSRelationshipDescription *relationship = self.relationshipsByName[relationshipName];
        
        for (NSString *key in values) {
            
            // found matching key (will only run once because dictionaries dont have duplicates)
            if ([key isEqualToString:relationshipName]) {
                
                // destination entity
                NSEntityDescription *destinationEntity = relationship.destinationEntity;
                
                Class entityClass = NSClassFromString(destinationEntity.managedObjectClassName);
                
                NSString *destinationResourceIDKey = [entityClass resourceIDKey];
                
                // to-one relationship
                if (!relationship.isToMany) {
                    
                    // get resource ID of object
                    
                    NSManagedObject<NOResourceKeysProtocol> *destinationResource = values[key];
                    
                    NSNumber *destinationResourceID = [destinationResource valueForKey:destinationResourceIDKey];
                    
                    jsonObject[key] = destinationResourceID;
                    
                }
                
                // to-many relationship
                else {
                    
                    NSSet *destinationResources = [values valueForKey:relationshipName];
                    
                    NSMutableArray *destinationResourceIDs = [[NSMutableArray alloc] init];
                    
                    for (NSManagedObject *destinationResource in destinationResources) {
                        
                        NSNumber *destinationResourceID = [destinationResource valueForKey:destinationResourceIDKey];
                        
                        [destinationResourceIDs addObject:destinationResourceID];
                    }
                    
                    jsonObject[key] = destinationResourceIDs;
                    
                }
                
                break;
            }
        }
    }
    
    return jsonObject;
}

@end

@implementation NOAPICachedStore (DateCached)

-(void)setupDateCached
{
    // a mutable dictionary per entity
    NSMutableDictionary *dateCached;
    
    // try to load previously saved dates entities where cached
    
    if (self.datesCached) {
        
        dateCached = [NSMutableDictionary dictionaryWithDictionary:self.datesCached];
    }
    
    else {
        
        dateCached = [[NSMutableDictionary alloc] init];
    }
    
    for (NSString *entityName in self.model.entitiesByName) {
        
        NSMutableDictionary *entityDates;
        
        // try to load previously saved dates instances of this entity where cached
        
        NSDictionary *savedEntityDates = dateCached[entityName];
        
        if (savedEntityDates) {
            
            entityDates = [NSMutableDictionary dictionaryWithDictionary:savedEntityDates];
        }
        
        else {
            
            entityDates = [[NSMutableDictionary alloc] init];
        }
        
        
        [dateCached addEntriesFromDictionary:@{entityName: entityDates}];
    }
    
    self.datesCached = [NSDictionary dictionaryWithDictionary:dateCached];
    
    // a NSOperationQueue per entity
    NSMutableDictionary *dateCachedOperationQueues = [[NSMutableDictionary alloc] init];
    
    for (NSString *entityName in self.model.entitiesByName) {
        
        [dateCachedOperationQueues addEntriesFromDictionary:@{entityName: [[NSOperationQueue alloc] init]}];
    }
    
    _dateCachedOperationQueues = [NSDictionary dictionaryWithDictionary:dateCachedOperationQueues];
    
}

-(void)cachedResource:(NSString *)resourceName
       withResourceID:(NSUInteger)resourceID
{
    // get the operation queue editing for the entity's mutable dicitonary of dates
    NSOperationQueue *operationQueue = _dateCachedOperationQueues[resourceName];
    
    // get the mutable dictionary
    NSMutableDictionary *resourceDatesCached = _datesCached[resourceName];
    
    [operationQueue addOperations:@[[NSBlockOperation blockOperationWithBlock:^{
        
        resourceDatesCached[[NSNumber numberWithInteger:resourceID]] = [NSDate date];
        
    }]] waitUntilFinished:YES];
}

@end

