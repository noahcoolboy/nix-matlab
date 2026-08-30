#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#define CURLOPT_WRITEDATA 10001
#define CURLOPT_WRITEFUNCTION 20011
typedef int (*setopt_t)(void *, int, ...);
typedef size_t (*write_fn)(char *, size_t, size_t, void *);
static setopt_t real_setopt;
static write_fn orig_write;
static void *orig_data;
static FILE *out;
static size_t wrap(char *p, size_t s, size_t n, void *u) {
    if (s * n) {
        if (!out) {
            char path[4096];
            const char *pwd = getenv("PWD");
            snprintf(path, sizeof(path), "%s/versions.jsonl", pwd && *pwd ? pwd : ".");
            out = fopen(path, "a");
        }
        if (out) fwrite(p, s, n, out);
    }
    return orig_write ? orig_write(p, s, n, orig_data)
                      : fwrite(p, s, n, orig_data ? orig_data : stdout);
}
int curl_easy_setopt(void *h, int opt, ...) {
    if (!real_setopt) real_setopt = (setopt_t)dlsym(RTLD_NEXT, "curl_easy_setopt");
    va_list ap; va_start(ap, opt);
    int rc;
    switch (opt / 10000) {
    case 0: { long v = va_arg(ap, long); rc = real_setopt(h, opt, v); break; }
    case 3: { long long v = va_arg(ap, long long); rc = real_setopt(h, opt, v); break; }
    default: {
        void *v = va_arg(ap, void *);
        if (opt == CURLOPT_WRITEFUNCTION) orig_write = v;
        else if (opt == CURLOPT_WRITEDATA) orig_data = v;
        rc = real_setopt(h, opt, v);
        break;
    }
    }
    va_end(ap);
    return rc;
}
int curl_easy_perform(void *h) {
    static int (*real_perform)(void *);
    if (!real_setopt) real_setopt = (setopt_t)dlsym(RTLD_NEXT, "curl_easy_setopt");
    if (!real_perform) real_perform = dlsym(RTLD_NEXT, "curl_easy_perform");
    out = 0;
    real_setopt(h, CURLOPT_WRITEFUNCTION, wrap);
    real_setopt(h, CURLOPT_WRITEDATA, h);
    int rc = real_perform(h);
    real_setopt(h, CURLOPT_WRITEFUNCTION, orig_write);
    real_setopt(h, CURLOPT_WRITEDATA, (orig_write || orig_data) ? orig_data : stdout);
    if (out) { fputc('\n', out); fclose(out); out = 0; }
    return rc;
}
