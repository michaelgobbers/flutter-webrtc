#import <objc/runtime.h>

#import "FlutterRTCDesktopCapturer.h"

#if TARGET_OS_IPHONE
#import <ReplayKit/ReplayKit.h>
#import "FlutterRPScreenRecorder.h"
#import "FlutterBroadcastScreenCapturer.h"
#endif

#if TARGET_OS_OSX
dispatch_source_t refresh_timer;
RTCDesktopMediaList *_screen = nil;
RTCDesktopMediaList *_window = nil;
BOOL _captureWindow = NO;
BOOL _captureScreen = NO;
NSMutableArray<RTCDesktopSource *>* _captureSources;
FlutterEventSink _eventSink = nil;
FlutterEventChannel* _eventChannel = nil;
#endif

@implementation NSArray (Additions)

- (instancetype)arrayByRemovingObject:(id)object {
    return [self filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != %@", object]];
}

@end

@implementation FlutterWebRTCPlugin (DesktopCapturer)

-(void)getDisplayMedia:(NSDictionary *)constraints
                result:(FlutterResult)result {
    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
    RTCVideoSource *videoSource = [self.peerConnectionFactory videoSource];

#if TARGET_OS_IPHONE
 BOOL useBroadcastExtension = false;
    id videoConstraints = constraints[@"video"];
    if ([videoConstraints isKindOfClass:[NSDictionary class]]) {
       // constraints.video.deviceId
        useBroadcastExtension = [((NSDictionary *)videoConstraints)[@"deviceId"] isEqualToString:@"broadcast"];
    }
    
    id screenCapturer;
    
    if(useBroadcastExtension){
        screenCapturer = [[FlutterBroadcastScreenCapturer alloc] initWithDelegate:videoSource];
    } else {
        screenCapturer = [[FlutterRPScreenRecorder alloc] initWithDelegate:videoSource];
    }
    
    [screenCapturer startCapture];
    NSLog(@"start %@ capture", useBroadcastExtension ? @"broadcast" : @"replykit");
        
    self.videoCapturerStopHandlers[mediaStreamId] = ^(CompletionHandler handler) {
        NSLog(@"stop %@ capture", useBroadcastExtension ? @"broadcast" : @"replykit");
        [screenCapturer stopCaptureWithCompletionHandler:handler];
    };

    if(useBroadcastExtension) {
        NSString *extension = [[[NSBundle mainBundle] infoDictionary] valueForKey: kRTCScreenSharingExtension];
        if(extension) {
            RPSystemBroadcastPickerView *picker = [[RPSystemBroadcastPickerView alloc] init];
            picker.preferredExtension = extension;
            picker.showsMicrophoneButton = false;
            
            SEL selector = NSSelectorFromString(@"buttonPressed:");
            if([picker respondsToSelector:selector]) {
                [picker performSelector:selector withObject:nil];
            }
        }
    }
#endif
    
#if TARGET_OS_OSX
/* example for constraints:
    {
        'audio': false,
        'video": {
            'deviceId':  {'exact': sourceId},
            'mandatory': {
                'frameRate': 30.0
            },
        }
    }
*/
    NSString *sourceId = nil;
    BOOL useDefaultScreen = NO;
    NSInteger fps = 30;
    id videoConstraints = constraints[@"video"];
    if([videoConstraints isKindOfClass:[NSNumber class]] && [videoConstraints boolValue] == YES) {
        useDefaultScreen = YES;
    } else if ([videoConstraints isKindOfClass:[NSDictionary class]]) {
        NSDictionary *deviceId = videoConstraints[@"deviceId"];
        if (deviceId != nil && [deviceId isKindOfClass:[NSDictionary class]]) {
            if(deviceId[@"exact"] != nil) {
                sourceId = deviceId[@"exact"];
                if(sourceId == nil) {
                    result(@{@"error": @"No deviceId.exact found"});
                    return;
                }
            }
        } else {
            // fall back to default screen if no deviceId is specified
            useDefaultScreen = YES;
        }
        id mandatory = videoConstraints[@"mandatory"];
        if (mandatory != nil && [mandatory isKindOfClass:[NSDictionary class]]) {
            id frameRate = mandatory[@"frameRate"];
            if (frameRate != nil && [frameRate isKindOfClass:[NSNumber class]]) {
                fps = [frameRate integerValue];
            }
        }
    }
    RTCDesktopCapturer *desktopCapturer;
    RTCDesktopSource *source = nil;
    if(useDefaultScreen){
        desktopCapturer  = [[RTCDesktopCapturer alloc] initWithDefaultScreen:self captureDelegate:videoSource];
    } else {
         source = [self getSourceById:sourceId];
        if(source == nil) {
            result(@{@"error":  [NSString stringWithFormat:@"No source found for id: %@",sourceId]});
            return;
        }
        desktopCapturer  = [[RTCDesktopCapturer alloc] initWithSource:source delegate:self captureDelegate:videoSource];
    }
    [desktopCapturer startCaptureWithFPS:fps];
    NSLog(@"start desktop capture: sourceId: %@, type: %@, fps: %lu", sourceId, source.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window", fps);

    self.videoCapturerStopHandlers[mediaStreamId] = ^(CompletionHandler handler) {
        NSLog(@"stop desktop capture: sourceId: %@, type: %@", sourceId, source.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window");
        [desktopCapturer stopCapture];
        handler();
    };
#endif

    NSString *trackUUID = [[NSUUID UUID] UUIDString];
    RTCVideoTrack *videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource trackId:trackUUID];
    [mediaStream addVideoTrack:videoTrack];

    NSMutableArray *audioTracks = [NSMutableArray array];
    NSMutableArray *videoTracks = [NSMutableArray array];

    for (RTCVideoTrack *track in mediaStream.videoTracks) {
        [self.localTracks setObject:track forKey:track.trackId];
        [videoTracks addObject:@{@"id": track.trackId, @"kind": track.kind, @"label": track.trackId, @"enabled": @(track.isEnabled), @"remote": @(YES), @"readyState": @"live"}];
    }

    self.localStreams[mediaStreamId] = mediaStream;
    result(@{@"streamId": mediaStreamId, @"audioTracks" : audioTracks, @"videoTracks" : videoTracks });
}

-(void)getDesktopSources:(NSDictionary *)argsMap
             result:(FlutterResult)result {
#if TARGET_OS_OSX
    NSArray *types = [argsMap objectForKey:@"types"];
    if (types == nil) {
        result([FlutterError errorWithCode:@"ERROR"
                                   message:@"types is required"
                                   details:nil]);
        return;
    }

    NSEnumerator *typesEnumerator = [types objectEnumerator];
    NSString *type;
    _captureWindow = NO;
    _captureScreen = NO;
    _captureSources = [NSMutableArray array];
    while ((type = typesEnumerator.nextObject) != nil) {
        if ([type isEqualToString:@"screen"]) {
            _captureScreen = YES;
        } else if ([type isEqualToString:@"window"]) {
            _captureWindow = YES;
        } else {
            result([FlutterError errorWithCode:@"ERROR"
                                       message:@"Invalid type"
                                       details:nil]);
            return;
        }
    }

    if(!_captureWindow && !_captureScreen) {
        result([FlutterError errorWithCode:@"ERROR"
                                   message:@"At least one type is required"
                                   details:nil]);
        return;
    }

    NSMutableArray *sources = [NSMutableArray array];
    [self startHandling:_captureWindow captureScreen:_captureScreen];
    NSEnumerator *enumerator = [_captureSources objectEnumerator];
    RTCDesktopSource *object;
    while ((object = enumerator.nextObject) != nil) {
        [sources addObject:@{
                             @"id": object.sourceId,
                             @"name": object.name,
                             @"thumbnailSize": @{@"width": @0, @"height": @0},
                             @"type": object.sourceType == RTCDesktopSourceTypeScreen? @"screen" : @"window",
                             }];
    }
    result(@{@"sources": sources});
#else
    result([FlutterError errorWithCode:@"ERROR"
                               message:@"Not supported on iOS"
                               details:nil]);
#endif
}

-(void)getDesktopSourceThumbnail:(NSDictionary *)argsMap
             result:(FlutterResult)result {
#if TARGET_OS_OSX
    NSString* sourceId = argsMap[@"sourceId"];
    RTCDesktopSource *object = [self getSourceById:sourceId];
    if(object == nil) {
        result(@{@"error": @"No source found"});
        return;
    }
    NSImage *image = [object UpdateThumbnail];
    if(image != nil) {
        NSImage *resizedImg = [self resizeImage:image forSize:NSMakeSize(140, 140)];
        NSData *data = [resizedImg TIFFRepresentation];
        result(data);
    } else {
        result(@{@"error": @"No thumbnail found"});
    }
    
#else
    result([FlutterError errorWithCode:@"ERROR"
                               message:@"Not supported on iOS"
                               details:nil]);
#endif
}

#if TARGET_OS_OSX
- (NSImage*)resizeImage:(NSImage*)sourceImage forSize:(CGSize)targetSize {
    CGSize imageSize = sourceImage.size;
    CGFloat width = imageSize.width;
    CGFloat height = imageSize.height;
    CGFloat targetWidth = targetSize.width;
    CGFloat targetHeight = targetSize.height;
    CGFloat scaleFactor = 0.0;
    CGFloat scaledWidth = targetWidth;
    CGFloat scaledHeight = targetHeight;
    CGPoint thumbnailPoint = CGPointMake(0.0,0.0);

    if (CGSizeEqualToSize(imageSize, targetSize) == NO) {
        CGFloat widthFactor = targetWidth / width;
        CGFloat heightFactor = targetHeight / height;

        // scale to fit the longer
        scaleFactor = (widthFactor>heightFactor)?widthFactor:heightFactor;
        scaledWidth  = ceil(width * scaleFactor);
        scaledHeight = ceil(height * scaleFactor);

        // center the image
        if (widthFactor > heightFactor) {
            thumbnailPoint.y = (targetHeight - scaledHeight) * 0.5;
        } else if (widthFactor < heightFactor) {
            thumbnailPoint.x = (targetWidth - scaledWidth) * 0.5;
        }
    }

    NSImage *newImage = [[NSImage alloc] initWithSize:NSMakeSize(scaledWidth, scaledHeight)];
    CGRect thumbnailRect = {thumbnailPoint, {scaledWidth, scaledHeight}};
    NSRect imageRect = NSMakeRect(0.0, 0.0, width, height);

    [newImage lockFocus];
    [sourceImage drawInRect:thumbnailRect fromRect:imageRect operation:NSCompositeCopy fraction:1.0];
    [newImage unlockFocus];

    return newImage;
}

-(RTCDesktopSource *)getSourceById:(NSString *)sourceId {
    NSEnumerator *enumerator = [_captureSources objectEnumerator];
    RTCDesktopSource *object;
    while ((object = enumerator.nextObject) != nil) {
        if([sourceId isEqualToString:object.sourceId]) {
            return object;
        }
    }
    return nil;
}

- (void)startHandling:(BOOL)captureWindow captureScreen:(BOOL) captureScreen {
    [self stopHandling];
     if(_captureWindow) {
        if(!_window) _window = [[RTCDesktopMediaList alloc] initWithType:RTCDesktopSourceTypeWindow delegate:self];
         [_window UpdateSourceList:NO];
        NSArray<RTCDesktopSource *>* sources = [_window getSources];
        _captureSources = [_captureSources arrayByAddingObjectsFromArray:sources];
    }

    if(_captureScreen) {
        if(!_screen) _screen = [[RTCDesktopMediaList alloc] initWithType:RTCDesktopSourceTypeScreen  delegate:self];
        [_screen UpdateSourceList:NO];
        NSArray<RTCDesktopSource *>* sources = [_screen getSources];
        _captureSources = [_captureSources arrayByAddingObjectsFromArray:sources];
    }
    NSLog(@"captureSources: %lu", [_captureSources count]);
    refresh_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(refresh_timer, DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC, 0 * NSEC_PER_SEC);
    __weak typeof (self) weak_self = self;
    dispatch_source_set_event_handler(refresh_timer, ^{
        [weak_self refreshSources];
    });

    dispatch_resume(refresh_timer);
}

- (void) refreshSources {
        if(_captureWindow && _window != nil) {
            [_window UpdateSourceList:YES];
        }
        if(_captureScreen && _screen != nil) {
            [_screen UpdateSourceList:YES];
        }
}

- (void)stopHandling {
    if (refresh_timer) {
        dispatch_source_cancel(refresh_timer);
        refresh_timer = nil;
    }
}

-(void) enableDesktopCapturerEventChannel:(nonnull NSObject<FlutterBinaryMessenger> *)messenger {
    if(_eventChannel == nil) {
        _eventChannel = [FlutterEventChannel
                                            eventChannelWithName:@"FlutterWebRTC/desktopSourcesEvent"
                                            binaryMessenger:messenger];
        [_eventChannel setStreamHandler:self];
    }
}

#pragma mark - FlutterStreamHandler methods

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)sink {
    _eventSink = sink;
    return nil;
}


#pragma mark - RTCDesktopMediaListDelegate delegate

- (void)didDesktopSourceAdded:(RTC_OBJC_TYPE(RTCDesktopSource) *)source {
    //NSLog(@"didDesktopSourceAdded: %@, id %@", source.name, source.sourceId);
    _captureSources = [_captureSources arrayByAddingObject:source];
    if(_eventSink) {
        NSImage *image = [source UpdateThumbnail];
        NSData *data = [[NSData alloc] init];
        if(image != nil) {
            NSImage *resizedImg = [self resizeImage:image forSize:NSMakeSize(140, 140)];
            data = [resizedImg TIFFRepresentation];
        }
        _eventSink(@{
            @"event": @"desktopSourceAdded",
            @"id": source.sourceId,
            @"name": source.name,
            @"thumbnailSize": @{@"width": @0, @"height": @0},
            @"type": source.sourceType == RTCDesktopSourceTypeScreen? @"screen" : @"window",
            @"thumbnail": data
        });
    }
}

- (void)didDesktopSourceRemoved:(RTC_OBJC_TYPE(RTCDesktopSource) *) source {
   //NSLog(@"didDesktopSourceRemoved: %@, id %@", source.name, source.sourceId);
    _captureSources = [_captureSources arrayByRemovingObject:source];
    if(_eventSink) {
        _eventSink(@{
            @"event": @"desktopSourceRemoved",
            @"id": source.sourceId,
        });
    }
}

- (void)didDesktopSourceNameChanged:(RTC_OBJC_TYPE(RTCDesktopSource) *) source {
    //NSLog(@"didDesktopSourceNameChanged: %@, id %@", source.name, source.sourceId);
    if(_eventSink) {
        _eventSink(@{
            @"event": @"desktopSourceNameChanged",
            @"id": source.sourceId,
            @"name": source.name,
        });
    }
}

- (void)didDesktopSourceThumbnailChanged:(RTC_OBJC_TYPE(RTCDesktopSource) *) source {
    //NSLog(@"didDesktopSourceThumbnailChanged: %@, id %@", source.name, source.sourceId);
    if(_eventSink) {
        NSImage *resizedImg = [self resizeImage:[source thumbnail] forSize:NSMakeSize(140, 140)];
        NSData *data = [resizedImg TIFFRepresentation];
        _eventSink(@{
            @"event": @"desktopSourceThumbnailChanged",
            @"id": source.sourceId,
            @"thumbnail": data 
        });
    }
}

#pragma mark - RTCDesktopCapturerDelegate delegate

-(void)didSourceCaptureStart:(RTCDesktopCapturer *) capturer {
    NSLog(@"didSourceCaptureStart");
}

-(void)didSourceCapturePaused:(RTCDesktopCapturer *) capturer {
    NSLog(@"didSourceCapturePaused");
}

-(void)didSourceCaptureStop:(RTCDesktopCapturer *) capturer {
    NSLog(@"didSourceCaptureStop");
}

-(void)didSourceCaptureError:(RTCDesktopCapturer *) capturer{
    NSLog(@"didSourceCaptureError");
}

#endif

@end
