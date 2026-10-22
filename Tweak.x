// CameraFlip (formerly TapFlip) — Snapchat-style camera flip while recording in the iOS 6 Camera app.
//
// While you record, CameraFlip does the recording itself instead of PL's AVCaptureMovieFileOutput:
// a video data output + an audio data output feed one AVAssetWriter. Double-tapping the preview
// flips the camera with PL's own flip routine and the writer just keeps going, so the result is
// one continuous file: no stop/restart, audio never cuts out, nothing to join afterwards.
//  - Frames leave the data output already upright (on iOS 6 the connection's videoOrientation
//    physically rotates them), so both cameras share one orientation.
//  - The writer is sized for the back camera (1080p on iPhone 5) and scales the front camera's
//    720p frames up (AVVideoScalingModeKey), so the picture size never changes.
//  - Only the video input is swapped on a flip; the microphone input stays put.
// PL still thinks it's using its movie output: start/stopRecording, isRecording, recordedDuration
// and outputFileURL on that output are answered by CameraFlip, and PL's recording-delegate callbacks
// fire at the right moments, so PL saves the file exactly as it saves its own.
// If anything can't be set up (outputs can't be added, frames can't be rotated, the writer won't
// start), that recording falls back to the stock movie output.
//
// When not recording (photo mode, or video mode before you hit record), a double-tap does exactly
// what the flip button does. That replaces PL's own double-tap there (fit / fill preview toggle).

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface PLCameraController : NSObject
+ (id)sharedInstance;
- (BOOL)isCapturingVideo;
- (int)cameraMode;
- (int)cameraDevice;
- (BOOL)hasFrontCamera;
- (BOOL)hasRearCamera;
- (AVCaptureSession *)currentSession;
- (void)enqueueBlockInCaptureSessionQueue:(void (^)(void))block;
- (BOOL)isChangingModes;
@end

@interface PLCameraView : UIView
- (void)_toggleCameraButtonWasPressed:(id)sender;
- (void)_reallyToggleCamera;
- (void)_clearFocusViews;
- (id)_toggleButton;
- (id)_shutterButton;
- (id)_modeSwitch;
- (id)_previewImageWell;
- (void)setCameraButtonsEnabled:(BOOL)enabled;
- (BOOL)isCameraReady;
- (BOOL)optionsAreVisible;
- (BOOL)_toggleButtonShouldBeHidden;
@end

@interface PLCameraButton : UIButton
- (void)setIsCapturing:(BOOL)capturing;
@end

#define FTR_PHOTO_MODE 0   // PLCameraController modes: 0 photo, 1 video, 2 pano
#define FTR_VIDEO_MODE 1

enum {
    FTRStateIdle = 0,
    FTRStateStarting,    // outputs being attached, waiting for the first frame
    FTRStateRecording,
    FTRStateStopping     // writer finishing / outputs being handed back
};

#pragma mark - Log

static int gLogLines = 0;

static void FTRLog(NSString *fmt, ...) {
    if (gLogLines++ > 600) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    @synchronized([NSFileManager class]) {
        FILE *f = fopen("/var/mobile/CameraFlip.log", "a");
        if (f) {
            fputs([line UTF8String], f);
            fclose(f);
        }
    }
}

#pragma mark - Helpers

static BOOL gMirrorFront = NO;   // MirrorFront installed: front camera footage is saved mirrored
static BOOL gStockStart = NO;    // let one startRecording call through to the real movie output

static id FTRIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

static BOOL FTRBoolIvar(id obj, const char *name) {
    if (!obj) return NO;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return NO;
    return *(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv));
}

static PLCameraController *FTRController(PLCameraView *cam) {
    PLCameraController *c = FTRIvar(cam, "_cameraController");
    if (!c) c = [%c(PLCameraController) sharedInstance];
    return c;
}

static AVCaptureDeviceInput *FTRInputFor(AVCaptureSession *s, NSString *mediaType) {
    for (AVCaptureInput *in in [s inputs]) {
        if ([in isKindOfClass:[AVCaptureDeviceInput class]] && [[(AVCaptureDeviceInput *)in device] hasMediaType:mediaType]) {
            return (AVCaptureDeviceInput *)in;
        }
    }
    return nil;
}

static NSError *FTRError(NSInteger code, BOOL finishedOK) {
    return [NSError errorWithDomain:AVFoundationErrorDomain code:code
                           userInfo:@{AVErrorRecordingSuccessfullyFinishedKey: @(finishedOK)}];
}

// Upright output size: the back camera's best 16:9 size, turned to match the capture orientation.
static CGSize FTROutputSize(AVCaptureVideoOrientation o) {
    CGFloat longSide = 1280, shortSide = 720;
    for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if ([d position] != AVCaptureDevicePositionBack) continue;
        if ([d supportsAVCaptureSessionPreset:AVCaptureSessionPreset1920x1080]) {
            longSide = 1920;
            shortSide = 1080;
        } else if (![d supportsAVCaptureSessionPreset:AVCaptureSessionPreset1280x720]) {
            longSide = 640;
            shortSide = 480;
        }
    }
    BOOL portrait = (o == AVCaptureVideoOrientationPortrait || o == AVCaptureVideoOrientationPortraitUpsideDown);
    return portrait ? CGSizeMake(shortSide, longSide) : CGSizeMake(longSide, shortSide);
}

static NSDictionary *FTRVideoSettings(CGSize size, AVAssetWriter *w) {
    BOOL hd = size.width * size.height >= 1920 * 1080;
    int bitrate = hd ? 17000000 : (size.width * size.height >= 1280 * 720 ? 10000000 : 3500000);
    NSMutableDictionary *compression = [NSMutableDictionary dictionaryWithDictionary:@{
        AVVideoAverageBitRateKey: @(bitrate),
        AVVideoMaxKeyFrameIntervalKey: @30,
    }];
    if (hd) compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264High41;
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:@{
        AVVideoCodecKey: AVVideoCodecH264,
        AVVideoWidthKey: @((int)size.width),
        AVVideoHeightKey: @((int)size.height),
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,   // front camera's 720p is scaled up to fit
        AVVideoCompressionPropertiesKey: compression,
    }];
    if (![w canApplyOutputSettings:settings forMediaType:AVMediaTypeVideo]) {
        [compression removeObjectForKey:AVVideoProfileLevelKey];
        settings[AVVideoCompressionPropertiesKey] = compression;
        FTRLog(@"High profile refused, using the default profile");
    }
    return settings;
}

