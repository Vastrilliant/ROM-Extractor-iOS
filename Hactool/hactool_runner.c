#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include <unistd.h>
#include <fcntl.h>
#include <getopt.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <execinfo.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#endif
#include "hactool_runner.h"

int hactool_main(int argc, char **argv);

static jmp_buf g_jmp;
static volatile int g_active = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static int g_crash_fd = -1;
static char g_stage[192] = "";
static char g_alt_stack[128 * 1024];
static int g_vbuf_done = 0;
static const int g_crash_signals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP };

static void crash_puts(const char *s) {
    if (g_crash_fd < 0) return;
    size_t n = 0;
    while (s[n]) n++;
    (void)!write(g_crash_fd, s, n);
}

static void crash_put_hex(uint64_t v) {
    char buf[19];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 16; i++) buf[2 + i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 0xF];
    buf[18] = 0;
    crash_puts(buf);
}

static void crash_put_dec(long v) {
    char buf[24];
    int i = 23;
    buf[i] = 0;
    int neg = v < 0;
    unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
    do { buf[--i] = (char)('0' + u % 10); u /= 10; } while (u && i > 1);
    if (neg) buf[--i] = '-';
    crash_puts(buf + i);
}

static const char *crash_signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS: return "SIGBUS";
        case SIGABRT: return "SIGABRT";
        case SIGILL: return "SIGILL";
        case SIGFPE: return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default: return "?";
    }
}

static void crash_handler(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;
    crash_puts("\n[CRASH] signal ");
    crash_put_dec(sig);
    crash_puts(" (");
    crash_puts(crash_signal_name(sig));
    crash_puts(") fault_addr=");
    crash_put_hex((uint64_t)(uintptr_t)(info ? info->si_addr : 0));
    crash_puts(" stage=\"");
    crash_puts(g_stage);
    crash_puts("\"\n");
#ifdef __APPLE__
    crash_puts("[CRASH] image_slide=");
    crash_put_hex((uint64_t)(int64_t)_dyld_get_image_vmaddr_slide(0));
    crash_puts("\n");
#endif
    void *frames[64];
    int n = backtrace(frames, 64);
    crash_puts("[CRASH] backtrace:\n");
    if (g_crash_fd >= 0) backtrace_symbols_fd(frames, n, g_crash_fd);
    crash_puts("[CRASH] end\n");
}

static void use_alt_stack(void) {
    stack_t ss;
    ss.ss_sp = g_alt_stack;
    ss.ss_size = sizeof(g_alt_stack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
}

void hactool_install_crash_handler(const char *log_path) {
    if (g_crash_fd >= 0) return;
    g_crash_fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND | SA_NODEFER;
    for (size_t i = 0; i < sizeof(g_crash_signals) / sizeof(g_crash_signals[0]); i++) {
        sigaction(g_crash_signals[i], &sa, NULL);
    }
    use_alt_stack();
}

void hactool_set_stage(const char *stage) {
    size_t i = 0;
    if (stage) {
        for (; stage[i] && i < sizeof(g_stage) - 1; i++) g_stage[i] = stage[i];
    }
    g_stage[i] = 0;
}

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
    use_alt_stack();

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
    if (!g_vbuf_done) {
        setvbuf(stdout, NULL, _IOLBF, 0);
        g_vbuf_done = 1;
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

uint64_t hactool_process_resident_memory(void) {
#ifdef __APPLE__
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    return result == KERN_SUCCESS ? (uint64_t)info.resident_size : 0;
#else
    return 0;
#endif
}

uint64_t hactool_process_footprint(void) {
#ifdef __APPLE__
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return result == KERN_SUCCESS ? (uint64_t)info.phys_footprint : 0;
#else
    return 0;
#endif
}

uint64_t hactool_available_memory(void) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    return (uint64_t)os_proc_available_memory();
#else
    return 0;
#endif
}
