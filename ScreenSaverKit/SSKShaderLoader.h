#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads Metal shader libraries from precompiled metallib bundles or source files.
/// Centralizes the fallback chain: metallib → walk upward → cwd → compile from source.
@interface SSKShaderLoader : NSObject

/// Loads a Metal shader library by name, searching the bundle for a precompiled
/// metallib first, then falling back to compiling the .metal source file.
///
/// @param name      Base name of the shader (e.g. @"SSKParticleShaders").
/// @param device    Metal device to create the library on.
/// @param bundle    Bundle to search for resources.
/// @return The loaded library, or nil if all fallback paths fail.
+ (nullable id<MTLLibrary>)loadLibraryNamed:(NSString *)name
                                     device:(id<MTLDevice>)device
                                     bundle:(NSBundle *)bundle;

@end

NS_ASSUME_NONNULL_END
