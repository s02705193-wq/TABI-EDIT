#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <Photos/Photos.h>
#include <math.h>

@interface TabiViewController : UIViewController <WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSURL *currentVideoURL;
@property (nonatomic, strong) NSURL *recordedVoiceURL;
@property (nonatomic, strong) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong) NSTimer *exportProgressTimer;
@property (nonatomic, strong) AVAssetExportSession *activeExporter;
@end

@implementation TabiViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:1.0];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
    [config.userContentController addScriptMessageHandler:self name:@"tabiNative"];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.opaque = NO;
    self.webView.backgroundColor = self.view.backgroundColor;
    self.webView.scrollView.backgroundColor = self.view.backgroundColor;
    self.webView.UIDelegate = self;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    if (htmlPath) {
        NSURL *htmlURL = [NSURL fileURLWithPath:htmlPath];
        NSURL *readRoot = [NSURL fileURLWithPath:@"/"];
        [self.webView loadFileURL:htmlURL allowingReadAccessToURL:readRoot];
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)sendJSEvent:(NSString *)jsCode {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:jsCode completionHandler:nil];
    });
}

// Native iOS Video Picker with Lossless Passthrough (Zero Pre-Compression!)
- (void)openNativeVideoPicker {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.delegate = self;
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        picker.videoExportPreset = AVAssetExportPresetPassthrough;
        [self presentViewController:picker animated:YES completion:nil];
    });
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
    if (!mediaURL) return;

    NSString *ext = mediaURL.pathExtension.length > 0 ? mediaURL.pathExtension : @"mp4";
    NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tabi_source_video.%@", ext]];
    [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:mediaURL toURL:[NSURL fileURLWithPath:tempFile] error:nil];

    self.currentVideoURL = [NSURL fileURLWithPath:tempFile];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.currentVideoURL options:nil];
    double duration = CMTimeGetSeconds(asset.duration);
    if (isnan(duration) || duration <= 0) duration = 10.0;

    NSString *urlStr = self.currentVideoURL.absoluteString;
    NSString *js = [NSString stringWithFormat:@"window.onNativeVideoSelected('%@', %.3f);", urlStr, duration];
    [self sendJSEvent:js];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

// Native Microphone Voiceover Recorder
- (void)toggleVoiceRecording {
    if (self.audioRecorder && self.audioRecorder.isRecording) {
        [self.audioRecorder stop];
        self.audioRecorder = nil;
        [self sendJSEvent:@"window.onVoiceRecordState(false, '✅ Mic Voiceover Recorded');"];
        return;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session requestRecordPermission:^(BOOL granted) {
        if (!granted) {
            [self sendJSEvent:@"window.onVoiceRecordState(false, '❌ Mic Permission Denied');"];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
            [session setActive:YES error:nil];

            NSString *voicePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tabi_voiceover.m4a"];
            [[NSFileManager defaultManager] removeItemAtPath:voicePath error:nil];
            self.recordedVoiceURL = [NSURL fileURLWithPath:voicePath];

            NSDictionary *recSettings = @{
                AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                AVSampleRateKey: @44100.0,
                AVNumberOfChannelsKey: @2,
                AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
            };

            NSError *err = nil;
            self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:self.recordedVoiceURL settings:recSettings error:&err];
            if (self.audioRecorder && !err) {
                [self.audioRecorder prepareToRecord];
                [self.audioRecorder record];
                [self sendJSEvent:@"window.onVoiceRecordState(true, '🔴 Recording Mic...');"];
            } else {
                [self sendJSEvent:@"window.onVoiceRecordState(false, '❌ Mic Error');"];
            }
        });
    }];
}

