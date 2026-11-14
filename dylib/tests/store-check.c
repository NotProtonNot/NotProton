// The store's side with no socket in it: which process gets the debugger, what a frame
// looks like on the wire, which pages are the store's, and the two switches.
#include "../feats/store.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

// The catalogue's map is the catalogue's to check.
char *np_catalog_map(void) { return strdup("{480:[\"good\",\"ok\"]}"); }

static int failures;

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static int count(char **argv) { int n = 0; while (argv && argv[n]) n++; return n; }

int main(void) {
    char home[PATH_MAX], dir[PATH_MAX];
    snprintf(home, sizeof home, "%s/store.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(home)) { perror("mkdtemp"); return 1; }
    setenv("HOME", home, 1);
    snprintf(dir, sizeof dir, "%s/Library", home); mkdir(dir, 0755);
    snprintf(dir, sizeof dir, "%s/Library/Application Support", home); mkdir(dir, 0755);
    snprintf(dir, sizeof dir, "%s/Library/Application Support/notproton", home); mkdir(dir, 0755);

    printf("== which process gets the debugger ==\n");
    char *helper[] = { "Steam Helper", "-lang=en_US", NULL };
    char **args = np_store_helper_args("/x/Steam Helper.app/Contents/MacOS/Steam Helper", helper);
    check(args != NULL, "the web helper itself does");
    check(args && count(args) == 4, "with two arguments added to its own");
    check(args && strcmp(args[0], "Steam Helper") == 0 && strcmp(args[1], "-lang=en_US") == 0,
          "and its own left as they were");
    check(args && strcmp(args[2], "--remote-debugging-port=27101") == 0, "the port");
    // The address is what keeps the port off the network.
    check(args && strcmp(args[3], "--remote-debugging-address=127.0.0.1") == 0,
          "and this machine as the only address");
    free(args);
    char *renderer[] = { "Steam Helper", "--type=renderer", NULL };
    check(!np_store_helper_args("/x/Steam Helper", renderer), "one of the helper's children does not");
    char *told[] = { "Steam Helper", "--remote-debugging-port=8080", NULL };
    check(!np_store_helper_args("/x/Steam Helper", told), "a helper already told a port keeps it");
    check(!np_store_helper_args("/x/steam_osx", helper), "Steam itself does not");
    check(!np_store_helper_args("/x/Some Game", helper), "and neither does a game");
    check(!np_store_helper_args(NULL, helper) && !np_store_helper_args("/x/Steam Helper", NULL),
          "nothing to start is nothing to add to");

    printf("== the switches ==\n");
    check(np_store_enabled() && np_store_switch(), "the store is on until someone turns it off");
    check(np_store_set_enabled(0) && !np_store_switch() && !np_store_enabled(), "turning it off is kept");
    check(!np_store_helper_args("/x/Steam Helper", helper), "and the helper then starts without the debugger");
    check(np_store_set_enabled(1) && np_store_enabled(), "turning it on again is kept");
    check(np_store_set_enabled(1), "and doing it twice is not an error");
    // The switch for every badge turns the store off with the rest, without changing
    // what the store's own switch was left at.
    snprintf(dir, sizeof dir, "%s/Library/Application Support/notproton/no-mac-badges", home);
    FILE *f = fopen(dir, "w"); if (f) fclose(f);
    check(!np_store_enabled() && np_store_switch(), "every badge off is the store off, its own switch untouched");
    check(!np_store_helper_args("/x/Steam Helper", helper), "and no debugger then either");
    unlink(dir);

    printf("== a frame on the wire ==\n");
    const uint8_t mask[4] = { 0x11, 0x22, 0x33, 0x44 };
    uint8_t out[70000];
    size_t n = np_store_frame("hi", 2, mask, out, sizeof out);
    check(n == 8 && out[0] == 0x81 && out[1] == (0x80 | 2), "a short one says its length in a byte, masked");
    check(memcmp(out + 2, mask, 4) == 0 && out[6] == ('h' ^ 0x11) && out[7] == ('i' ^ 0x22),
          "and carries the mask and the text under it");
    static char big[66000];
    memset(big, 'a', sizeof big);
    n = np_store_frame(big, 300, mask, out, sizeof out);
    check(n == 300 + 8 && out[1] == (0x80 | 126) && out[2] == 1 && out[3] == 44, "a longer one takes two more bytes");
    n = np_store_frame(big, 66000, mask, out, sizeof out);
    check(n == 66000 + 14 && out[1] == (0x80 | 127) && out[8] == 0x01 && out[9] == 0xD0,
          "and a page script's worth takes eight");
    check(out[10] == mask[0] && out[14] == ('a' ^ mask[0]) && out[15] == ('a' ^ mask[1]), "masked the same way");
    check(np_store_frame(big, 66000, mask, out, 100) == 0, "one that does not fit is not written");

    printf("== which pages are the store's ==\n");
    check(np_store_wants("page", "https://store.steampowered.com/app/480/"), "an app page");
    check(np_store_wants("page", "https://store.steampowered.com/wishlist/id/x/"), "the wishlist");
    check(!np_store_wants("page", "https://steamloopback.host/index.html"), "not Steam's own interface");
    check(!np_store_wants("page", "https://store.steampowered.com.evil.example/"), "not a look-alike host");
    check(!np_store_wants("page", "https://steamcommunity.com/"), "not the community");
    check(!np_store_wants("service_worker", "https://store.steampowered.com/"), "not a worker");
    check(!np_store_wants(NULL, NULL), "and not nothing");

    printf("== the script the pages are given ==\n");
    char *js = np_store_script("a(__NP_MAP__)b", "{1:2}");
    check(js && strcmp(js, "a({1:2})b") == 0, "the map goes in the one place that takes it");
    free(js);
    check(!np_store_script("a b", "{}"), "a script with no place for it is refused");
    check(!np_store_script("__NP_MAP__ and __NP_MAP__", "{}"), "and so is one with two");
    js = np_store_script(np_store_page_js, "{480:[\"good\",\"ok\"]}");
    check(js != NULL, "the script that ships has exactly one");
    check(js && strstr(js, "const MAP = {480:[\"good\",\"ok\"]};") != NULL, "and it is where the map is read");
    check(js && !strstr(js, "__NP_MAP__"), "with nothing left to fill in");
    free(js);

    printf(failures ? "==> store-check: %d failure(s)\n"
                    : "==> store-check: the debugger goes to the helper alone, and the script goes in whole\n", failures);
    return failures ? 1 : 0;
}
