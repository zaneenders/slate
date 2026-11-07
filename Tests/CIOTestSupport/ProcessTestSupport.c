#include "CIOTestSupport.h"
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int cli_test_spawn_terminal(const char *path, int slave, int *child) {
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  int error = posix_spawn_file_actions_init(&actions);
  if (error) return error;
  error = posix_spawnattr_init(&attributes);
  if (error) { posix_spawn_file_actions_destroy(&actions); return error; }
  for (int fd = 0; fd < 3 && !error; fd++) error = posix_spawn_file_actions_adddup2(&actions, slave, fd);
  sigset_t mask;
  sigemptyset(&mask);
  if (!error) error = posix_spawnattr_setsigmask(&attributes, &mask);
  if (!error) error = posix_spawnattr_setpgroup(&attributes, 0);
  if (!error) error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK);
  char *arguments[] = {(char *)path, NULL};
  pid_t pid = -1;
  if (!error) error = posix_spawn(&pid, path, &actions, &attributes, arguments, environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  *child = (int)pid;
  return error;
}

int cli_test_wait_terminal(int child, int *value) {
  int status;
  pid_t result = waitpid((pid_t)child, &status, WNOHANG | WUNTRACED);
  if (result < 0) return -errno;
  if (result == 0) return 0;
  if (WIFSTOPPED(status)) { *value = WSTOPSIG(status); return 1; }
  if (WIFEXITED(status)) { *value = WEXITSTATUS(status); return 2; }
  if (WIFSIGNALED(status)) { *value = WTERMSIG(status); return 3; }
  return 0;
}
