//
//  DistanceFilterLocationProvider.m
//  CDVBackgroundGeolocation
//
//  Created by Marian Hello on 14/09/2016.
//  Copyright © 2016 mauron85. All rights reserved.
//

#import "DistanceFilterLocationProvider.h"
#import "Logging.h"

#define SYSTEM_VERSION_EQUAL_TO(v)                  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedSame)
#define SYSTEM_VERSION_GREATER_THAN(v)              ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedDescending)
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN(v)                 ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(v)     ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedDescending)

#define LOCATION_DENIED         "User denied use of location services."
#define LOCATION_RESTRICTED     "Application's use of location services is restricted."
#define LOCATION_NOT_DETERMINED "User undecided on application's use of location services."

static NSString * const Domain = @"com.marianhello";

enum {
    maxLocationWaitTimeInSeconds = 15,
    maxLocationAgeInSeconds = 30
};

@interface DistanceFilterLocationProvider () <CLLocationManagerDelegate>
@end

@implementation DistanceFilterLocationProvider {
    BOOL isUpdatingLocation;
    BOOL isAcquiringStationaryLocation;
    BOOL isAcquiringSpeed;
    
    CLCircularRegion *stationaryRegion;
    NSDate *stationarySince;

    BGOperationMode operationMode;
    NSDate *aquireStartTime;
    //    BOOL shouldStart; //indicating intent to start service, but we're waiting for user permission
    
    CLLocationManager *locationManager;

    // configurable options
    Config *_config;
}


- (instancetype) init
{
    self = [super init];
    
    if (self == nil) {
        return self;
    }
    
    // background location cache, for when no network is detected.
    locationManager = [[CLLocationManager alloc] init];

    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"9.0")) {
        DDLogDebug(@"DistanceFilterProvider iOS9 detected");
        locationManager.allowsBackgroundLocationUpdates = YES;
    }
    
    locationManager.delegate = self;
    
    isUpdatingLocation = NO;
    isAcquiringStationaryLocation = NO;
    isAcquiringSpeed = NO;
    //    shouldStart = NO;
    stationaryRegion = nil;
    
    return self;
}

- (void) onCreate {/* noop */}

/**
 * configure provider
 * @param {Config} configuration
 * @param {NSError} optional error
 */
- (BOOL) configure:(Config*)config error:(NSError * __autoreleasing *)outError
{
    DDLogVerbose(@"DistanceFilterProvider configure");
    _config = config;

    locationManager.pausesLocationUpdatesAutomatically = _config.pauseLocationUpdates;
    locationManager.activityType = [_config decodeActivityType];
    locationManager.distanceFilter = _config.distanceFilter; // meters
    locationManager.desiredAccuracy = [_config decodeDesiredAccuracy];
    
    return YES;
}

/**
 * Turn on background geolocation
 */
- (BOOL) start:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"DistanceFilterProvider will start");
    
    NSUInteger authStatus;
    
    if ([CLLocationManager respondsToSelector:@selector(authorizationStatus)]) { // iOS 4.2+
        authStatus = [CLLocationManager authorizationStatus];
        
        if (authStatus == kCLAuthorizationStatusDenied) {
            NSDictionary *errorDictionary = @{ @"code": [NSNumber numberWithInt:DENIED], @"message" : @LOCATION_DENIED };
            if (outError != NULL) {
                *outError = [NSError errorWithDomain:Domain code:DENIED userInfo:errorDictionary];
            }
            
            return NO;
        }
        
        if (authStatus == kCLAuthorizationStatusRestricted) {
            NSDictionary *errorDictionary = @{ @"code": [NSNumber numberWithInt:DENIED], @"message" : @LOCATION_RESTRICTED };
            if (outError != NULL) {
                *outError = [NSError errorWithDomain:Domain code:DENIED userInfo:errorDictionary];
            }
            
            return NO;
        }
        
#ifdef __IPHONE_8_0
        // we do startUpdatingLocation even though we might not get permissions granted
        // we can stop later on when recieved callback on user denial
        // it's neccessary to start call startUpdatingLocation in iOS < 8.0 to show user prompt!
        
        if (authStatus == kCLAuthorizationStatusNotDetermined) {
            if ([locationManager respondsToSelector:@selector(requestAlwaysAuthorization)]) {  //iOS 8.0+
                DDLogVerbose(@"DistanceFilterProvider requestAlwaysAuthorization");
                [locationManager requestAlwaysAuthorization];
            }
        }
#endif
    }
    
    [self switchMode:FOREGROUND];
    
    return YES;
}

