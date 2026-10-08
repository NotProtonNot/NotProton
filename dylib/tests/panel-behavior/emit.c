// The payload is a macro, so the unit under test is included rather than linked.
// Both forms come from one body, which is what makes the checks that run against
// this output speak for both page shapes at once.
#include "../../feats/webpatch.c"

#include <stdio.h>
#include <string.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "component") == 0) {
        fputs(NP_CX_OPTIONS_COMPONENT, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "statement") == 0) {
        fputs(NP_CX_OPTIONS_STATEMENT, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "collision") == 0) {
        fputs("var MSCXOpts=" NP_CX_OPTIONS_CAPTURE("t", "g") ";", stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "migration") == 0) {
        fputs(NP_LAUNCH_MIGRATION, stdout);
        return 0;
    }
    fputs("usage: emit component|statement|collision|migration\n", stderr);
    return 2;
}
