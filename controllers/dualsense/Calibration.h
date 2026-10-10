#import <Foundation/Foundation.h>
#include <math.h>
// Gain for the Core Haptics envelope conversion.
static float DSBPCMGain(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    id s = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    if (![s isKindOfClass:NSDictionary.class] || ![s[@"version"] isEqual:@1] ||
        ![s[@"pcmGain"] isKindOfClass:NSNumber.class]) {
        return 1;
    }
    double g = [s[@"pcmGain"] doubleValue];
    return isfinite(g) && g >= .25 && g <= 4 ? (float)g : 1;
}
static float DSBCalibratedPCM(float sample, float gain) {
    return fmaxf(0, fminf(1, sample * gain));
}