/**
 * Turn it off
 */
- (BOOL) stop:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"DistanceFilterProvider stop");
    
    [self stopUpdatingLocation];
    [self stopMonitoringSignificantLocationChanges];
    [self stopMonitoringForRegion];
    
    return YES;
}

/**
 * toggle between foreground and background operation mode
 */
- (void) switchMode:(BGOperationMode)mode
{
    DDLogInfo(@"DistanceFilterProvider switchMode %lu", (unsigned long)mode);
    
    operationMode = mode;
    
    if (operationMode == FOREGROUND || !_config.saveBatteryOnBackground) {
        isAcquiringSpeed = YES;
        isAcquiringStationaryLocation = NO;
        [self stopMonitoringForRegion];
        [self stopMonitoringSignificantLocationChanges];
    } else if (operationMode == BACKGROUND) {
        isAcquiringSpeed = NO;
        isAcquiringStationaryLocation = YES;
        [self startMonitoringSignificantLocationChanges];
    }
    
    aquireStartTime = [NSDate date];
    
    // Crank up the GPS power temporarily to get a good fix on our current location
    [self stopUpdatingLocation];
    locationManager.distanceFilter = kCLDistanceFilterNone;
    locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    [self startUpdatingLocation];
}

- (void) locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    DDLogDebug(@"DistanceFilterProvider didUpdateLocations (operationMode: %lu)", (unsigned long)operationMode);
    
    BGOperationMode actAsInMode = operationMode;
    
    if (actAsInMode == BACKGROUND) {
        if (_config.saveBatteryOnBackground == NO) actAsInMode = FOREGROUND;
    }
    
    if (actAsInMode == FOREGROUND) {
        if (!isUpdatingLocation) [self startUpdatingLocation];
    }
    
    if (actAsInMode == BACKGROUND) {
        if (!isAcquiringStationaryLocation && !stationaryRegion) {
            // Perhaps our GPS signal was interupted, re-acquire a stationaryLocation now.
            [self switchMode:operationMode];
        }
    }
    
    
    Location *bestLocation = nil;
    for (CLLocation *location in locations) {
        Location *bgloc = [Location fromCLLocation:location];
        
        // test the age of the location measurement to determine if the measurement is cached
        // in most cases you will not want to rely on cached measurements
        DDLogDebug(@"Location age %f", [bgloc locationAge]);
        if ([bgloc locationAge] > maxLocationAgeInSeconds || ![bgloc hasAccuracy] || ![bgloc hasTime]) {
            continue;
        }
        
        if (bestLocation == nil) {
            bestLocation = bgloc;
            continue;
        }
        
        if ([bgloc isBetterLocation:bestLocation]) {
            DDLogInfo(@"Better location found: %@", bgloc);
            bestLocation = bgloc;
        }
    }
    
    if (bestLocation == nil) {
        return;
    }
    
    // test the measurement to see if it is more accurate than the previous measurement
    if (isAcquiringStationaryLocation) {
        DDLogDebug(@"Acquiring stationary location, accuracy: %@", bestLocation.accuracy);
        if (_config.isDebugging) {
            AudioServicesPlaySystemSound (acquiringLocationSound);
        }
        
        if ([bestLocation.accuracy doubleValue] <= [[NSNumber numberWithInteger:_config.desiredAccuracy] doubleValue]) {
            DDLogDebug(@"DistanceFilterProvider found most accurate stationary before timeout");
        } else if (-[aquireStartTime timeIntervalSinceNow] < maxLocationWaitTimeInSeconds) {
            // we still have time to aquire better location
            return;
        }
        
        isAcquiringStationaryLocation = NO;
        [self stopUpdatingLocation]; //saving power while monitoring region
        
        Location *stationaryLocation = [bestLocation copy];
        stationaryLocation.radius = [NSNumber numberWithInteger:_config.stationaryRadius];
        stationaryLocation.time = stationarySince;
        [self startMonitoringStationaryRegion:stationaryLocation];
        // fire onStationary @event for Javascript.
        [super.delegate onStationaryChanged:stationaryLocation];
    } else if (isAcquiringSpeed) {
        if (_config.isDebugging) {
            AudioServicesPlaySystemSound (acquiringLocationSound);
        }
        
        if ([bestLocation.accuracy doubleValue] <= [[NSNumber numberWithInteger:_config.desiredAccuracy] doubleValue]) {
            DDLogDebug(@"DistanceFilterProvider found most accurate location before timeout");
        } else if (-[aquireStartTime timeIntervalSinceNow] < maxLocationWaitTimeInSeconds) {
            // we still have time to aquire better location
            return;
        }
        
        if (_config.isDebugging) {
            [self notify:@"Aggressive monitoring engaged"];
        }
        
        // We should have a good sample for speed now, power down our GPS as configured by user.
        isAcquiringSpeed = NO;
        locationManager.desiredAccuracy = _config.desiredAccuracy;
        locationManager.distanceFilter = [self calculateDistanceFilter:[bestLocation.speed floatValue]];
        [self startUpdatingLocation];
        
    } else if (actAsInMode == FOREGROUND) {
        // Adjust distanceFilter incrementally based upon current speed
        float newDistanceFilter = [self calculateDistanceFilter:[bestLocation.speed floatValue]];
        if (newDistanceFilter != locationManager.distanceFilter) {
            DDLogInfo(@"DistanceFilterProvider updated distanceFilter, new: %f, old: %f", newDistanceFilter, locationManager.distanceFilter);
            locationManager.distanceFilter = newDistanceFilter;
            [self startUpdatingLocation];
        }
    } else if ([self locationIsBeyondStationaryRegion:bestLocation]) {
        if (_config.isDebugging) {
            [self notify:@"Manual stationary exit-detection"];
        }
        [self switchMode:operationMode];
    }
    
    [super.delegate onLocationChanged:bestLocation];
}

