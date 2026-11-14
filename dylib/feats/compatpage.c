#include "compatpage.h"
#include "compat.h"
#include "defaults.h"
#include "machine.h"
#include "tuning.h"
#include "webpatch.h"
#include "../util/log.h"

#include <stdlib.h>

// What this Mac asks for, which the page offers as one button beside the settings it
// writes. A runner whose set could not be worked out is passed as NULL, and the row for
// it stays off the page rather than offering settings nothing stands behind.
static void publish_tuning(void) {
    const np_machine_t *m = np_machine();
    char rosetta[NP_DEFAULTS_TEXT_MAX + 1], fex[NP_DEFAULTS_TEXT_MAX + 1], mac[256];
    int has_rosetta = np_tuning_recommend(m, NP_DEFAULTS_ROSETTA, rosetta, sizeof rosetta);
    int has_fex = np_tuning_recommend(m, NP_DEFAULTS_FEX, fex, sizeof fex);
    np_machine_summary(m, mac, sizeof mac);
    np_webpatch_set_tuning(has_rosetta ? rosetta : NULL, has_fex ? fex : NULL, mac);
}

static void publish_defaults(void) {
    char rosetta[NP_DEFAULTS_TEXT_MAX + 1], fex[NP_DEFAULTS_TEXT_MAX + 1];
    int read = np_defaults_read(NP_DEFAULTS_ROSETTA, rosetta, sizeof rosetta);
    read &= np_defaults_read(NP_DEFAULTS_FEX, fex, sizeof fex);

    np_compat_tool_info_t tools[NP_WEBPATCH_BUILDS_MAX];
    size_t count = np_compat_tools(tools, NP_WEBPATCH_BUILDS_MAX);
    char (*own)[NP_DEFAULTS_TEXT_MAX + 1] = count ? malloc(count * sizeof *own) : NULL;
    np_webpatch_build_t builds[NP_WEBPATCH_BUILDS_MAX];
    size_t n = 0;
    if (count && !own) read = 0;
    for (size_t i = 0; own && i < count; i++) {
        uint32_t runner = tools[i].fex ? NP_DEFAULTS_FEX : NP_DEFAULTS_ROSETTA;
        int has = np_defaults_read_build(tools[i].build, runner, own[i], sizeof own[i]);
        if (has < 0) {
            NP_WARN("webpatch: %s's own settings cannot be read, so the Settings page leaves it out", tools[i].name);
            continue;
        }
        builds[n++] = (np_webpatch_build_t){ tools[i].name, tools[i].build, tools[i].display,
                                             tools[i].fex, has > 0 ? own[i] : NULL };
    }
    if (read) np_webpatch_set_defaults(rosetta, fex);
    else np_webpatch_set_defaults(NULL, NULL);
    publish_tuning();
    np_webpatch_set_builds(builds, n);
    free(own);
}

void np_compatpage_publish(const uint8_t *src, size_t len) {
    np_webpatch_set_fallback_tool(np_compat_fallback_tool_name());
    const char *fex[NP_WEBPATCH_FEX_TOOLS_MAX];
    np_webpatch_set_fex_tools(fex, np_compat_fex_tools(fex, NP_WEBPATCH_FEX_TOOLS_MAX));
    const char *tools[NP_WEBPATCH_BUILDS_MAX], *builds[NP_WEBPATCH_BUILDS_MAX];
    const char *archs[NP_WEBPATCH_BUILDS_MAX];
    np_webpatch_set_tool_builds(tools, builds, archs,
        np_compat_tool_builds(tools, builds, archs, NP_WEBPATCH_BUILDS_MAX));
    if (np_webpatch_has_shape(src, len)) publish_defaults();
}
