// Plugin and variant descriptor files, as specified in conf-format.md. One reader for
// both, so the two kinds cannot drift apart; compat_run.sh reads the same grammar and
// both are checked against dylib/tests/conf-fixtures.
#ifndef NP_CONF_H
#define NP_CONF_H

#include <stddef.h>

#define NP_CONF_LINE     2048
#define NP_CONF_ID_MAX    192
#define NP_CONF_REC_BUF  4096   // a record's fields, names and values together

typedef enum { NP_CONF_PLUGIN, NP_CONF_VARIANT } np_conf_kind;

// One record's fields in the order they were read, as "name\0value\0" pairs.
typedef struct {
    char id[NP_CONF_ID_MAX];
    char kv[NP_CONF_REC_BUF];
    int  nkv;
    int  kvlen;
} np_conf_rec_t;

// Walks a record's fields. Returns 0 when there are no more.
int np_conf_next(const np_conf_rec_t *rec, int *iter, const char **name, const char **value);
// The first value of a field, or NULL. Fields that may repeat have more than one.
const char *np_conf_get(const np_conf_rec_t *rec, const char *name);
int np_conf_count(const np_conf_rec_t *rec, const char *name);

typedef struct {
    // A record that passed the grammar and its own schema. Returning a code refuses it,
    // which is how directory-wide rules (a repeated id, the record limit) are applied.
    const char *(*record)(const np_conf_rec_t *rec, void *ctx, const char **detail);
    // A file or a record that was refused. scope is a path or an id.
    void (*refused)(const char *scope, const char *code, const char *detail, void *ctx);
    // Called as each file is opened, for checks that report per file.
    void (*file)(const char *path, void *ctx);
} np_conf_sink_t;

void np_conf_read_file(const char *path, const char *shown, np_conf_kind kind,
                       const np_conf_sink_t *sink, void *ctx);
// Every *.conf in dir, in LC_ALL=C name order. shown_dir prefixes the path a refusal
// names, so a check can report where EXPECTED says rather than an absolute path.
void np_conf_read_dir(const char *dir, const char *shown_dir, np_conf_kind kind,
                      const np_conf_sink_t *sink, void *ctx);

#define NP_CONF_UNREADABLE    "unreadable"
#define NP_CONF_LINE_LONG     "line-too-long"
#define NP_CONF_NO_HEADER     "no-header"
#define NP_CONF_BAD_ID        "bad-id"
#define NP_CONF_DUP_ID        "duplicate-id"
#define NP_CONF_UNKNOWN       "unknown-field"
#define NP_CONF_DUP_FIELD     "duplicate-field"
#define NP_CONF_EMPTY         "empty-value"
#define NP_CONF_TAB           "tab-in-value"
#define NP_CONF_REQUIRED      "missing-required"
#define NP_CONF_BAD_VALUE     "bad-value"
#define NP_CONF_LIMIT         "limit"
#define NP_CONF_BAD_TYPE      "bad-type"
#define NP_CONF_SLIDER_SHAPE  "slider-shape"
#define NP_CONF_BAD_DEFAULT   "bad-default"

#endif
