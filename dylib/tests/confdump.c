// Prints what the reader makes of a fixture tree, in the normalised form from
// conf-format.md, so dylib/tests/conf-fixtures/EXPECTED can judge it the same way it
// judges compat_run.sh.
#include "../feats/conf.h"

#include <stdio.h>

static void print_tsv(const char *a, const char *b, const char *c, const char *detail) {
    printf("%s\t%s\t%s%s%s\n", a, b, c, detail ? ":" : "", detail ? detail : "");
}

static const char *on_record(const np_conf_rec_t *rec, void *ctx, const char **detail) {
    const char *n, *v;
    int it = 0;
    (void)ctx;
    (void)detail;
    while (np_conf_next(rec, &it, &n, &v))
        print_tsv(rec->id, n, v, NULL);
    return NULL;
}

static void on_refused(const char *scope, const char *code, const char *detail, void *ctx) {
    (void)ctx;
    print_tsv("!", scope, code, detail);
}

static void on_file(const char *path, void *ctx) {
    (void)ctx;
    printf("== %s\n", path);
}

int main(int argc, char **argv) {
    const np_conf_sink_t sink = { on_record, on_refused, on_file };
    char dir[2048];
    if (argc != 2) { fprintf(stderr, "usage: confdump <fixture-root>\n"); return 2; }
    for (int i = 0; i < 2; i++) {
        const char *name = i ? "variants" : "plugins";
        snprintf(dir, sizeof(dir), "%s/%s", argv[1], name);
        np_conf_read_dir(dir, name, i ? NP_CONF_VARIANT : NP_CONF_PLUGIN, &sink, NULL);
    }
    return 0;
}
