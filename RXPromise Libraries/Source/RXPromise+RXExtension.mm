//
//  RXPromise+RXExtension.m
//
//  Copyright 2013 Andreas Grosam
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

#import "RXPromise+RXExtension.h"
#import "RXPromise.h"
#import "RXPromise+Private.h"
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    #import <UIKit/UIKit.h>
#endif
#include <cassert>

// Set default logger severity to "Error" (logs only errors)
#if !defined (DEBUG_LOG)
#define DEBUG_LOG 1
#endif
#import "utility/DLog.h"
#import <objc/runtime.h>


@interface RXPromiseWrapper : NSObject
@property (nonatomic, strong) RXPromise* promise;
@end

@implementation RXPromiseWrapper
@synthesize promise = _promise;
@end


namespace {
    
    void sync_sequence(NSEnumerator* iter, RXPromise* returnedPromise,
                       RXPromiseWrapper* taskPromise, rxp_unary_task task)
    {
        // Implementation notes:
        // We have a shared resource `root` which will be multiple times set by this
        // method and which is retrieved in the error handler of the returned promise
        // which is registered only once.
        
        assert(Shared.sync_queue);
        assert(task);
        assert(dispatch_get_specific(rxpromise::shared::QueueID) == rxpromise::shared::sync_queue_id);
        
        // If the returned promise has been cancelled or otherwise resolved, bail out:
        if (returnedPromise && !returnedPromise.isPending) {
            return;
        }
        id obj = [iter nextObject];
        if (obj == nil) {
            // Finished processing the inputs:
            [returnedPromise fulfillWithValue:@"OK"];
            return;
        }
        
        // Execute the task and get the task promise:
        taskPromise.promise = task(obj);
        
        // Register a continuation for the next object:
        taskPromise.promise.thenOn(Shared.sync_queue, ^id(id result){
            sync_sequence(iter, returnedPromise, taskPromise, task);
            return returnedPromise;
        }, ^id(NSError*error){
            return error;
        });
        
    }
    
    
    
    
    void rxp_while(RXPromise* returnedPromise, rxp_nullary_task block) {
        if (returnedPromise == nil || block == nil || returnedPromise.isCancelled) {
            return;
        }
        RXPromise* taskPromise = block();
        if (taskPromise == nil) {
            [returnedPromise fulfillWithValue:@"OK"];
            return;
        }
        taskPromise.then(^id(id result) {
            rxp_while(returnedPromise, block);
            return nil;
        }, ^id(NSError* error) {
            [returnedPromise rejectWithReason:error];
            return nil;
        });
        returnedPromise.then(nil, ^id(NSError* error) {
            [taskPromise cancel];
            return nil;
        });
    }
    
    
    
    
}




@implementation RXPromise (RXExtension)

#pragma mark -