static NSDictionary *FTRAudioSettings(void) {
    return @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey: @1,
        AVSampleRateKey: @44100.0,
        AVEncoderBitRateKey: @64000,
    };
}

// PL turns its last movie frame (sensor orientation) into the image-well thumbnail by tagging it
// with an orientation from the capture orientation. Our frames are already upright, so turn the
// thumbnail back the other way first. Returns +1.
static CGImageRef FTRCopyPreviewFrame(NSURL *url, AVCaptureVideoOrientation o) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(960, 960);
    CMTime t = CMTimeSubtract([asset duration], CMTimeMake(1, 10));
    if (CMTimeCompare(t, kCMTimeZero) < 0) t = kCMTimeZero;
    NSError *e = nil;
    CGImageRef up = [gen copyCGImageAtTime:t actualTime:NULL error:&e];
    if (!up) {
        FTRLog(@"no thumbnail: %@", e);
        return NULL;
    }
    size_t w = CGImageGetWidth(up), h = CGImageGetHeight(up);
    BOOL swap = (o == AVCaptureVideoOrientationPortrait || o == AVCaptureVideoOrientationPortraitUpsideDown);
    size_t W = swap ? h : w, H = swap ? w : h;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        CGImageRelease(up);
        return NULL;
    }
    switch (o) {
        case AVCaptureVideoOrientationPortrait:            // PL shows it rotated 90 CW: pre-rotate 90 CCW
            CGContextTranslateCTM(ctx, W, 0);
            CGContextRotateCTM(ctx, M_PI_2);
            break;
        case AVCaptureVideoOrientationPortraitUpsideDown:  // shown rotated 90 CCW: pre-rotate 90 CW
            CGContextTranslateCTM(ctx, 0, H);
            CGContextRotateCTM(ctx, -M_PI_2);
            break;
        case AVCaptureVideoOrientationLandscapeLeft:       // shown rotated 180
            CGContextTranslateCTM(ctx, W, H);
            CGContextRotateCTM(ctx, M_PI);
            break;
        default:
            break;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), up);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGImageRelease(up);
    return out;
}

static void FTRSetPLPreviewFrame(PLCameraController *c, CGImageRef frame) {
    Ivar iv = class_getInstanceVariable(object_getClass(c), "_lastVideoPreviewFrameImageRef");
    if (!iv || !frame) return;
    CGImageRef *slot = (CGImageRef *)((uint8_t *)(__bridge void *)c + ivar_getOffset(iv));
    if (*slot) CGImageRelease(*slot);
    *slot = CGImageRetain(frame);
}

// Shift a sample buffer's timestamps (returns +1).
static CMSampleBufferRef FTRCopyShifted(CMSampleBufferRef sb, CMTime shift) {
    CMItemCount n = 0;
    if (CMSampleBufferGetSampleTimingInfoArray(sb, 0, NULL, &n) != noErr || n <= 0) return NULL;
    CMSampleTimingInfo *info = malloc(sizeof(CMSampleTimingInfo) * n);
    CMSampleBufferGetSampleTimingInfoArray(sb, n, info, &n);
    for (CMItemCount i = 0; i < n; i++) {
        info[i].presentationTimeStamp = CMTimeAdd(info[i].presentationTimeStamp, shift);
        if (CMTIME_IS_NUMERIC(info[i].decodeTimeStamp)) info[i].decodeTimeStamp = CMTimeAdd(info[i].decodeTimeStamp, shift);
    }
    CMSampleBufferRef out = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sb, n, info, &out);
    free(info);
    return out;
}

// First buffer of a stream: how far is its timestamp from host time? If it's clearly on some
// other clock, return the shift that puts it on host time; otherwise no shift.
static CMTime FTRClockShift(CMSampleBufferRef sb, NSString *what) {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    double lag = CMTimeGetSeconds(CMTimeSubtract(now, pts));
    BOOL off = fabs(lag) > 2.0;
    FTRLog(@"%@ clock: %.3fs behind host time%@", what, lag, off ? @" - not host time, shifting it" : @"");
    return off ? CMTimeSubtract(now, pts) : kCMTimeZero;
}

static void FTRFlipSettled(int gen);

#pragma mark - Recorder

@interface FTRRecorder : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate> {
    dispatch_queue_t _queue;
    int _state;
    BOOL _owns, _stopRequested, _flipping, _sessionStarted;
    int _flipGen;
    CFTimeInterval _flipAt;
    PLCameraController *_controller;
    AVCaptureSession *_session;
    AVCaptureMovieFileOutput *_movieOutput;
    id _delegate;
    NSURL *_url;
    AVCaptureVideoDataOutput *_videoOut;
    AVCaptureAudioDataOutput *_audioOut;
    AVCaptureConnection *_loggedConnection;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoIn, *_audioIn;
    AVCaptureVideoOrientation _orientation;
    CGSize _outSize;
    CMTime _firstPTS, _endPTS, _finalDuration;
    size_t _lastW, _lastH;
    unsigned _frames, _dropped, _wrongShape, _audioDropped, _audioBuffers;
    // The mic runs in its own capture session so a camera flip (which reconfigures PL's session)
    // can't pause it. _plAudioInput is PL's mic input, parked while we record.
    AVCaptureSession *_audioSession;
    AVCaptureDeviceInput *_plAudioInput, *_micInput;
    BOOL _audioSeparate, _audioFlowing;
    CFTimeInterval _attachedAt;
    // Both streams must share a clock; if one isn't on host time it gets shifted onto it.
    BOOL _videoClockChecked, _audioClockChecked;
    CMTime _videoShift, _audioShift;
    CMTime _audioEnd;
    double _maxAudioGap;
}
+ (FTRRecorder *)shared;
- (BOOL)owns:(id)output;
- (BOOL)reportsRecording;
- (BOOL)isActivelyRecording;
- (BOOL)canFlip;
- (CMTime)duration;
- (NSURL *)url;
- (BOOL)startWithOutput:(AVCaptureMovieFileOutput *)mo url:(NSURL *)url delegate:(id)delegate;
- (void)stopFromPL;
- (BOOL)beginFlip;
- (int)flipGeneration;
- (void)sessionWillCommit:(AVCaptureSession *)s;
@end

