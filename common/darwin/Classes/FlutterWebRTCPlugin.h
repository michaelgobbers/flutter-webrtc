#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_MAC
#import <FlutterMacOS/FlutterMacOS.h>
#endif

#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@class FlutterRTCVideoRenderer;
@class FlutterRTCFrameCapturer;

@interface FlutterWebRTCPlugin : NSObject<FlutterPlugin, RTCPeerConnectionDelegate>

@property (nonatomic, strong) RTCPeerConnectionFactory *peerConnectionFactory;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCPeerConnection *> *peerConnections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCMediaStream *> *localStreams;
@property (nonatomic, strong) NSMutableDictionary<NSString *, RTCMediaStreamTrack *> *localTracks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, FlutterRTCVideoRenderer *> *renders;
#if TARGET_OS_IPHONE
@property (nonatomic, retain) UIViewController *viewController;/*for broadcast or ReplayKit */
#endif
@property (nonatomic, strong) NSObject<FlutterBinaryMessenger>* messenger;
@property (nonatomic, strong) RTCCameraVideoCapturer *videoCapturer;
@property (nonatomic, strong) FlutterRTCFrameCapturer *frameCapturer;
#if TARGET_OS_MAC
@property (nonatomic, strong) RTCDesktopCapturer *desktopCapturer;
#endif
@property (nonatomic) BOOL _usingFrontCamera;
@property (nonatomic) int _targetWidth;
@property (nonatomic) int _targetHeight;
@property (nonatomic) int _targetFps;

- (RTCMediaStream*)streamForId:(NSString*)streamId peerConnectionId:(NSString *)peerConnectionId;
- (NSDictionary*)mediaStreamToMap:(RTCMediaStream *)stream ownerTag:(NSString*)ownerTag;
- (NSDictionary*)mediaTrackToMap:(RTCMediaStreamTrack*)track;
- (NSDictionary*)receiverToMap:(RTCRtpReceiver*)receiver;
- (NSDictionary*)transceiverToMap:(RTCRtpTransceiver*)transceiver;

@end
