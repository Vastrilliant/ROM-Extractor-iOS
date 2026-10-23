#ifndef HACTOOL_RUNNER_H
#define HACTOOL_RUNNER_H
/* Runs hactool in-process. stdout/stderr are redirected to log_path and HOME is
   set to `home` (hactool reads $HOME/.switch/title.keys and prod.keys from it).
   Returns hactool's exit status. Not re-entrant: callers must serialize. */
int hactool_run(int argc, char **argv, const char *home, const char *log_path);
#endif