@implementation FTRRecorder

+ (FTRRecorder *)shared {
    static FTRRecorder *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        r = [FTRRecorder new];
    });
    return r;
}

- (id)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.mbucc9000.cameraflip.capture", DISPATCH_QUEUE_SERIAL);
        _finalDuration = kCMTimeZero;
    }
    return self;
}

#pragma mark What PL sees

- (BOOL)owns:(id)output {
    @synchronized(self) {
        return _owns && output == _movieOutput;
    }
}

// The movie output's isRecording: YES from start until PL has been handed the finished file.
- (BOOL)reportsRecording {
    @synchronized(self) {
        return _owns && _state != FTRStateIdle;
    }
}

- (BOOL)isActivelyRecording {
    @synchronized(self) {
        return _owns && _state == FTRStateRecording && !_stopRequested;
    }
}

- (BOOL)canFlip {
    @synchronized(self) {
        return _owns && _state == FTRStateRecording && !_stopRequested && !_flipping;
    }
}

- (CMTime)duration {
    @synchronized(self) {
        if (_state == FTRStateIdle || _state == FTRStateStopping) return _finalDuration;
        if (!_sessionStarted || !CMTIME_IS_NUMERIC(_endPTS)) return kCMTimeZero;
        return CMTimeSubtract(_endPTS, _firstPTS);
    }
}

- (NSURL *)url {
    @synchronized(self) {
        return _url;
    }
}

#pragma mark Start

- (BOOL)startWithOutput:(AVCaptureMovieFileOutput *)mo url:(NSURL *)url delegate:(id)delegate {
    PLCameraController *c = delegate;
    @synchronized(self) {
        if (_owns || _state != FTRStateIdle) {
            FTRLog(@"recorder busy, leaving this one to the stock recorder");
            return NO;
        }
    }
    if (![c respondsToSelector:@selector(enqueueBlockInCaptureSessionQueue:)]) return NO;
    AVCaptureSession *session = [c currentSession];
    if (!session || ![[session outputs] containsObject:mo] || !FTRInputFor(session, AVMediaTypeVideo) || !FTRInputFor(session, AVMediaTypeAudio)) {
        FTRLog(@"session isn't the usual video setup, using the stock recorder");
        return NO;
    }
    AVCaptureConnection *mc = [mo connectionWithMediaType:AVMediaTypeVideo];
    AVCaptureVideoOrientation o = (mc && [mc isVideoOrientationSupported]) ? [mc videoOrientation] : AVCaptureVideoOrientationPortrait;
    CGSize size = FTROutputSize(o);

    NSError *e = nil;
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&e];
    if (!w) {
        FTRLog(@"writer: %@", e);
        return NO;
    }
    if ([mo metadata]) w.metadata = [mo metadata];   // PL's location / make / model / software
    AVAssetWriterInput *vi = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:FTRVideoSettings(size, w)];
    vi.expectsMediaDataInRealTime = YES;
    AVAssetWriterInput *ai = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:FTRAudioSettings()];
    ai.expectsMediaDataInRealTime = YES;
    if (![w canAddInput:vi] || ![w canAddInput:ai]) {
        FTRLog(@"writer won't take the inputs");
        return NO;
    }
    [w addInput:vi];
    [w addInput:ai];

    AVCaptureVideoDataOutput *vdo = [AVCaptureVideoDataOutput new];
    vdo.alwaysDiscardsLateVideoFrames = YES;
    vdo.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    [vdo setSampleBufferDelegate:self queue:_queue];
    AVCaptureAudioDataOutput *ado = [AVCaptureAudioDataOutput new];
    [ado setSampleBufferDelegate:self queue:_queue];

    @synchronized(self) {
        _state = FTRStateStarting;
        _owns = YES;
        _stopRequested = NO;
        _flipping = NO;
        _sessionStarted = NO;
        _controller = c;
        _session = session;
        _movieOutput = mo;
        _delegate = delegate;
        _url = url;
        _videoOut = vdo;
        _audioOut = ado;
        _loggedConnection = nil;
        _writer = w;
        _videoIn = vi;
        _audioIn = ai;
        _orientation = o;
        _outSize = size;
        _firstPTS = kCMTimeInvalid;
        _endPTS = kCMTimeInvalid;
        _finalDuration = kCMTimeZero;
        _lastW = _lastH = 0;
        _frames = _dropped = _wrongShape = _audioDropped = _audioBuffers = 0;
        _plAudioInput = FTRInputFor(session, AVMediaTypeAudio);
        _micInput = nil;
        _audioSession = nil;
        _audioSeparate = NO;
        _audioFlowing = NO;
        _attachedAt = 0;
        _videoClockChecked = _audioClockChecked = NO;
        _videoShift = _audioShift = kCMTimeZero;
        _audioEnd = kCMTimeInvalid;
        _maxAudioGap = 0;
    }
    FTRLog(@"--- recording %@ at %.0fx%.0f, orientation %d, camera %d", [url lastPathComponent], size.width, size.height, (int)o, [c cameraDevice]);
    [c enqueueBlockInCaptureSessionQueue:^{
        [self attach];
    }];
    return YES;
}

