#include <janet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/time.h>

enum {
  TRIAD_JANET_COMMAND = 1
};

typedef struct {
  int kind;
  int argc;
  char **argv;
} TriadJanetAction;

typedef struct {
  TriadJanetAction *actions;
  int action_count;
  int action_capacity;
  char *last_error;
} TriadJanetRuntime;

typedef struct {
  JanetTable *env;
} TriadJanetScript;

static TriadJanetRuntime *current_runtime = NULL;
static int janet_init_count = 0;
static volatile sig_atomic_t janet_eval_interrupted = 0;

void triad_janet_script_free(void *script_ptr);

static void janet_eval_alarm_handler(int sig) {
  (void) sig;
  janet_eval_interrupted = 1;
  janet_interpreter_interrupt(NULL);
}

static char *copy_cstring(const char *source) {
  size_t len = strlen(source);
  char *copy = (char *) malloc(len + 1);
  if (copy == NULL) return NULL;
  memcpy(copy, source, len + 1);
  return copy;
}

static char *copy_janet_string(JanetString source) {
  int32_t len = janet_string_length(source);
  char *copy = (char *) malloc((size_t) len + 1);
  if (copy == NULL) return NULL;
  memcpy(copy, source, (size_t) len);
  copy[len] = '\0';
  return copy;
}

static char *copy_number_string(double value) {
  char buffer[64];
  int len = snprintf(buffer, sizeof(buffer), "%.17g", value);
  if (len < 0 || (size_t) len >= sizeof(buffer)) return NULL;
  return copy_cstring(buffer);
}

static char *copy_arg_string(Janet value) {
  switch (janet_type(value)) {
    case JANET_STRING:
      return copy_janet_string(janet_unwrap_string(value));
    case JANET_SYMBOL:
      return copy_janet_string(janet_unwrap_symbol(value));
    case JANET_KEYWORD:
      return copy_janet_string(janet_unwrap_keyword(value));
    case JANET_NUMBER:
      return copy_number_string(janet_unwrap_number(value));
    case JANET_BOOLEAN:
      return copy_cstring(janet_unwrap_boolean(value) ? "true" : "false");
    default:
      janet_panic("expected command arguments to be strings, symbols, keywords, numbers, or booleans");
      return NULL;
  }
}

static void free_action(TriadJanetAction *action) {
  if (action->argv != NULL) {
    for (int i = 0; i < action->argc; i++) {
      if (action->argv[i] != NULL) free(action->argv[i]);
    }
    free(action->argv);
  }
  memset(action, 0, sizeof(TriadJanetAction));
}

static void clear_runtime(TriadJanetRuntime *runtime) {
  if (runtime == NULL) return;
  for (int i = 0; i < runtime->action_count; i++) {
    free_action(&runtime->actions[i]);
  }
  runtime->action_count = 0;
  if (runtime->last_error != NULL) {
    free(runtime->last_error);
    runtime->last_error = NULL;
  }
}

static void set_error(TriadJanetRuntime *runtime, const char *message) {
  if (runtime == NULL) return;
  if (runtime->last_error != NULL) free(runtime->last_error);
  runtime->last_error = copy_cstring(message);
}

static int append_action(TriadJanetRuntime *runtime, TriadJanetAction action) {
  if (runtime == NULL) return 0;
  if (runtime->action_count == runtime->action_capacity) {
    int new_capacity = runtime->action_capacity == 0 ? 4 : runtime->action_capacity * 2;
    TriadJanetAction *new_actions = (TriadJanetAction *) realloc(
      runtime->actions, sizeof(TriadJanetAction) * (size_t) new_capacity);
    if (new_actions == NULL) return 0;
    runtime->actions = new_actions;
    runtime->action_capacity = new_capacity;
  }
  runtime->actions[runtime->action_count++] = action;
  return 1;
}

static Janet c_command(int32_t argc, Janet *argv) {
  janet_arity(argc, 1, INT32_MAX);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_COMMAND;
  action.argc = argc;
  action.argv = (char **) calloc((size_t) argc, sizeof(char *));
  if (action.argv == NULL) janet_panic("failed to append action");
  for (int32_t i = 0; i < argc; i++) {
    action.argv[i] = copy_arg_string(argv[i]);
    if (action.argv[i] == NULL) {
      free_action(&action);
      janet_panic("failed to append action");
    }
  }
  if (!append_action(current_runtime, action)) {
    free_action(&action);
    janet_panic("failed to append action");
  }
  return janet_wrap_nil();
}

