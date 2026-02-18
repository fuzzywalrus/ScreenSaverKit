#import "SSKShaderLoader.h"
#import "SSKDiagnostics.h"

@implementation SSKShaderLoader

+ (nullable id<MTLLibrary>)loadLibraryNamed:(NSString *)name
                                     device:(id<MTLDevice>)device
                                     bundle:(NSBundle *)bundle {
    NSParameterAssert(name.length > 0);
    NSParameterAssert(device);
    NSParameterAssert(bundle);

    // 1. Try precompiled metallib from bundle resources.
    NSString *metallibPath = [bundle pathForResource:name ofType:@"metallib"];
    NSError *error = nil;
    if (metallibPath.length > 0) {
        NSURL *metallibURL = [NSURL fileURLWithPath:metallibPath];
        id<MTLLibrary> library = [device newLibraryWithURL:metallibURL error:&error];
        if (library) {
            return library;
        }
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKShaderLoader: failed to load %@.metallib at %@ (%@).",
             name, metallibPath, error.localizedDescription ?: @"unknown error"];
        }
    }

    // 2. Locate .metal source file — bundle resources, then walk upward, then cwd.
    NSString *metalSourcePath = [bundle pathForResource:name ofType:@"metal"];
    if (!metalSourcePath) {
        NSString *relativePath = [NSString stringWithFormat:@"ScreenSaverKit/Shaders/%@.metal", name];
        NSString *probe = bundle.bundlePath;
        for (NSUInteger i = 0; i < 5 && probe.length > 1; i++) {
            NSString *candidate = [probe stringByAppendingPathComponent:relativePath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                metalSourcePath = candidate;
                break;
            }
            probe = [probe stringByDeletingLastPathComponent];
        }
        if (!metalSourcePath) {
            NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
            NSString *candidate = [cwd stringByAppendingPathComponent:relativePath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                metalSourcePath = candidate;
            }
        }
    }

    if (metalSourcePath.length == 0) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKShaderLoader: %@ source not found; cannot compile fallback library.", name];
        }
        return nil;
    }

    // 3. Compile from source.
    NSError *readError = nil;
    NSString *source = [NSString stringWithContentsOfFile:metalSourcePath encoding:NSUTF8StringEncoding error:&readError];
    if (!source) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKShaderLoader: failed to read %@ source at %@ (%@).",
             name, metalSourcePath, readError.localizedDescription ?: @"unknown error"];
        }
        return nil;
    }
    error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKShaderLoader: failed to compile %@ source at %@ (%@).",
         name, metalSourcePath, error.localizedDescription ?: @"unknown error"];
    }
    return library;
}

@end