/**
 * Called when user exits their stationary radius (ie: they walked ~50m away from their last recorded location.
 *
 */
- (void) locationManager:(CLLocationManager *)manager didExitRegion:(CLCircularRegion *)region
{
    CLLocationDistance radius = [region radius];
    CLLocationCoordinate2D coordinate = [region center];
    
    DDLogDebug(@"DistanceFilterProvider didExitRegion {%f,%f,%f}", coordinate.latitude, coordinate.longitude, radius);
    if (_config.isDebugging) {
        AudioServicesPlaySystemSound (exitRegionSound);
        [self notify:@"Exit stationary region"];
    }
    [self switchMode:operationMode];
}

- (void) locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager
{
    DDLogDebug(@"DistanceFilterProvider location updates paused");
    if (_config.isDebugging) {
        [self notify:@"Location updates paused"];
    }
}

- (void) locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager
{
    DDLogDebug(@"DistanceFilterProvider location updates resumed");
    if (_config.isDebugging) {
        [self notify:@"Location updates resumed b"];
    }
}

- (void) locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    DDLogError(@"DistanceFilterProvider didFailWithError: %@", error);
    if (_config.isDebugging) {
        AudioServicesPlaySystemSound (locationErrorSound);
        [self notify:[NSString stringWithFormat:@"Location error: %@", error.localizedDescription]];
    }
    
    switch(error.code) {
        case kCLErrorLocationUnknown:
        case kCLErrorNetwork:
        case kCLErrorRegionMonitoringDenied:
        case kCLErrorRegionMonitoringSetupDelayed:
        case kCLErrorRegionMonitoringResponseDelayed:
        case kCLErrorGeocodeFoundNoResult:
        case kCLErrorGeocodeFoundPartialResult:
        case kCLErrorGeocodeCanceled:
            break;
        case kCLErrorDenied:
            break;
    }
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(onError:)]) {
        [self.delegate onError:error];
    }
}