// Session queue: swap PL's movie output for our video data output, and move the mic out of PL's
// session into one of our own, where PL's flip reconfiguration can't pause it.
- (void)attach {
    _attachedAt = CACurrentMediaTime();
    AVCaptureSession *s = _session;
    [s beginConfiguration];
    [s removeOutput:_movieOutput];
    if (_plAudioInput) [s removeInput:_plAudioInput];
    BOOL ok = [s canAddOutput:_videoOut];
    if (ok) [s addOutput:_videoOut];
    AVCaptureConnection *vc = ok ? [_videoOut connectionWithMediaType:AVMediaTypeVideo] : nil;
    if (ok && !(vc && [vc isVideoOrientationSupported])) {
        FTRLog(@"video data output can't rotate frames");
        ok = NO;
    }
    if (ok) {
        [self configureVideoConnection];
    } else {
        @synchronized(self) {
            _state = FTRStateIdle;
            _owns = NO;
        }
        if ([[s outputs] containsObject:_videoOut]) [s removeOutput:_videoOut];
        if (_plAudioInput && [s canAddInput:_plAudioInput]) [s addInput:_plAudioInput];
        if ([s canAddOutput:_movieOutput]) [s addOutput:_movieOutput];
        [self restoreMovieConnection];
    }
    [s commitConfiguration];
    if (!ok) {
        [self fallBackToStock];
        return;
    }
    if (![self startSeparateAudio]) {
        // No session of our own for the mic: put it back in PL's. Audio will pause on flips.
        FTRLog(@"mic stays in the camera session (audio will pause during flips)");
        [s beginConfiguration];
        if (_plAudioInput && ![[s inputs] containsObject:_plAudioInput] && [s canAddInput:_plAudioInput]) [s addInput:_plAudioInput];
        if ([s canAddOutput:_audioOut]) [s addOutput:_audioOut];
        [s commitConfiguration];
    }
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(sessionInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:s];
    [nc addObserver:self selector:@selector(sessionInterrupted:) name:AVCaptureSessionRuntimeErrorNotification object:s];
    if (_audioSession) {
        [nc addObserver:self selector:@selector(audioSessionNote:) name:AVCaptureSessionWasInterruptedNotification object:_audioSession];
        [nc addObserver:self selector:@selector(audioSessionNote:) name:AVCaptureSessionInterruptionEndedNotification object:_audioSession];
        [nc addObserver:self selector:@selector(audioSessionNote:) name:AVCaptureSessionRuntimeErrorNotification object:_audioSession];
    }
}

// Session queue: an audio-only capture session holding the mic and our audio data output.
- (BOOL)startSeparateAudio {
    AVCaptureDevice *mic = [_plAudioInput device] ?: [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (!mic) return NO;
    NSError *e = nil;
    AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:mic error:&e];
    if (!in) {
        FTRLog(@"mic input: %@", e);
        return NO;
    }
    AVCaptureSession *as = [AVCaptureSession new];
    [as beginConfiguration];
    BOOL ok = [as canAddInput:in];
    if (ok) [as addInput:in];
    if (ok) {
        ok = [as canAddOutput:_audioOut];
        if (ok) [as addOutput:_audioOut];
    }
    [as commitConfiguration];
    if (ok) {
        CFTimeInterval t0 = CACurrentMediaTime();
        [as startRunning];
        ok = [as isRunning];
        FTRLog(ok ? @"mic running in its own session (%.2fs to start)" : @"own audio session didn't start (%.2fs)", CACurrentMediaTime() - t0);
    } else {
        FTRLog(@"own audio session wouldn't take the mic");
    }
    if (!ok) {
        [as beginConfiguration];
        if ([[as outputs] containsObject:_audioOut]) [as removeOutput:_audioOut];
        if ([[as inputs] containsObject:in]) [as removeInput:in];
        [as commitConfiguration];
        return NO;
    }
    @synchronized(self) {
        _audioSession = as;
        _micInput = in;
        _audioSeparate = YES;
    }
    return YES;
}

// Session queue: shut the mic session down so PL can have the mic back.
- (void)stopSeparateAudio {
    AVCaptureSession *as = _audioSession;
    if (!as) return;
    [as stopRunning];
    [as beginConfiguration];
    if ([[as outputs] containsObject:_audioOut]) [as removeOutput:_audioOut];
    if (_micInput && [[as inputs] containsObject:_micInput]) [as removeInput:_micInput];
    [as commitConfiguration];
    @synchronized(self) {
        _audioSession = nil;
        _micInput = nil;
        _audioSeparate = NO;
    }
}

// The mic session hiccuped. Don't end the recording over it; the log shows whether audio came back.
- (void)audioSessionNote:(NSNotification *)n {
    FTRLog(@"mic session: %@ %@", [n name], [n userInfo] ?: @"");
}

// Session queue: hand the recording to PL's own movie output after all.
- (void)fallBackToStock {
    FTRLog(@"falling back to the stock movie recorder");
    [_videoOut setSampleBufferDelegate:nil queue:NULL];
    [_audioOut setSampleBufferDelegate:nil queue:NULL];
    AVCaptureMovieFileOutput *mo = _movieOutput;
    NSURL *url = _url;
    id d = _delegate;
    [self clearRefs];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    gStockStart = YES;
    [mo startRecordingToOutputFileURL:url recordingDelegate:d];
    gStockStart = NO;
}

// Orientation, mirroring and stabilization for whichever camera feeds the data output now.
// Called inside the session's configuration (ours, or PL's flip) so it applies from the first frame.
- (void)configureVideoConnection {
    AVCaptureConnection *vc = [_videoOut connectionWithMediaType:AVMediaTypeVideo];
    if (!vc) return;
    if ([vc isVideoOrientationSupported] && [vc videoOrientation] != _orientation) [vc setVideoOrientation:_orientation];
    BOOL front = [[FTRInputFor(_session, AVMediaTypeVideo) device] position] == AVCaptureDevicePositionFront;
    if ([vc isVideoMirroringSupported]) {
        if ([vc automaticallyAdjustsVideoMirroring]) [vc setAutomaticallyAdjustsVideoMirroring:NO];
        BOOL mirror = front && gMirrorFront;
        if ([vc isVideoMirrored] != mirror) [vc setVideoMirrored:mirror];
    }
    if ([vc isVideoStabilizationSupported] && ![vc enablesVideoStabilizationWhenAvailable]) {
        [vc setEnablesVideoStabilizationWhenAvailable:YES];
    }
    if (vc != _loggedConnection) {
        _loggedConnection = vc;
        FTRLog(@"%@ camera: orientation %d, mirrored %d, stabilization supported %d",
               front ? @"front" : @"back", (int)[vc videoOrientation], [vc isVideoMirroringSupported] && [vc isVideoMirrored],
               [vc isVideoStabilizationSupported]);
    }
}

- (void)restoreMovieConnection {
    AVCaptureConnection *mc = [_movieOutput connectionWithMediaType:AVMediaTypeVideo];
    if ([mc isVideoStabilizationSupported]) [mc setEnablesVideoStabilizationWhenAvailable:YES];
    if ([mc isVideoOrientationSupported]) [mc setVideoOrientation:_orientation];
}

