#include "compatpage.h"
#include "compat.h"
#include "defaults.h"
#include "webpatch.h"
#include "../util/log.h"

#include <stdlib.h>

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
    np_webpatch_set_builds(builds, n);
    free(own);
}

void np_compatpage_publish(const uint8_t *src, size_t len) {
    np_webpatch_set_fallback_tool(np_compat_fallback_tool_name());
    const char *fex[NP_WEBPATCH_FEX_TOOLS_MAX];
    np_webpatch_set_fex_tools(fex, np_compat_fex_tools(fex, NP_WEBPATCH_FEX_TOOLS_MAX));
    if (np_webpatch_has_shape(src, len)) publish_defaults();
}
