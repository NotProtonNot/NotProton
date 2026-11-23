#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static void str(FILE *f, const char *s, size_t n) {
    fputc('"', f);
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') fprintf(f, "\\%c", c);
        else if (c < 0x20) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}

int main(int argc, char **argv) {
    const char *out = getenv("NP_PROBE_OUT");
    char cwd[4096];
    FILE *f;
    if (!out || !getcwd(cwd, sizeof cwd) || !(f = fopen(out, "a"))) return 1;
    fputs("{\"argv\":[", f);
    for (int i = 1; i < argc; i++) {
        if (i > 1) fputc(',', f);
        str(f, argv[i], strlen(argv[i]));
    }
    fputs("],\"env\":{", f);
    int n = 0;
    for (char **e = environ; *e; e++) {
        const char *eq = strchr(*e, '=');
        if (!eq) continue;
        if (n++) fputc(',', f);
        str(f, *e, (size_t)(eq - *e));
        fputc(':', f);
        str(f, eq + 1, strlen(eq + 1));
    }
    fputs("},\"cwd\":", f);
    str(f, cwd, strlen(cwd));
    fputs("}\n", f);
    return fclose(f) ? 1 : 0;
}
