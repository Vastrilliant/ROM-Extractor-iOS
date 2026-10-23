#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include <unistd.h>
#include <fcntl.h>
#include <getopt.h>
#include <pthread.h>
#include "hactool_runner.h"

int hactool_main(int argc, char **argv);

static jmp_buf g_jmp;
static volatile int g_active = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* Defined here; hactool sources reach it through the exit() macro in ios_shim.h. */
#undef exit
void hactool_exit(int code) {
    if (g_active) {
        longjmp(g_jmp, code + 1);
    }
    exit(code);
}

int hactool_run(int argc, char **argv, const char *home, const char *log_path) {
    pthread_mutex_lock(&g_lock);

    setenv("HOME", home, 1);
    unsetenv("XDG_CONFIG_HOME");

    fflush(stdout);
    fflush(stderr);
    int saved_out = dup(STDOUT_FILENO);
    int saved_err = dup(STDERR_FILENO);
    int log_fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log_fd >= 0) {
        dup2(log_fd, STDOUT_FILENO);
        dup2(log_fd, STDERR_FILENO);
        close(log_fd);
    }

    /* Reset getopt so repeated calls work. */
    optind = 1;
#ifdef __APPLE__
    optreset = 1;
#endif

    int ret;
    int jv = setjmp(g_jmp);
    if (jv == 0) {
        g_active = 1;
        ret = hactool_main(argc, argv);
    } else {
        ret = jv - 1;
    }
    g_active = 0;

    fflush(stdout);
    fflush(stderr);
    if (saved_out >= 0) { dup2(saved_out, STDOUT_FILENO); close(saved_out); }
    if (saved_err >= 0) { dup2(saved_err, STDERR_FILENO); close(saved_err); }

    pthread_mutex_unlock(&g_lock);
    return ret;
}