// Any thread (it's PL's session queue in practice): about to commit a session change.
- (void)sessionWillCommit:(AVCaptureSession *)s {
    BOOL separate;
    @synchronized(self) {
        if (!_owns || s != _session || (_state != FTRStateStarting && _state != FTRStateRecording)) return;
        separate = _audioSeparate;
    }
    if ([[s outputs] containsObject:_movieOutput]) {
        // The movie output and a video data output can't run together; ours wins while recording.
        FTRLog(@"movie output was put back mid-recording, taking it out again");
        [s removeOutput:_movieOutput];
    }
    if (separate && _plAudioInput && [[s inputs] containsObject:_plAudioInput]) {
        FTRLog(@"camera session took the mic back mid-recording, taking it out again");
        [s removeInput:_plAudioInput];
    }
    [self configureVideoConnection];
}

- (void)sessionInterrupted:(NSNotification *)n {
    FTRLog(@"session %@ while recording", [n name]);
    dispatch_async(_queue, ^{
        [self finishWithError:FTRError(AVErrorSessionWasInterrupted, YES)];
    });
}

#pragma mark Frames

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)connection {
    if (output == _videoOut) {
        [self handleVideo:sb];
    } else if (output == _audioOut) {
        [self handleAudio:sb];
    }
}

- (void)handleVideo:(CMSampleBufferRef)sb {
    int state;
    @synchronized(self) {
        state = _state;
    }
    if (state != FTRStateStarting && state != FTRStateRecording) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    if ((w > h) != (_outSize.width > _outSize.height)) {
        _wrongShape++;   // a frame from before the new camera's rotation kicked in
        return;
    }
    if (!_videoClockChecked) {
        _videoShift = FTRClockShift(sb, @"video");
        _videoClockChecked = YES;
    }
    if (CMTimeCompare(_videoShift, kCMTimeZero) != 0) {
        CMSampleBufferRef shifted = FTRCopyShifted(sb, _videoShift);
        if (shifted) {
            [self writeVideo:shifted width:w height:h];
            CFRelease(shifted);
        }
        return;
    }
    [self writeVideo:sb width:w height:h];
}

- (void)writeVideo:(CMSampleBufferRef)sb width:(size_t)w height:(size_t)h {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);

    if (!_sessionStarted) {
        // Hold the start until the mic is live (up to 1.5s), so the video doesn't open silent.
        CFTimeInterval since = _attachedAt ? CACurrentMediaTime() - _attachedAt : 0;
        if (!_audioFlowing && since < 1.5) return;
        if (!_audioFlowing) FTRLog(@"no audio after %.1fs, starting without waiting", since);
        if (![_writer startWriting]) {
            FTRLog(@"writer won't start: %@", [_writer error]);
            [self failStart];
            return;
        }
        [_writer startSessionAtSourceTime:pts];
        @synchronized(self) {
            _sessionStarted = YES;
            _firstPTS = pts;
            _endPTS = pts;
            _state = FTRStateRecording;
        }
        FTRLog(@"first frame %zux%zu", w, h);
        id d = _delegate;
        AVCaptureMovieFileOutput *mo = _movieOutput;
        NSURL *url = _url;
        dispatch_async(dispatch_get_main_queue(), ^{
            [d captureOutput:mo didStartRecordingToOutputFileAtURL:url fromConnections:@[]];
        });
    }

    if (w != _lastW || h != _lastH) {
        BOOL wasFlipping;
        int gen;
        @synchronized(self) {
            wasFlipping = _flipping;
            _flipping = NO;
            gen = _flipGen;
        }
        if (_lastW) {
            FTRLog(@"frames now %zux%zu%@", w, h,
                   wasFlipping ? [NSString stringWithFormat:@", %.2fs after the double-tap", CACurrentMediaTime() - _flipAt] : @"");
        }
        if (wasFlipping) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FTRFlipSettled(gen);
            });
        }
        _lastW = w;
        _lastH = h;
    }

    if ([_videoIn isReadyForMoreMediaData]) {
        if (![_videoIn appendSampleBuffer:sb]) {
            FTRLog(@"video append failed: %@", [_writer error]);
            [self finishWithError:FTRError(AVErrorUnknown, NO)];
            return;
        }
        CMTime dur = CMSampleBufferGetDuration(sb);
        CMTime end = CMTIME_IS_NUMERIC(dur) ? CMTimeAdd(pts, dur) : pts;
        @synchronized(self) {
            _endPTS = end;
        }
        _frames++;
    } else {
        _dropped++;
    }
    if (_frames && _frames % 60 == 0) [self checkLimits];
}

- (void)handleAudio:(CMSampleBufferRef)sb {
    int state;
    @synchronized(self) {
        state = _state;
    }
    if (state != FTRStateStarting && state != FTRStateRecording) return;
    _audioFlowing = YES;
    if (!_audioClockChecked) {
        _audioShift = FTRClockShift(sb, @"audio");
        _audioClockChecked = YES;
    }
    if (state != FTRStateRecording || !_sessionStarted) return;
    if (CMTimeCompare(_audioShift, kCMTimeZero) != 0) {
        CMSampleBufferRef shifted = FTRCopyShifted(sb, _audioShift);
        if (shifted) {
            [self writeAudio:shifted];
            CFRelease(shifted);
        }
        return;
    }
    [self writeAudio:sb];
}

- (void)writeAudio:(CMSampleBufferRef)sb {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    if (CMTimeCompare(pts, _firstPTS) < 0) return;
    if (CMTIME_IS_NUMERIC(_audioEnd)) {
        double gap = CMTimeGetSeconds(CMTimeSubtract(pts, _audioEnd));
        if (gap > _maxAudioGap) _maxAudioGap = gap;
        if (gap > 0.1) FTRLog(@"audio gap %.2fs", gap);
    }
    CMTime dur = CMSampleBufferGetDuration(sb);
    _audioEnd = CMTIME_IS_NUMERIC(dur) ? CMTimeAdd(pts, dur) : pts;
    _audioBuffers++;
    if ([_audioIn isReadyForMoreMediaData]) {
        if (![_audioIn appendSampleBuffer:sb]) {
            FTRLog(@"audio append failed: %@", [_writer error]);
            [self finishWithError:FTRError(AVErrorUnknown, NO)];
        }
    } else {
        _audioDropped++;
    }
}

