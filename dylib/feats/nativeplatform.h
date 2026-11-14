// Mac and Windows app lists for the Steam macOS library filter
#ifndef NOTPROTON_FEATS_NATIVEPLATFORM_H
#define NOTPROTON_FEATS_NATIVEPLATFORM_H

char *np_nativeplatform_javascript(void);

// "appid mac deck anticheat" lines for every game in appinfo.vdf, or NULL. Caller frees.
char *np_nativeplatform_compat(void);

#endif // NOTPROTON_FEATS_NATIVEPLATFORM_H
