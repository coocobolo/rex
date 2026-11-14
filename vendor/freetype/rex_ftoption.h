/* FreeType build configuration for Rex, layered over upstream ftoption.h.
 * Re-enable any disabled feature by removing its `#undef` line below (and, for
 * WOFF1/compressed fonts, uncommenting `"src/gzip/ftgzip.c"` in build.zig). */
#include <freetype/config/ftoption.h>

#define FT_CONFIG_OPTION_USE_PNG
/* Pair kerning from GPOS for UI fonts that have no legacy `kern` table. */
#define TT_CONFIG_OPTION_GPOS_KERNING

/* Disable compressed stream/WOFF1 tables (uses bundled inflate unless
 * FT_CONFIG_OPTION_SYSTEM_ZLIB is also defined). */
#undef FT_CONFIG_OPTION_USE_ZLIB
/* Disable the 56 KiB Adobe Glyph List table; only synthesizes Unicode cmaps
 * from PostScript glyph names on fonts that lack a `cmap` table. */
#undef FT_CONFIG_OPTION_ADOBE_GLYPH_LIST
/* Disable OT-SVG hooks (svg module is omitted). */
#undef FT_CONFIG_OPTION_SVG
/* Disable embedded BDF property support inside SFNT. */
#undef TT_CONFIG_OPTION_BDF