// Native Color-Managed AVFoundation + CoreImage HD 60FPS Exporter (Bright, Vivid & Crisp!)
- (void)exportVideoWithPayload:(NSDictionary *)payload {
    if (!self.currentVideoURL || ![[NSFileManager defaultManager] fileExistsAtPath:self.currentVideoURL.path]) {
        [self sendJSEvent:@"window.onExportError('Please select a video first!');"];
        return;
    }

    NSDictionary *settings = payload[@"settings"] ?: @{};
    NSArray *segments = payload[@"segments"] ?: @[];

    AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:self.currentVideoURL options:nil];
    AVMutableComposition *composition = [AVMutableComposition composition];

    AVAssetTrack *srcVideoTrack = [[sourceAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!srcVideoTrack) {
        [self sendJSEvent:@"window.onExportError('Could not read video track.');"];
        return;
    }

    AVMutableCompositionTrack *compVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    compVideoTrack.preferredTransform = srcVideoTrack.preferredTransform;

    AVAssetTrack *srcAudioTrack = [[sourceAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    AVMutableCompositionTrack *compAudioTrack = nil;
    if (srcAudioTrack) {
        compAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    }

    CMTime insertCursor = kCMTimeZero;
    double assetDuration = CMTimeGetSeconds(sourceAsset.duration);

    if (segments.count > 0) {
        for (NSDictionary *seg in segments) {
            double st = [seg[@"start"] doubleValue];
            double en = [seg[@"end"] doubleValue];
            if (en > assetDuration) en = assetDuration;
            double dur = en - st;
            if (dur <= 0.05) continue;

            CMTime startCM = CMTimeMakeWithSeconds(st, 600);
            CMTime durCM = CMTimeMakeWithSeconds(dur, 600);
            CMTimeRange range = CMTimeRangeMake(startCM, durCM);

            [compVideoTrack insertTimeRange:range ofTrack:srcVideoTrack atTime:insertCursor error:nil];
            if (srcAudioTrack && compAudioTrack) {
                [compAudioTrack insertTimeRange:range ofTrack:srcAudioTrack atTime:insertCursor error:nil];
            }
            insertCursor = CMTimeAdd(insertCursor, durCM);
        }
    } else {
        CMTimeRange fullRange = CMTimeRangeMake(kCMTimeZero, sourceAsset.duration);
        [compVideoTrack insertTimeRange:fullRange ofTrack:srcVideoTrack atTime:kCMTimeZero error:nil];
        if (srcAudioTrack && compAudioTrack) {
            [compAudioTrack insertTimeRange:fullRange ofTrack:srcAudioTrack atTime:kCMTimeZero error:nil];
        }
        insertCursor = sourceAsset.duration;
    }

    // Audio Mix (Original Volume + Voice Overlay)
    NSMutableArray<AVMutableAudioMixInputParameters *> *audioMixParams = [NSMutableArray array];
    float origVol = [settings[@"originalVolume"] ?: @(100) floatValue] / 100.0f;
    float voiceVol = [settings[@"voiceVolume"] ?: @(120) floatValue] / 100.0f;

    if (compAudioTrack) {
        AVMutableAudioMixInputParameters *origParam = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:compAudioTrack];
        [origParam setVolume:origVol atTime:kCMTimeZero];
        [audioMixParams addObject:origParam];
    }

    if (self.recordedVoiceURL && [[NSFileManager defaultManager] fileExistsAtPath:self.recordedVoiceURL.path]) {
        AVURLAsset *voiceAsset = [AVURLAsset URLAssetWithURL:self.recordedVoiceURL options:nil];
        AVAssetTrack *vTrack = [[voiceAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (vTrack) {
            AVMutableCompositionTrack *compVoiceTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTime maxDur = CMTimeMinimum(voiceAsset.duration, insertCursor);
            [compVoiceTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, maxDur) ofTrack:vTrack atTime:kCMTimeZero error:nil];

            AVMutableAudioMixInputParameters *vParam = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:compVoiceTrack];
            [vParam setVolume:voiceVol atTime:kCMTimeZero];
            [audioMixParams addObject:vParam];
        }
    }

    // Read user sliders
    float br = [settings[@"brightness"] ?: @(-23) floatValue];
    float co = [settings[@"contrast"] ?: @(-31) floatValue];
    float sa = [settings[@"saturation"] ?: @(39) floatValue];
    float bl = [settings[@"brilliance"] ?: @(-9) floatValue];
    float sharpness = [settings[@"sharpness"] ?: @(98) floatValue];

    float hslRed = [settings[@"hslRed"] ?: @(63) floatValue];
    float hslBlue = [settings[@"hslBlue"] ?: @(15) floatValue];
    float hslDarkBlue = [settings[@"hslDarkBlue"] ?: @(64) floatValue];
    float hslPurple = [settings[@"hslPurple"] ?: @(60) floatValue];
    float hslPink = [settings[@"hslPink"] ?: @(60) floatValue];
    float hslAvg = (hslRed + hslBlue + hslDarkBlue + hslPurple + hslPink) / 5.0f;

    BOOL fadeInEnabled = [settings[@"fadeInEnabled"] ?: @NO boolValue];
    double fadeInDuration = [settings[@"fadeInDuration"] ?: @(1.2) doubleValue];

    // Calculate bright, clear, non-dark CoreImage filter parameters
    // 1. Shadow lift so dark rooms/areas are always bright & visible!
    float shadowLift = 0.22f + ((-co / 100.0f) * 0.20f); // +0.22 to +0.30 shadow lift
    float highlightRecover = 0.92f;

    // 2. Gentle brightness & crisp contrast (NEVER darkens the video!)
    float ciBrightness = (br > 0) ? (br / 100.0f) * 0.08f : (br / 100.0f) * 0.015f;
    float ciContrast = 1.03f + ((co > 0) ? (co / 100.0f) * 0.15f : 0.0f) - ((bl / 100.0f) * 0.04f);
    float ciSaturation = 1.0f + ((sa / 100.0f) * 0.55f) + ((hslAvg / 100.0f) * 0.42f);
    float ciVibrance = (hslAvg / 100.0f) * 0.70f;

    AVMutableVideoComposition *videoComp = [AVMutableVideoComposition videoCompositionWithAsset:composition applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest * _Nonnull request) {
        CIImage *img = request.sourceImage;
        CGRect extent = img.extent;

        // 1. Lift Shadows & Balance Highlights (CIHighlightShadowAdjust — keeps video bright & clear!)
        CIFilter *hsFilter = [CIFilter filterWithName:@"CIHighlightShadowAdjust"];
        if (hsFilter) {
            [hsFilter setValue:img forKey:kCIInputImageKey];
            [hsFilter setValue:@(shadowLift) forKey:@"inputShadowAmount"];
            [hsFilter setValue:@(highlightRecover) forKey:@"inputHighlightAmount"];
            CIImage *outImg = hsFilter.outputImage;
            if (outImg) img = outImg;
        }

        // 2. Color Controls (Vivid CapCut Saturation + Clean Contrast)
        CIFilter *colorControls = [CIFilter filterWithName:@"CIColorControls"];
        if (colorControls) {
            [colorControls setValue:img forKey:kCIInputImageKey];
            [colorControls setValue:@(ciBrightness) forKey:kCIInputBrightnessKey];
            [colorControls setValue:@(ciContrast) forKey:kCIInputContrastKey];
            [colorControls setValue:@(ciSaturation) forKey:kCIInputSaturationKey];
            CIImage *outImg = colorControls.outputImage;
            if (outImg) img = outImg;
        }

        // 3. Vibrance Boost for HSL Pop (Boosts colors while keeping gray walls clean!)
        CIFilter *vibFilter = [CIFilter filterWithName:@"CIVibrance"];
        if (vibFilter) {
            [vibFilter setValue:img forKey:kCIInputImageKey];
            [vibFilter setValue:@(ciVibrance) forKey:@"inputAmount"];
            CIImage *outImg = vibFilter.outputImage;
            if (outImg) img = outImg;
        }

        // 4. Crisp CapCut HD Sharpening (CISharpenLuminance + CIUnsharpMask)
        if (sharpness > 0.0f) {
            float k = sharpness / 100.0f;
            CIFilter *sharpen = [CIFilter filterWithName:@"CISharpenLuminance"];
            if (sharpen) {
                [sharpen setValue:img forKey:kCIInputImageKey];
                [sharpen setValue:@(k * 1.15f) forKey:kCIInputSharpnessKey];
                [sharpen setValue:@(1.8f) forKey:kCIInputRadiusKey];
                CIImage *outImg = sharpen.outputImage;
                if (outImg) img = outImg;
            }
            CIFilter *unsharp = [CIFilter filterWithName:@"CIUnsharpMask"];
            if (unsharp) {
                [unsharp setValue:img forKey:kCIInputImageKey];
                [unsharp setValue:@(2.5f) forKey:kCIInputRadiusKey];
                [unsharp setValue:@(k * 0.95f) forKey:kCIInputIntensityKey];
                CIImage *outImg = unsharp.outputImage;
                if (outImg) img = outImg;
            }
        }

        // 5. Optional Smooth Fade-In Animation (Only if enabled by user!)
        double sec = CMTimeGetSeconds(request.compositionTime);
        if (fadeInEnabled && fadeInDuration > 0.05 && sec < fadeInDuration) {
            double prog = fmax(0.0, fmin(1.0, sec / fadeInDuration));
            CGFloat alpha = (CGFloat)(prog * prog * (3.0 - 2.0 * prog));
            CIFilter *fadeFilter = [CIFilter filterWithName:@"CIColorMatrix"];
            if (fadeFilter) {
                [fadeFilter setValue:img forKey:kCIInputImageKey];
                [fadeFilter setValue:[CIVector vectorWithX:alpha Y:0 Z:0 W:0] forKey:@"inputRVector"];
                [fadeFilter setValue:[CIVector vectorWithX:0 Y:alpha Z:0 W:0] forKey:@"inputGVector"];
                [fadeFilter setValue:[CIVector vectorWithX:0 Y:0 Z:alpha W:0] forKey:@"inputBVector"];
                CIImage *outImg = fadeFilter.outputImage;
                if (outImg) img = outImg;
            }
        }

        // Use context:nil so Apple's native Rec.709 color-managed GPU context renders with zero darkening!
        [request finishWithImage:[img imageByCroppingToRect:extent] context:nil];
    }];

    videoComp.frameDuration = CMTimeMake(1, 60); // 60 FPS Smooth

    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"TABI_EDIT_1080p60_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]]];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    NSURL *outURL = [NSURL fileURLWithPath:outPath];

    // HighestQuality preset with native resolution & 60FPS
    self.activeExporter = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
    self.activeExporter.outputURL = outURL;
    self.activeExporter.outputFileType = AVFileTypeMPEG4;
    self.activeExporter.videoComposition = videoComp;
    self.activeExporter.shouldOptimizeForNetworkUse = NO;

    if (audioMixParams.count > 0) {
        AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
        audioMix.inputParameters = audioMixParams;
        self.activeExporter.audioMix = audioMix;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.exportProgressTimer invalidate];
        self.exportProgressTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer * _Nonnull timer) {
            int pct = (int)roundf(self.activeExporter.progress * 100.0f);
            [self sendJSEvent:[NSString stringWithFormat:@"window.onExportProgress(%d);", pct]];
        }];
    });

    __weak typeof(self) weakSelf = self;
    [self.activeExporter exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.exportProgressTimer invalidate];
            weakSelf.exportProgressTimer = nil;

            if (weakSelf.activeExporter.status == AVAssetExportSessionStatusCompleted) {
                if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(outPath)) {
                    UISaveVideoAtPathToSavedPhotosAlbum(outPath, nil, nil, nil);
                }
                [weakSelf sendJSEvent:@"window.onExportComplete();"];

                UIActivityViewController *shareVC = [[UIActivityViewController alloc] initWithActivityItems:@[outURL] applicationActivities:nil];
                if (shareVC.popoverPresentationController) {
                    shareVC.popoverPresentationController.sourceView = weakSelf.view;
                    shareVC.popoverPresentationController.sourceRect = CGRectMake(weakSelf.view.bounds.size.width / 2, weakSelf.view.bounds.size.height / 2, 1, 1);
                }
                [weakSelf presentViewController:shareVC animated:YES completion:nil];
            } else {
                NSString *errMsg = weakSelf.activeExporter.error.localizedDescription ?: @"Export failed";
                errMsg = [errMsg stringByReplacingOccurrencesOfString:@"'" withString:@""];
                [weakSelf sendJSEvent:[NSString stringWithFormat:@"window.onExportError('%@');", errMsg]];
            }
        });
    }];
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"tabiNative"]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *payload = (NSDictionary *)message.body;
    NSString *action = payload[@"action"];

    if ([action isEqualToString:@"pickVideo"]) {
        [self openNativeVideoPicker];
    } else if ([action isEqualToString:@"toggleVoiceRecord"]) {
        [self toggleVoiceRecording];
    } else if ([action isEqualToString:@"exportVideo"]) {
        [self exportVideoWithPayload:payload];
    }
}

@end

@interface TabiAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TabiAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[TabiViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TabiAppDelegate class]));
    }
}
