#ifndef IOS_SHIM_H
#define IOS_SHIM_H
#include <stdlib.h>
/* hactool calls exit() on errors. Inside an app that would kill the process,
   so it is redirected to a longjmp back into hactool_run(). */
void hactool_exit(int code) __attribute__((noreturn));
#define exit(code) hactool_exit(code)
#endif
