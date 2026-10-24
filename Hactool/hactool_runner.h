#ifndef HACTOOL_RUNNER_H
#define HACTOOL_RUNNER_H
#include <stdint.h>
/* Runs hactool in-process. stdout/stderr are redirected to log_path and HOME is
   set to `home` (hactool reads $HOME/.switch/title.keys and prod.keys from it).
   Returns hactool's exit status. Not re-entrant: callers must serialize. */
int hactool_run(int argc, char **argv, const char *home, const char *log_path);
uint64_t hactool_process_resident_memory(void);
uint64_t hactool_process_footprint(void);
uint64_t hactool_available_memory(void);
void hactool_install_crash_handler(const char *log_path);
void hactool_set_stage(const char *stage);
#endif
