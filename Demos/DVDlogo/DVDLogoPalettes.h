#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Registers the Retro DVD Logo palettes with the shared palette manager (idempotent).
void DVDRegisterRetroPalettes(void);

/// Returns the identifier of the default palette for the Retro DVD Logo saver.
NSString *DVDDefaultPaletteIdentifier(void);

/// Module identifier used when requesting palettes from the shared palette manager.
NSString *DVDPaletteModuleIdentifier(void);

NS_ASSUME_NONNULL_END
