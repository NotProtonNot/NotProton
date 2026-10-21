// The payload is a macro, so the unit under test is included rather than linked.
// Both forms come from one body, which is what makes the checks that run against
// this output speak for both page shapes at once.
#include "../../feats/webpatch.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

char *np_nativeplatform_javascript(void) {
    return NULL;
}

static void put_panel(const char *body) {
    for (const char *p = body; *p; p++) {
        const char *text = marker_text(*p);
        if (text) fputs(text, stdout);
        else putchar(*p);
    }
}

int main(int argc, char **argv) {
    if (argc >= 2 && (strcmp(argv[1], "component") == 0 || strcmp(argv[1], "statement") == 0)) {
        np_webpatch_set_fallback_tool(argc >= 3 ? argv[2] : NULL);
        np_webpatch_set_fex_tools((const char *const *)argv + 3,
                                  argc > 3 ? (size_t)(argc - 3) : 0);
        np_webpatch_set_features(getenv("NP_TEST_READY"), getenv("NP_TEST_FEATS"));
        np_webpatch_set_variants(getenv("NP_TEST_VARS"));
        put_panel(strcmp(argv[1], "component") == 0 ? NP_CX_OPTIONS_COMPONENT
                                                    : NP_CX_OPTIONS_STATEMENT);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "migration") == 0) {
        fputs(NP_LAUNCH_MIGRATION, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "compat-hint") == 0) {
        fputs(NP_COMPAT_HINT, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "image-files-label") == 0) {
        fputs(NP_IMAGE_FILES_LABEL, stdout);
        return 0;
    }
    fputs("usage: emit component|statement [fallback [fex-tool...]]|migration|compat-hint|"
          "image-files-label\n", stderr);
    return 2;
}
