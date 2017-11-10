//
//  RawLocationProvider.m
//  RCTBackgroundGeolocation
//
//  Created by Marian Hello on 06/11/2017.
//  Copyright © 2017 mauron85. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "RawLocationProvider.h"
#import "LocationController.h"
#import "Logging.h"

static NSString * const TAG = @"RawLocationProvider";
static NSString * const Domain = @"com.marianhello";

@implementation RawLocationProvider {

    BOOL isStarted;
    Config *_config;
    LocationController *locationController;
}

- (instancetype) init
{
    self = [super init];

    if (self == nil) {
        return self;
    }

    locationController = [LocationController sharedInstance];
    locationController.delegate = self;

    return self;
}

- (void) onCreate {/* noop */}

- (void) onDestroy {/* noop */}

- (BOOL) configure:(Config*)config error:(NSError * __autoreleasing *)outError
{
    DDLogVerbose(@"%@ configure", TAG);
    _config = config;

    locationController.pausesLocationUpdatesAutomatically = _config.pauseLocationUpdates;
    locationController.activityType = [_config decodeActivityType];
    locationController.distanceFilter = _config.distanceFilter; // meters
    locationController.desiredAccuracy = [_config decodeDesiredAccuracy];

    return YES;
}

- (BOOL) start:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"%@ will start", TAG);

    if (!isStarted) {
        [locationController start:outError];
        isStarted = YES;
    }

    return YES;
}

- (BOOL) stop:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"%@ will stop", TAG);

    if (isStarted) {
        [locationController stop:outError];
        isStarted = NO;
    }

    return YES;
}

- (void) switchMode:(BGOperationMode)mode
{
    /* do nothing */
}

- (void) onAuthorizationChanged:(BGAuthorizationStatus)authStatus
{
    [self.delegate onAuthorizationChanged:authStatus];
}

- (void) onLocationsChanged:(NSArray*)locations
{
    for (CLLocation *location in locations) {
        Location *bgloc = [Location fromCLLocation:location];
        [self.delegate onLocationChanged:bgloc];
    }
}

- (void) onError:(NSError*)error
{
    [super.delegate onError:error];
}

- (void) onPause:(CLLocationManager*)manager
{
    [self.delegate onLocationPause];
}

- (void) onResume:(CLLocationManager*)manager
{
    [self.delegate onLocationResume];
}

- (void) dealloc
{
//    locationController.delegate = nil;
}

@end