- (void) locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    DDLogInfo(@"LocationManager didChangeAuthorizationStatus %u", status);
    if (_config.isDebugging) {
        [self notify:[NSString stringWithFormat:@"Authorization status changed %u", status]];
    }
    
    switch(status) {
        case kCLAuthorizationStatusRestricted:
        case kCLAuthorizationStatusDenied:
            if (self.delegate && [self.delegate respondsToSelector:@selector(onAuthorizationChanged:)]) {
                [self.delegate onAuthorizationChanged:DENIED];
            }
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
            if (self.delegate && [self.delegate respondsToSelector:@selector(onAuthorizationChanged:)]) {
                [self.delegate onAuthorizationChanged:ALLOWED];
            }
            break;
        default:
            break;
    }
}

- (void) stopUpdatingLocation
{
    if (isUpdatingLocation) {
        [locationManager stopUpdatingLocation];
        isUpdatingLocation = NO;
    }
}

- (void) startUpdatingLocation
{
    if (!isUpdatingLocation) {
        [locationManager startUpdatingLocation];
        isUpdatingLocation = YES;
    }
}

- (void) startMonitoringSignificantLocationChanges
{
    [locationManager startMonitoringSignificantLocationChanges];
}

- (void) stopMonitoringSignificantLocationChanges
{
    [locationManager stopMonitoringSignificantLocationChanges];
}

/**
 * Creates a new circle around user and region-monitors it for exit
 */
- (void) startMonitoringStationaryRegion:(Location*)location {
    CLLocationCoordinate2D coord = [location coordinate];
    DDLogDebug(@"DistanceFilterProvider startMonitoringStationaryRegion {%f,%f,%ld}", coord.latitude, coord.longitude, (long)_config.stationaryRadius);
    
    if (_config.isDebugging) {
        AudioServicesPlaySystemSound (acquiredLocationSound);
        [self notify:[NSString stringWithFormat:@"Monitoring region {%f,%f,%ld}", location.coordinate.latitude, location.coordinate.longitude, (long)_config.stationaryRadius]];
    }
    
    [self stopMonitoringForRegion];
    stationaryRegion = [[CLCircularRegion alloc] initWithCenter: coord radius:_config.stationaryRadius identifier:@"DistanceFilterProvider stationary region"];
    stationaryRegion.notifyOnExit = YES;
    [locationManager startMonitoringForRegion:stationaryRegion];
    stationarySince = [NSDate date];
}

- (void) stopMonitoringForRegion
{
    if (stationaryRegion != nil) {
        [locationManager stopMonitoringForRegion:stationaryRegion];
        stationaryRegion = nil;
        stationarySince = nil;
    }
}

/**
 * Calculates distanceFilter by rounding speed to nearest 5 and multiplying by 10.  Clamped at 1km max.
 */
- (float) calculateDistanceFilter:(float)speed
{
    float newDistanceFilter = _config.distanceFilter;
    if (speed < 100) {
        // (rounded-speed-to-nearest-5) / 2)^2
        // eg 5.2 becomes (5/2)^2
        newDistanceFilter = pow((5.0 * floorf(fabsf(speed) / 5.0 + 0.5f)), 2) + _config.distanceFilter;
    }
    return (newDistanceFilter < 1000) ? newDistanceFilter : 1000;
}

/**
 * Manual stationary location his-testing.  This seems to help stationary-exit detection in some places where the automatic geo-fencing doesn't
 */
- (BOOL) locationIsBeyondStationaryRegion:(Location*)location
{
    CLLocationCoordinate2D regionCenter = [stationaryRegion center];
    BOOL containsCoordinate = [stationaryRegion containsCoordinate:[location coordinate]];
    
    DDLogVerbose(@"DistanceFilterProvider location {%@,%@} region {%f,%f,%f} contains: %d",
                 location.latitude, location.longitude, regionCenter.latitude, regionCenter.longitude,
                 [stationaryRegion radius], containsCoordinate);
    
    return !containsCoordinate;
}

- (void) notify:(NSString*)message
{
    [super notify:message];
}

- (void) onDestroy
{
    locationManager.delegate = nil;
    //    [super dealloc];
}

@end