static const JanetReg triad_cfuns[] = {
  {"triad/command", c_command, NULL},
  {NULL, NULL, NULL}
};

static void remove_symbol(JanetTable *env, const char *name) {
  janet_table_remove(env, janet_csymbolv(name));
}

static void scrub_env(JanetTable *env) {
  const char *blocked[] = {
    "dofile", "require", "import", "use", "eval", "compile", "asm", "disasm",
    "sandbox", "debug/break", "debug/unbreak", "debug/fbreak", "debug/unfbreak",
    "debug/arg-stack", "debug/stack", "debug/stacktrace", "debug/lineage",
    "debug/step", "os/execute", "os/spawn", "os/shell", "os/exit", "os/getenv",
    "os/setenv", "os/environ", "file/open", "file/read", "file/write",
    "file/close", "file/seek", "file/stat", "file/rm", "file/mkdir",
    "file/temp", "slurp", "spit", "native", "native/lookup", "native/load",
    "ffi/open", "ffi/lookup", "net/connect", "net/listen", NULL
  };
  for (int i = 0; blocked[i] != NULL; i++) {
    remove_symbol(env, blocked[i]);
  }
}

static void harden_sandbox(void) {
  janet_sandbox(
    JANET_SANDBOX_SUBPROCESS |
    JANET_SANDBOX_NET |
    JANET_SANDBOX_FFI |
    JANET_SANDBOX_FS |
    JANET_SANDBOX_ENV |
    JANET_SANDBOX_DYNAMIC_MODULES |
    JANET_SANDBOX_THREADS |
    JANET_SANDBOX_SIGNAL |
    JANET_SANDBOX_HRTIME |
    JANET_SANDBOX_CHROOT |
    JANET_SANDBOX_UNMARSHAL);
}

static int eval_source_with_timer(
    TriadJanetRuntime *runtime,
    JanetTable *env,
    const char *source,
    const char *path,
    int32_t fuel_limit,
    Janet *out) {
  struct sigaction next_action;
  struct sigaction previous_action;
  struct itimerval next_timer;
  struct itimerval previous_timer;
  int32_t micros = fuel_limit <= 0 ? 1000 : fuel_limit;

  memset(&next_action, 0, sizeof(next_action));
  next_action.sa_handler = janet_eval_alarm_handler;
  sigemptyset(&next_action.sa_mask);
  sigaction(SIGALRM, &next_action, &previous_action);
  getitimer(ITIMER_REAL, &previous_timer);

  memset(&next_timer, 0, sizeof(next_timer));
  next_timer.it_value.tv_sec = micros / 1000000;
  next_timer.it_value.tv_usec = micros % 1000000;
  if (next_timer.it_value.tv_sec == 0 && next_timer.it_value.tv_usec == 0) {
    next_timer.it_value.tv_usec = 1000;
  }

  janet_eval_interrupted = 0;
  setitimer(ITIMER_REAL, &next_timer, NULL);
  int status = janet_dostring(env, source, path, out);

  memset(&next_timer, 0, sizeof(next_timer));
  setitimer(ITIMER_REAL, &next_timer, NULL);
  sigaction(SIGALRM, &previous_action, NULL);
  setitimer(ITIMER_REAL, &previous_timer, NULL);

  if (janet_eval_interrupted) {
    set_error(runtime, "Janet script exceeded fuel limit");
    janet_interpreter_interrupt_handled(NULL);
    return 0;
  }
  if (status != 0) {
    JanetString desc = janet_description(*out);
    char *message = copy_janet_string(desc);
    set_error(
      runtime,
      message == NULL || message[0] == '\0' ? "Janet evaluation failed" : message);
    if (message != NULL) free(message);
    return 0;
  }
  return status == 0;
}

static int eval_source(
    TriadJanetRuntime *runtime,
    JanetTable *env,
    const char *source,
    const char *path) {
  Janet out;
  int status = janet_dostring(env, source, path, &out);
  if (status != 0) {
    JanetString desc = janet_description(out);
    char *message = copy_janet_string(desc);
    set_error(runtime, message == NULL ? "Janet evaluation failed" : message);
    if (message != NULL) free(message);
    return 0;
  }
  return 1;
}

void *triad_janet_new(void) {
  if (janet_init_count == 0) {
    janet_init();
  }
  janet_init_count++;
  return calloc(1, sizeof(TriadJanetRuntime));
}