+(instancetype) all:(NSArray*)promises
{
    static void const* const s_counter_key = &s_counter_key;
    RXPromise* promise = [[self alloc] init];
    int count = (int)[promises count];
    if (count == 0) {
        [promise rejectWithReason:@"parameter error"];
        return promise;
    }
    objc_setAssociatedObject(promise, s_counter_key, [NSNumber numberWithInt:count], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    promise_completionHandler_t onSuccess = ^id(id result) {
        int counter = [objc_getAssociatedObject(promise, s_counter_key) intValue];
        if (--counter > 0) {
            objc_setAssociatedObject(promise, s_counter_key, [NSNumber numberWithInt:counter], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        else {
            objc_setAssociatedObject(promise, s_counter_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSMutableArray* results = [[NSMutableArray alloc] initWithCapacity:count];
            for (RXPromise* p in promises) {
                [results addObject:[p synced_peakResult]];
            }
            [promise fulfillWithValue:results];
        }
        return nil;
    };
    promise_errorHandler_t onError = ^id(NSError* error) {
        int counter = [objc_getAssociatedObject(promise, s_counter_key) intValue];
        if (--counter > 0) {
            objc_setAssociatedObject(promise, s_counter_key, [NSNumber numberWithInt:counter], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            objc_setAssociatedObject(promise, s_counter_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [promise rejectWithReason:error];
        return nil;
    };
    
    for (RXPromise* p in promises) {
        p.thenOn(Shared.sync_queue, onSuccess, onError);
    }
    promise.thenOn(Shared.sync_queue, nil, ^id(NSError*error){
        for (RXPromise* p in promises) {
            [p cancelWithReason:error];
        }
        return nil;
    });
    
    return promise;
}


+ (instancetype) any:(NSArray*)promises
{
    static void const* const s_counter_key = &s_counter_key;
    RXPromise* promise = [[self alloc] init];
    int count = (int)[promises count];
    if (count == 0) {
        [promise rejectWithReason:@"parameter error"];
        return promise;
    }
    objc_setAssociatedObject(promise, s_counter_key, [NSNumber numberWithInt:count], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    promise_completionHandler_t onSuccess = ^(id result){
        int counter = [objc_getAssociatedObject(promise, s_counter_key) intValue];
        if (--counter > 0) {
            objc_setAssociatedObject(promise, s_counter_key, [NSNumber numberWithInt:counter], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        else {
            objc_setAssociatedObject(promise, s_counter_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (RXPromise* p in promises) {
            [p cancel];
        }
        [promise fulfillWithValue:result];
        return result;
    };
    promise_errorHandler_t onError = ^(NSError* error) {
        int counter = [objc_getAssociatedObject(promises, s_counter_key) intValue];
        if (--counter > 0) {
            objc_setAssociatedObject(promise, s_counter_key, [NSNumber numberWithInt:counter], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        else {
            objc_setAssociatedObject(promise, s_counter_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [promise rejectWithReason:@"none succeeded"];
        }
        return error;
    };
    for (RXPromise* p in promises) {
        p.thenOn(Shared.sync_queue, onSuccess, onError);
    }
    promise.thenOn(Shared.sync_queue, nil, ^id(NSError*error){
        for (RXPromise* p in promises) {
            [p cancelWithReason:error];
        }
        return error;
    });
    
    return promise;
}


+ (instancetype) sequence:(NSArray*)inputs task:(rxp_unary_task)task
{
    NSParameterAssert(task);
    assert(dispatch_get_specific(rxpromise::shared::QueueID) != rxpromise::shared::sync_queue_id);
    NSEnumerator* iter = [inputs objectEnumerator];
    
    // A promise wrapper holding the current task promise:
    RXPromiseWrapper* currentTaskPromise = [[RXPromiseWrapper alloc] init];
    
    // Create the returned promise:
    RXPromise* returnedPromise = [[self alloc] init];
    // Register an error handler which cancels the current task's root:
    returnedPromise.thenOn(Shared.sync_queue, nil, ^id(NSError*error){
        DLogInfo(@"cancelling task promise's root: %@", currentTaskPromise.promise.root);
        [currentTaskPromise.promise.root cancelWithReason:error];
        return error;
    });
    
    dispatch_sync(Shared.sync_queue, ^{
        sync_sequence(iter, returnedPromise, currentTaskPromise, task);
    });
    return returnedPromise;
}


+ (instancetype) repeat: (rxp_nullary_task)block {
    RXPromise* promise = [[self alloc] init];
    rxp_while(promise, block);
    return promise;
}




#pragma mark - iOS Specific

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

- (void) makeBackgroundTaskWithName:(NSString*)taskName {
    
    UIBackgroundTaskIdentifier backgroundTaskIdentifier =
    [[UIApplication sharedApplication] beginBackgroundTaskWithName:taskName
                                                 expirationHandler:^{
                                                     [[self root] cancelWithReason:@"Background execution time expired"];
                                                 }];
    self.thenOn(dispatch_get_main_queue(), ^id(id result) {
        [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
        return nil;
    }, ^id(NSError* error) {
        [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
        return nil;
    });
}

#endif

@end