// The limits PL set on its movie output still apply: max length, max size, free space.
- (void)checkLimits {
    CMTime maxDur = [_movieOutput maxRecordedDuration];
    if (CMTIME_IS_NUMERIC(maxDur) && CMTimeGetSeconds(maxDur) > 0 && CMTimeCompare([self duration], maxDur) >= 0) {
        FTRLog(@"max duration reached");
        [self finishWithError:FTRError(AVErrorMaximumDurationReached, YES)];
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    int64_t maxSize = [_movieOutput maxRecordedFileSize];
    if (maxSize > 0 && (int64_t)[[fm attributesOfItemAtPath:[_url path] error:nil] fileSize] >= maxSize) {
        FTRLog(@"max file size reached");
        [self finishWithError:FTRError(AVErrorMaximumFileSizeReached, YES)];
        return;
    }
    int64_t minFree = [_movieOutput minFreeDiskSpaceLimit];
    if (minFree > 0) {
        NSDictionary *fs = [fm attributesOfFileSystemForPath:[[_url path] stringByDeletingLastPathComponent] error:nil];
        NSNumber *free = fs[NSFileSystemFreeSize];
        if (free && [free longLongValue] < minFree) {
            FTRLog(@"disk nearly full");
            [self finishWithError:FTRError(AVErrorDiskFull, YES)];
        }
    }
}

// Capture queue: the writer wouldn't start, before PL heard anything. Record the stock way instead.
- (void)failStart {
    @synchronized(self) {
        _state = FTRStateIdle;
        _owns = NO;
    }
    [_controller enqueueBlockInCaptureSessionQueue:^{
        [self detachOutputs];
        [self fallBackToStock];
    }];
}

#pragma mark Flip

- (BOOL)beginFlip {
    int gen;
    @synchronized(self) {
        if (!_owns || _state != FTRStateRecording || _stopRequested || _flipping) return NO;
        _flipping = YES;
        gen = ++_flipGen;
    }
    _flipAt = CACurrentMediaTime();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL timedOut = NO;
        @synchronized(self) {
            if (self->_flipGen == gen && self->_flipping) {
                self->_flipping = NO;
                timedOut = YES;
            }
        }
        if (timedOut) {
            FTRLog(@"flip: no new-camera frames after 3s");
            FTRFlipSettled(gen);
        }
    });
    return YES;
}

- (int)flipGeneration {
    @synchronized(self) {
        return _flipGen;
    }
}

#pragma mark Stop

- (void)stopFromPL {
    @synchronized(self) {
        if (!_owns || _stopRequested || _state == FTRStateIdle) return;
        _stopRequested = YES;
    }
    dispatch_async(_queue, ^{
        [self finishWithError:nil];
    });
}

// Capture queue. err nil = PL asked to stop; otherwise the recording ended by itself.
- (void)finishWithError:(NSError *)err {
    @synchronized(self) {
        if (_state != FTRStateStarting && _state != FTRStateRecording) return;
        _state = FTRStateStopping;
        _stopRequested = YES;
        _finalDuration = (_sessionStarted && CMTIME_IS_NUMERIC(_endPTS)) ? CMTimeSubtract(_endPTS, _firstPTS) : kCMTimeZero;
    }
    FTRLog(@"stopping at %.2fs: %u frames, %u dropped (encoder busy), %u skipped mid-flip; audio %@: %u buffers, %u dropped, longest gap %.2fs; error %@",
           CMTimeGetSeconds(_finalDuration), _frames, _dropped, _wrongShape, _audioSeparate ? @"(own session)" : @"(camera session)",
           _audioBuffers, _audioDropped, _maxAudioGap, err);
    if (_sessionStarted && [_writer status] == AVAssetWriterStatusWriting) {
        [_videoIn markAsFinished];
        [_audioIn markAsFinished];
        [_writer finishWritingWithCompletionHandler:^{
            dispatch_async(self->_queue, ^{
                [self writerFinished:err];
            });
        }];
    } else {
        if ([_writer status] == AVAssetWriterStatusWriting) [_writer cancelWriting];
        [self writerFinished:(err ?: FTRError(AVErrorNoDataCaptured, NO))];
    }
}

- (void)writerFinished:(NSError *)err {
    BOOL wrote = _sessionStarted && [_writer status] == AVAssetWriterStatusCompleted;
    NSError *e = err;
    if (!wrote) {
        FTRLog(@"writer ended with status %d: %@", (int)[_writer status], [_writer error]);
        e = FTRError(err ? [err code] : AVErrorUnknown, NO);
    }
    CGImageRef frame = wrote ? FTRCopyPreviewFrame(_url, _orientation) : NULL;
    [_controller enqueueBlockInCaptureSessionQueue:^{
        [self detachOutputs];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self deliverFinish:e frame:frame];
            if (frame) CGImageRelease(frame);
        });
    }];
}

// Session queue: give PL its mic and movie output back.
- (void)detachOutputs {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopSeparateAudio];
    AVCaptureSession *s = _session;
    [s beginConfiguration];
    if ([[s outputs] containsObject:_videoOut]) [s removeOutput:_videoOut];
    if ([[s outputs] containsObject:_audioOut]) [s removeOutput:_audioOut];
    if (_plAudioInput && ![[s inputs] containsObject:_plAudioInput] && [s canAddInput:_plAudioInput]) [s addInput:_plAudioInput];
    if (![[s outputs] containsObject:_movieOutput] && [s canAddOutput:_movieOutput]) [s addOutput:_movieOutput];
    [self restoreMovieConnection];
    [s commitConfiguration];
    [_videoOut setSampleBufferDelegate:nil queue:NULL];
    [_audioOut setSampleBufferDelegate:nil queue:NULL];
}

// Main: PL's own "movie finished" handler, so it saves the file like any other recording.
- (void)deliverFinish:(NSError *)e frame:(CGImageRef)frame {
    if (frame) FTRSetPLPreviewFrame(_controller, frame);
    @synchronized(self) {
        _state = FTRStateIdle;   // isRecording now NO; duration / URL still answered until PL is done
    }
    FTRLog(@"handing %@ (%.1fs) to Camera, error %@", [_url lastPathComponent], CMTimeGetSeconds(_finalDuration), e);
    @try {
        [_delegate captureOutput:_movieOutput didFinishRecordingToOutputFileAtURL:_url fromConnections:@[] error:e];
    } @catch (NSException *x) {
        FTRLog(@"finish handler threw %@", x);
    }
    @synchronized(self) {
        _owns = NO;
    }
    [self clearRefs];
}