void triad_janet_free(void *runtime_ptr) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL) return;
  clear_runtime(runtime);
  if (runtime->actions != NULL) free(runtime->actions);
  free(runtime);
  if (janet_init_count > 0) {
    janet_init_count--;
    if (janet_init_count == 0) janet_deinit();
  }
}

int triad_janet_eval(void *runtime_ptr, const char *snapshot_source, const char *source, const char *path, int32_t fuel_limit) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL) return 0;
  clear_runtime(runtime);
  harden_sandbox();

  JanetTable *env = janet_core_env(NULL);
  scrub_env(env);
  janet_cfuns(env, NULL, triad_cfuns);

  Janet out;
  current_runtime = runtime;
  int status = janet_dostring(env, snapshot_source, path, &out);
  if (status == 0) {
    if (!eval_source_with_timer(runtime, env, source, path, fuel_limit, &out)) {
      if (runtime->last_error == NULL || runtime->last_error[0] == '\0') {
        set_error(runtime, "Janet evaluation failed");
      }
      current_runtime = NULL;
      return 0;
    }
  }
  current_runtime = NULL;
  if (status != 0) {
    JanetString desc = janet_description(out);
    char *message = copy_janet_string(desc);
    set_error(runtime, message == NULL ? "Janet evaluation failed" : message);
    if (message != NULL) free(message);
    return 0;
  }
  return 1;
}

void *triad_janet_script_load(void *runtime_ptr, const char *bootstrap_source, const char *source, const char *path, int32_t fuel_limit) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL) return NULL;
  clear_runtime(runtime);
  harden_sandbox();

  TriadJanetScript *script = (TriadJanetScript *) calloc(1, sizeof(TriadJanetScript));
  if (script == NULL) {
    set_error(runtime, "failed to allocate Janet script");
    return NULL;
  }

  script->env = janet_core_env(NULL);
  scrub_env(script->env);
  janet_cfuns(script->env, NULL, triad_cfuns);
  janet_gcroot(janet_wrap_table(script->env));

  current_runtime = runtime;
  if (!eval_source(runtime, script->env, bootstrap_source, path)) {
    current_runtime = NULL;
    triad_janet_script_free(script);
    return NULL;
  }
  Janet out;
  if (!eval_source_with_timer(runtime, script->env, source, path, fuel_limit, &out)) {
    if (runtime->last_error == NULL || runtime->last_error[0] == '\0') {
      set_error(runtime, "Janet script load failed");
    }
    current_runtime = NULL;
    triad_janet_script_free(script);
    return NULL;
  }
  current_runtime = NULL;
  clear_runtime(runtime);
  return script;
}

int triad_janet_script_dispatch(void *runtime_ptr, void *script_ptr, const char *event_source, const char *path, int32_t fuel_limit) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  TriadJanetScript *script = (TriadJanetScript *) script_ptr;
  if (runtime == NULL || script == NULL || script->env == NULL) return 0;
  clear_runtime(runtime);
  harden_sandbox();

  current_runtime = runtime;
  if (!eval_source(runtime, script->env, event_source, path)) {
    current_runtime = NULL;
    return 0;
  }
  Janet out;
  if (!eval_source_with_timer(
        runtime,
        script->env,
        "(triad/dispatch-event triad/current-event)",
        path,
        fuel_limit,
        &out)) {
    if (runtime->last_error == NULL || runtime->last_error[0] == '\0') {
      set_error(runtime, "Janet event dispatch failed");
    }
    current_runtime = NULL;
    return 0;
  }
  current_runtime = NULL;
  return 1;
}

void triad_janet_script_free(void *script_ptr) {
  TriadJanetScript *script = (TriadJanetScript *) script_ptr;
  if (script == NULL) return;
  if (script->env != NULL) {
    janet_gcunroot(janet_wrap_table(script->env));
  }
  free(script);
}

const char *triad_janet_last_error(void *runtime_ptr) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || runtime->last_error == NULL) return "";
  return runtime->last_error;
}

int triad_janet_action_count(void *runtime_ptr) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL) return 0;
  return runtime->action_count;
}

int triad_janet_action_kind(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->action_count) return 0;
  return runtime->actions[index].kind;
}

int triad_janet_action_argc(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->action_count) return 0;
  return runtime->actions[index].argc;
}

const char *triad_janet_action_argv(void *runtime_ptr, int index, int arg_index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->action_count) return "";
  TriadJanetAction *action = &runtime->actions[index];
  if (arg_index < 0 || arg_index >= action->argc || action->argv == NULL) return "";
  return action->argv[arg_index] == NULL ? "" : action->argv[arg_index];
}
