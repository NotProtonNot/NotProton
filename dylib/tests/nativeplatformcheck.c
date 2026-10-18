#include "../feats/nativeplatform.h"
#include "../util/file.h"
#include "../util/log.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int   np_log_level = -1;
FILE *np_log_file;

static int g_wrong;
static char g_tool[PATH_MAX];

static void helper(const char *script) {
    unlink(g_tool);
    if (!script) return;
    FILE *f = fopen(g_tool, "w");
    if (!f) { printf("WRONG: cannot write %s\n", g_tool); g_wrong = 1; return; }
    fprintf(f, "#!/bin/sh\n%s\n", script);
    fclose(f);
    chmod(g_tool, 0755);
}

static void expect(const char *what, const char *script, const char *want) {
    helper(script);
    char *got = np_nativeplatform_javascript();
    if (want ? !got || strcmp(got, want) != 0 : got != NULL) {
        printf("WRONG: %s gave %s\n", what, got ? got : "nothing");
        g_wrong = 1;
    }
    free(got);
}

int main(void) {
    char home[] = "/tmp/np-nativeplatform-XXXXXX";
    if (!mkdtemp(home)) { perror("mkdtemp"); return 1; }
    setenv("HOME", home, 1);
    np_support_path(g_tool, sizeof(g_tool), home, "appinfo");
    char dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/Library", home);
    mkdir(dir, 0755);
    snprintf(dir, sizeof(dir), "%s/Library/Application Support", home);
    mkdir(dir, 0755);
    snprintf(dir, sizeof(dir), "%s", g_tool);
    *strrchr(dir, '/') = '\0';
    mkdir(dir, 0755);

    expect("two lists", "[ \"$2\" = --platforms ] || exit 2\nprintf 'mac=20,30\\nwindows=10\\n'",
           "window.__NOTPROTON_NATIVE_PLATFORM__={mac:new Set([20,30]),windows:new Set([10])};\n");
    expect("empty lists", "printf 'mac=\\nwindows=\\n'",
           "window.__NOTPROTON_NATIVE_PLATFORM__={mac:new Set([]),windows:new Set([])};\n");
    expect("no helper", NULL, NULL);
    expect("a helper that fails", "printf 'mac=1\\nwindows=2\\n'; exit 1", NULL);
    expect("script in a list", "printf 'mac=1,2]);alert(1);//\\nwindows=\\n'", NULL);
    expect("a trailing comma", "printf 'mac=1,\\nwindows=2\\n'", NULL);
    expect("a swapped order", "printf 'windows=2\\nmac=1\\n'", NULL);
    expect("an extra line", "printf 'mac=1\\nwindows=2\\nlinux=3\\n'", NULL);
    expect("no newline at the end", "printf 'mac=1\\nwindows=2'", NULL);
    expect("a helper that stalls after closing stdout",
           "printf 'mac=1\\nwindows=2\\n'; exec 1>&-; exec /bin/sleep 3", NULL);
    expect("a helper that stalls without output", "exec /bin/sleep 3", NULL);

    helper(NULL);
    rmdir(dir);
    snprintf(dir, sizeof(dir), "%s/Library/Application Support", home);
    rmdir(dir);
    snprintf(dir, sizeof(dir), "%s/Library", home);
    rmdir(dir);
    rmdir(home);
    if (!g_wrong) printf("==> nativeplatform: helper output checked, bad output refused\n");
    return g_wrong;
}