- (void)clearRefs {
    @synchronized(self) {
        _controller = nil;
        _session = nil;
        _movieOutput = nil;
        _delegate = nil;
        _videoOut = nil;
        _audioOut = nil;
        _loggedConnection = nil;
        _writer = nil;
        _videoIn = nil;
        _audioIn = nil;
        _plAudioInput = nil;
        _micInput = nil;
        _audioSession = nil;
    }
}

@end

#pragma mark - Recording UI
// PL never flips cameras mid-recording, so its mode-change code can un-hide the image well /
// photo-video switch or reset the red stop button. Put back what was there when we flipped.

static NSArray *gUISnapshot = nil;
static BOOL gReassertUI = NO;
static __weak PLCameraView *gFlipView = nil;

static NSArray *FTRSnapshotUI(PLCameraView *cam) {
    NSMutableArray *views = [NSMutableArray array];
    if ([cam respondsToSelector:@selector(_previewImageWell)]) {
        id v = [cam _previewImageWell];
        if (v) [views addObject:v];
    }
    if ([cam respondsToSelector:@selector(_modeSwitch)]) {
        id v = [cam _modeSwitch];
        if (v) [views addObject:v];
    }
    if ([cam respondsToSelector:@selector(_toggleButton)]) {
        id v = [cam _toggleButton];
        if (v) [views addObject:v];
    }
    NSMutableArray *snap = [NSMutableArray array];
    for (id x in views) {
        if (![x isKindOfClass:[UIView class]]) continue;
        UIView *v = x;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"view"] = v;
        d[@"hidden"] = @(v.hidden);
        d[@"alpha"] = @(v.alpha);
        d[@"touch"] = @(v.userInteractionEnabled);
        if ([v isKindOfClass:[UIControl class]]) d[@"enabled"] = @(((UIControl *)v).enabled);
        [snap addObject:d];
    }
    return snap;
}

static void FTRReassertUI(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FTRReassertUI();
        });
        return;
    }
    if (!gReassertUI || ![[FTRRecorder shared] isActivelyRecording]) return;
    for (NSDictionary *d in gUISnapshot) {
        UIView *v = d[@"view"];
        v.hidden = [d[@"hidden"] boolValue];
        v.alpha = [d[@"alpha"] floatValue];
        v.userInteractionEnabled = [d[@"touch"] boolValue];
        if (d[@"enabled"] && [v isKindOfClass:[UIControl class]]) ((UIControl *)v).enabled = [d[@"enabled"] boolValue];
    }
    PLCameraView *cam = gFlipView;
    id shutter = [cam respondsToSelector:@selector(_shutterButton)] ? [cam _shutterButton] : nil;
    if ([shutter respondsToSelector:@selector(setIsCapturing:)] && !FTRBoolIvar(shutter, "_isCapturing")) {
        [(PLCameraButton *)shutter setIsCapturing:YES];
    }
}

#pragma mark - Double-tap

static CFTimeInterval gLastIdleFlip = 0;

// Not recording: anything that should stop a double-tap from acting like the flip button?
static NSString *FTRIdleFlipBlocker(PLCameraView *cam, PLCameraController *c) {
    int mode = [c cameraMode];
    if (mode != FTR_PHOTO_MODE && mode != FTR_VIDEO_MODE) return @"not in photo or video mode";
    if (![c hasFrontCamera] || ![c hasRearCamera]) return @"only one camera";
    if ([c isCapturingVideo]) return @"stock recorder is recording";
    if ([c respondsToSelector:@selector(isChangingModes)] && [c isChangingModes]) return @"camera is switching modes";
    if ([cam respondsToSelector:@selector(isCameraReady)] && ![cam isCameraReady]) return @"camera not ready";
    if ([cam respondsToSelector:@selector(optionsAreVisible)] && [cam optionsAreVisible]) return @"Options panel is open";
    if ([cam respondsToSelector:@selector(_toggleButtonShouldBeHidden)] && [cam _toggleButtonShouldBeHidden]) return @"flip button is hidden";
    if (CACurrentMediaTime() - gLastIdleFlip < 1.0) return @"previous flip less than 1s ago";
    return nil;
}

static void FTRFlip(PLCameraView *cam) {
    PLCameraController *c = FTRController(cam);
    if (!c) return;
    FTRRecorder *rec = [FTRRecorder shared];

    if (![rec reportsRecording]) {
        // Photo mode, or video mode before recording: exactly what pressing the flip button does.
        NSString *why = FTRIdleFlipBlocker(cam, c);
        if (why) {
            FTRLog(@"double-tap ignored: %@", why);
            return;
        }
        gLastIdleFlip = CACurrentMediaTime();
        FTRLog(@"flip (%@ mode): camera %d -> %d", [c cameraMode] == FTR_PHOTO_MODE ? @"photo" : @"video",
               [c cameraDevice], [c cameraDevice] == 0 ? 1 : 0);
        id button = [cam respondsToSelector:@selector(_toggleButton)] ? [cam _toggleButton] : nil;
        [cam _toggleCameraButtonWasPressed:button];
        return;
    }

    if ([c cameraMode] != FTR_VIDEO_MODE) return;
    if (![rec beginFlip]) {
        FTRLog(@"double-tap ignored (recording is starting/stopping, or a flip is still in progress)");
        return;
    }
    FTRLog(@"flip: camera %d -> %d", [c cameraDevice], [c cameraDevice] == 0 ? 1 : 0);
    gFlipView = cam;
    gUISnapshot = FTRSnapshotUI(cam);
    gReassertUI = YES;
    // What the flip button runs (snapshot + flip animation, then setCameraDevice: on the controller),
    // minus the button handler's short perform-after-delay, so the camera switches sooner.
    if ([cam respondsToSelector:@selector(_reallyToggleCamera)]) {
        if ([cam respondsToSelector:@selector(_clearFocusViews)]) [cam _clearFocusViews];
        [cam _reallyToggleCamera];
    } else {
        id button = [cam respondsToSelector:@selector(_toggleButton)] ? [cam _toggleButton] : nil;
        [cam _toggleCameraButtonWasPressed:button];
    }
}

