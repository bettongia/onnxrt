//
//  Generated file. Do not edit.
//

// clang-format off

#import "GeneratedPluginRegistrant.h"

#if __has_include(<betto_onnxrt_ios/BettoOnnxrtIosPlugin.h>)
#import <betto_onnxrt_ios/BettoOnnxrtIosPlugin.h>
#else
@import betto_onnxrt_ios;
#endif

#if __has_include(<integration_test/IntegrationTestPlugin.h>)
#import <integration_test/IntegrationTestPlugin.h>
#else
@import integration_test;
#endif

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
  [BettoOnnxrtIosPlugin registerWithRegistrar:[registry registrarForPlugin:@"BettoOnnxrtIosPlugin"]];
  [IntegrationTestPlugin registerWithRegistrar:[registry registrarForPlugin:@"IntegrationTestPlugin"]];
}

@end
