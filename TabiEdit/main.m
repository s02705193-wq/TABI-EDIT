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

    // Clear any cached webview assets on launch so new IPA updates always load fresh
    NSSet *websiteDataTypes = [WKWebsiteDataStore allWebsiteDataTypes];
    [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:websiteDataTypes modifiedSince:[NSDate dateWithTimeIntervalSince1970:0] completionHandler:^{}];

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

// Native Bright HD Exporter (Zero Darkness + Zero Pixel Tearing!)
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
    float sa = [settings[@"saturation"] ?: @(39) floatValue];
    float sharpness = [settings[@"sharpness"] ?: @(98) floatValue];

    float hslRed = [settings[@"hslRed"] ?: @(63) floatValue];
    float hslBlue = [settings[@"hslBlue"] ?: @(15) floatValue];
    float hslDarkBlue = [settings[@"hslDarkBlue"] ?: @(64) floatValue];
    float hslPurple = [settings[@"hslPurple"] ?: @(60) floatValue];
    float hslPink = [settings[@"hslPink"] ?: @(60) floatValue];
    float hslAvg = (hslRed + hslBlue + hslDarkBlue + hslPurple + hslPink) / 5.0f;

    BOOL fadeInEnabled = [settings[@"fadeInEnabled"] ?: @NO boolValue];
    double fadeInDuration = [settings[@"fadeInDuration"] ?: @(1.2) doubleValue];

    // BRIGHT HD PARAMETERS:
    // 1. Gamma < 1.0 (0.85) + Exposure +0.16 EV ALWAYS brightens midtones & shadows so video is NEVER dark!
    float gammaPower = 0.85f - ((br > 0 ? br : 0) / 100.0f) * 0.12f;
    float exposureEV = 0.16f + ((br > 0 ? br : 0) / 100.0f) * 0.25f;

    // 2. Saturation & Vibrance (Clean, vivid CapCut colors without darkening!)
    float ciSaturation = 1.0f + ((sa / 100.0f) * 0.38f) + ((hslAvg / 100.0f) * 0.28f);
    float ciVibrance = (hslAvg / 100.0f) * 0.45f;

    // 3. Smooth, Tear-Free Sharpening (Single gentle CIUnsharpMask at 0.30 max intensity — ZERO pixel tearing!)
    float unsharpIntensity = (sharpness / 100.0f) * 0.30f;

    AVMutableVideoComposition *videoComp = [AVMutableVideoComposition videoCompositionWithAsset:composition applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest * _Nonnull request) {
        CIImage *img = request.sourceImage;
        CGRect extent = img.extent;

        // Step 1: Brighten Midtones & Shadows with CIGammaAdjust (power < 1.0 = BRIGHTER!)
        CIFilter *gammaFilter = [CIFilter filterWithName:@"CIGammaAdjust"];
        if (gammaFilter) {
            [gammaFilter setValue:img forKey:kCIInputImageKey];
            [gammaFilter setValue:@(gammaPower) forKey:@"inputPower"];
            CIImage *outImg = gammaFilter.outputImage;
            if (outImg) img = outImg;
        }

        // Step 2: Clean Exposure Lift (CIExposureAdjust +0.16 EV)
        CIFilter *expFilter = [CIFilter filterWithName:@"CIExposureAdjust"];
        if (expFilter) {
            [expFilter setValue:img forKey:kCIInputImageKey];
            [expFilter setValue:@(exposureEV) forKey:kCIInputEVKey];
            CIImage *outImg = expFilter.outputImage;
            if (outImg) img = outImg;
        }

        // Step 3: Vivid Saturation (CIColorControls with brightness = +0.02, contrast = 1.0)
        CIFilter *colorControls = [CIFilter filterWithName:@"CIColorControls"];
        if (colorControls) {
            [colorControls setValue:img forKey:kCIInputImageKey];
            [colorControls setValue:@(0.02f) forKey:kCIInputBrightnessKey];
            [colorControls setValue:@(1.00f) forKey:kCIInputContrastKey];
            [colorControls setValue:@(ciSaturation) forKey:kCIInputSaturationKey];
            CIImage *outImg = colorControls.outputImage;
            if (outImg) img = outImg;
        }

        // Step 4: Vibrance Boost for HSL Colors
        CIFilter *vibFilter = [CIFilter filterWithName:@"CIVibrance"];
        if (vibFilter) {
            [vibFilter setValue:img forKey:kCIInputImageKey];
            [vibFilter setValue:@(ciVibrance) forKey:@"inputAmount"];
            CIImage *outImg = vibFilter.outputImage;
            if (outImg) img = outImg;
        }

        // Step 5: Smooth Noise Clean + Tear-Free Gentle Unsharp Mask (No CISharpenLuminance halo tearing!)
        if (unsharpIntensity > 0.01f) {
            CIFilter *denoise = [CIFilter filterWithName:@"CINoiseReduction"];
            if (denoise) {
                [denoise setValue:img forKey:kCIInputImageKey];
                [denoise setValue:@(0.012f) forKey:@"inputNoiseLevel"];
                [denoise setValue:@(0.45f) forKey:kCIInputSharpnessKey];
                CIImage *outImg = denoise.outputImage;
                if (outImg) img = outImg;
            }
            CIFilter *unsharp = [CIFilter filterWithName:@"CIUnsharpMask"];
            if (unsharp) {
                [unsharp setValue:img forKey:kCIInputImageKey];
                [unsharp setValue:@(1.5f) forKey:kCIInputRadiusKey];
                [unsharp setValue:@(unsharpIntensity) forKey:kCIInputIntensityKey];
                CIImage *outImg = unsharp.outputImage;
                if (outImg) img = outImg;
            }
        }

        // Step 6: Optional Fade-In Animation (Only if enabled by user)
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

        [request finishWithImage:[img imageByCroppingToRect:extent] context:nil];
    }];

    // Preserve explicit Rec.709 HD Color Space so iOS never crushes gamma!
    videoComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2;
    videoComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2;
    videoComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2;

    // Match source frame rate so H.264 encoder allocates maximum bits per frame (prevents pixel tearing!)
    float srcFps = srcVideoTrack.nominalFrameRate;
    int targetFps = (srcFps >= 24.0f && srcFps <= 60.0f) ? (int)roundf(srcFps) : 30;
    videoComp.frameDuration = CMTimeMake(1, targetFps);

    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"TABI_EDIT_HD_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]]];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    NSURL *outURL = [NSURL fileURLWithPath:outPath];

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