// Main: the new camera's frames are flowing (or the flip timed out). Give PL a moment to finish its
// own UI updates, then make sure the recording controls are as they were and the stop button works.
static void FTRFlipSettled(int gen) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FTRRecorder *rec = [FTRRecorder shared];
        if ([rec flipGeneration] != gen) return;   // another flip has started; it'll settle itself
        if ([rec isActivelyRecording]) {
            PLCameraView *cam = gFlipView;
            id shutter = [cam respondsToSelector:@selector(_shutterButton)] ? [cam _shutterButton] : nil;
            if ([shutter isKindOfClass:[UIControl class]] && !((UIControl *)shutter).enabled) {
                FTRLog(@"stop button still disabled after the flip, re-enabling");
                [cam setCameraButtonsEnabled:YES];
            }
            FTRReassertUI();
        }
        gReassertUI = NO;
        gUISnapshot = nil;
    });
}

@interface FTRTapHelper : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) PLCameraView *cameraView;
+ (FTRTapHelper *)shared;
@end

@implementation FTRTapHelper

+ (FTRTapHelper *)shared {
    static FTRTapHelper *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = [FTRTapHelper new];
    });
    return h;
}

- (void)doubleTapped:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateRecognized) return;
    PLCameraView *cam = self.cameraView;
    if (cam) FTRFlip(cam);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    PLCameraView *cam = self.cameraView;
    if (!cam || cam.window != g.view) return NO;
    PLCameraController *c = FTRController(cam);
    int mode = c ? [c cameraMode] : -1;
    if (mode != FTR_PHOTO_MODE && mode != FTR_VIDEO_MODE) return NO;
    FTRRecorder *rec = [FTRRecorder shared];
    if ([rec reportsRecording] && ![rec canFlip]) return NO;   // our recording is starting, stopping or mid-flip
    for (UIView *v = touch.view; v; v = v.superview) {
        if ([v isKindOfClass:[UIControl class]] || [v isKindOfClass:[UIToolbar class]]) return NO;
    }
    UIView *area = FTRIvar(cam, "_overlayView");
    if (![area isKindOfClass:[UIView class]] || !area.window) area = FTRIvar(cam, "_previewView");
    if (![area isKindOfClass:[UIView class]] || !area.window) area = cam;
    return CGRectContainsPoint(area.bounds, [touch locationInView:area]);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

@end

static char kFTRRecognizerKey;

static void FTRAttach(PLCameraView *cam) {
    UIWindow *w = cam.window;
    if (!w) return;
    [FTRTapHelper shared].cameraView = cam;
    // On the window: PL's preview overlay isn't necessarily inside PLCameraView, and a window
    // recognizer sees every touch. shouldReceiveTouch: keeps it to the preview in photo / video mode.
    if (objc_getAssociatedObject(w, &kFTRRecognizerKey)) return;
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:[FTRTapHelper shared] action:@selector(doubleTapped:)];
    g.numberOfTapsRequired = 2;
    g.cancelsTouchesInView = NO;
    g.delaysTouchesEnded = NO;
    g.delegate = [FTRTapHelper shared];
    [w addGestureRecognizer:g];
    objc_setAssociatedObject(w, &kFTRRecognizerKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FTRLog(@"double-tap recognizer installed");
}

static BOOL FTRShouldTakeOver(AVCaptureMovieFileOutput *mo, id delegate) {
    Class plc = %c(PLCameraController);
    if (!plc || ![delegate isKindOfClass:plc]) return NO;
    if (FTRIvar(delegate, "_avCaptureOutputVideo") != mo) return NO;
    PLCameraController *c = delegate;
    return [c cameraMode] == FTR_VIDEO_MODE && [c hasFrontCamera] && [c hasRearCamera];
}

#pragma mark - Hooks

// PL's movie output: while CameraFlip is recording, it answers for it.
%hook AVCaptureMovieFileOutput

- (void)startRecordingToOutputFileURL:(NSURL *)url recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate
{
    if (!gStockStart && FTRShouldTakeOver(self, delegate) && [[FTRRecorder shared] startWithOutput:self url:url delegate:delegate]) return;
    %orig;
}

- (void)stopRecording
{
    FTRRecorder *rec = [FTRRecorder shared];
    if ([rec owns:self]) {
        [rec stopFromPL];
        return;
    }
    %orig;
}

- (BOOL)isRecording
{
    FTRRecorder *rec = [FTRRecorder shared];
    if ([rec owns:self]) return [rec reportsRecording];
    return %orig;
}

- (CMTime)recordedDuration
{
    FTRRecorder *rec = [FTRRecorder shared];
    if ([rec owns:self]) return [rec duration];
    return %orig;
}

- (NSURL *)outputFileURL
{
    FTRRecorder *rec = [FTRRecorder shared];
    if ([rec owns:self]) return [rec url];
    return %orig;
}

%end

// Applies our connection settings inside PL's flip reconfiguration, before it takes effect.
%hook AVCaptureSession

- (void)commitConfiguration
{
    [[FTRRecorder shared] sessionWillCommit:self];
    %orig;
}

%end

%hook PLCameraView

- (void)didMoveToWindow
{
    %orig;
    FTRAttach(self);
}

- (void)_handleOverlayViewDoubleTap:(id)recognizer
{
    // In photo and video modes a double-tap means flip (stock would toggle the preview fit / fill).
    PLCameraController *c = FTRController(self);
    int mode = c ? [c cameraMode] : -1;
    if ((mode == FTR_PHOTO_MODE || mode == FTR_VIDEO_MODE) && [c hasFrontCamera] && [c hasRearCamera]) return;
    %orig;
}

- (void)cameraControllerModeDidChange:(id)controller
{
    %orig;
    FTRReassertUI();
}

- (void)cameraController:(id)controller cleanApertureDidChange:(CGRect)aperture
{
    %orig;
    FTRReassertUI();
}

- (void)setCameraButtonsEnabled:(BOOL)enabled
{
    %orig;
    FTRReassertUI();
}

%end

%ctor {
    gMirrorFront = [[NSFileManager defaultManager] fileExistsAtPath:@"/Library/MobileSubstrate/DynamicLibraries/MirrorFront.dylib"];
    FTRLog(@"loaded 2.2 in %@ (MirrorFront %@)", [[NSProcessInfo processInfo] processName], gMirrorFront ? @"present" : @"absent");
    %init;
}
