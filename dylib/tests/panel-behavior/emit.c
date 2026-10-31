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

static void set_sample_data(void) {
    np_webpatch_set_defaults("MTL_HUD_ENABLED=1\nNOT A LINE\n", "WINEMSYNC=1\nX=\"});\n");
    const np_webpatch_build_t builds[] = {
        { "notproton-26.1", "26.1", "CrossOver 26.1", 0, NULL },
        { "notproton-26.1-fex", "26.1", "CrossOver 26.1 (FEX)", 1, "WINEMSYNC=0\n" },
        { "notproton-evil", "26.2", "Evil\"});alert(1);({", 0, NULL },
        { "notproton-empty", "25.0", "CrossOver 25", 0, "" },
    };
    np_webpatch_set_builds(builds, sizeof builds / sizeof builds[0]);
}

int main(int argc, char **argv) {
    const char *form = argc >= 2 ? argv[1] : "";
    int data = strcmp(form, "component-data") == 0 || strcmp(form, "statement-data") == 0;
    if (data || strcmp(form, "component") == 0 || strcmp(form, "statement") == 0) {
        np_webpatch_set_fallback_tool(argc >= 3 ? argv[2] : NULL);
        np_webpatch_set_fex_tools((const char *const *)argv + 3,
                                  argc > 3 ? (size_t)(argc - 3) : 0);
        if (data) set_sample_data();
        // NP_TEST_TOOLS is the set NotProton installed: the panel is only for those.
        const char *ours[NP_WEBPATCH_FEX_TOOLS_MAX];
        char tools[1024];
        size_t nours = 0;
        snprintf(tools, sizeof(tools), "%s", getenv("NP_TEST_TOOLS") ? getenv("NP_TEST_TOOLS") : "");
        for (char *tok = strtok(tools, ","); tok && nours < NP_WEBPATCH_FEX_TOOLS_MAX;
             tok = strtok(NULL, ","))
            ours[nours++] = tok;
        np_webpatch_set_tool_builds(ours, ours, ours, nours);
        np_webpatch_set_features(getenv("NP_TEST_READY"), getenv("NP_TEST_FEATS"));
        np_webpatch_set_variants(getenv("NP_TEST_VARS"));
        put_panel(strncmp(form, "component", 9) == 0 ? NP_CX_OPTIONS_COMPONENT
                                                     : NP_CX_OPTIONS_STATEMENT);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "barrel-names") == 0) {
        static const char *const names[] = NP_CX_BARREL_NAMES;
        for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) puts(names[i]);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "prefix-row") == 0) {
        fputs(NP_CX_PREFIX_ROW, stdout);
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
    if (argc == 2 && strcmp(argv[1], "library-windows-hint") == 0) {
        fputs(NP_LIBRARY_WINDOWS_HINT, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "library-windows-summary") == 0) {
        fputs(NP_LIBRARY_WINDOWS_SUMMARY, stdout);
        return 0;
    }
    fputs("usage: emit component|statement[-data] [fallback [fex-tool...]]|migration|compat-hint|"
          "image-files-label|library-windows-hint|library-windows-summary|prefix-row|barrel-names\n",
          stderr);
    return 2;
}
