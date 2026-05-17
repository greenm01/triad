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

#define TRIAD_JANET_MAX_WAITERS 64

typedef struct {
  int kind;
  int argc;
  char **argv;
} TriadJanetAction;

typedef struct {
  uint32_t window_id;
  int32_t x;
  int32_t y;
  int32_t w;
  int32_t h;
} TriadJanetLayoutInstruction;

typedef struct {
  TriadJanetAction *actions;
  int action_count;
  int action_capacity;
  TriadJanetLayoutInstruction *layout_instructions;
  int layout_instruction_count;
  int layout_instruction_capacity;
  char *last_error;
} TriadJanetRuntime;

typedef struct {
  JanetFiber *fiber;
  char *event_name;
} TriadJanetWaiter;

typedef struct {
  char *event_name;
  JanetFunction **handlers;
  int handler_count;
  int handler_capacity;
} TriadJanetHandlerList;

typedef struct {
  char *name;
  JanetFunction *function;
} TriadJanetLayout;

typedef struct {
  JanetTable *env;
  TriadJanetHandlerList *handler_lists;
  int handler_list_count;
  int handler_list_capacity;
  TriadJanetLayout *layouts;
  int layout_count;
  int layout_capacity;
  TriadJanetWaiter *waiters;
  int waiter_count;
  int waiter_capacity;
} TriadJanetScript;

static TriadJanetRuntime *current_runtime = NULL;
static TriadJanetScript *current_script = NULL;
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
  runtime->layout_instruction_count = 0;
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

static int append_layout_instruction(
    TriadJanetRuntime *runtime,
    TriadJanetLayoutInstruction instruction) {
  if (runtime == NULL) return 0;
  if (runtime->layout_instruction_count == runtime->layout_instruction_capacity) {
    int new_capacity =
      runtime->layout_instruction_capacity == 0
        ? 8
        : runtime->layout_instruction_capacity * 2;
    TriadJanetLayoutInstruction *new_instructions =
      (TriadJanetLayoutInstruction *) realloc(
        runtime->layout_instructions,
        sizeof(TriadJanetLayoutInstruction) * (size_t) new_capacity);
    if (new_instructions == NULL) return 0;
    runtime->layout_instructions = new_instructions;
    runtime->layout_instruction_capacity = new_capacity;
  }
  runtime->layout_instructions[runtime->layout_instruction_count++] = instruction;
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

static char *copy_layout_name(Janet value) {
  switch (janet_type(value)) {
    case JANET_STRING:
      return copy_janet_string(janet_unwrap_string(value));
    case JANET_SYMBOL:
      return copy_janet_string(janet_unwrap_symbol(value));
    case JANET_KEYWORD:
      return copy_janet_string(janet_unwrap_keyword(value));
    default:
      janet_panic("triad/def-layout expects a string, symbol, or keyword name");
      return NULL;
  }
}

static Janet c_def_layout(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  if (current_script == NULL) {
    janet_panic("triad/def-layout is only available while loading a persistent script");
  }
  if (!janet_checktype(argv[1], JANET_FUNCTION)) {
    janet_panic("triad/def-layout expects a layout function");
  }

  char *name = copy_layout_name(argv[0]);
  if (name == NULL || name[0] == '\0') {
    if (name != NULL) free(name);
    janet_panic("triad/def-layout expects a non-empty layout name");
  }
  JanetFunction *function = janet_unwrap_function(argv[1]);

  for (int i = 0; i < current_script->layout_count; i++) {
    if (strcmp(current_script->layouts[i].name, name) == 0) {
      janet_gcunroot(janet_wrap_function(current_script->layouts[i].function));
      current_script->layouts[i].function = function;
      janet_gcroot(janet_wrap_function(function));
      free(name);
      return janet_wrap_nil();
    }
  }

  if (current_script->layout_count == current_script->layout_capacity) {
    int new_capacity =
      current_script->layout_capacity == 0
        ? 4
        : current_script->layout_capacity * 2;
    TriadJanetLayout *new_layouts = (TriadJanetLayout *) realloc(
      current_script->layouts, sizeof(TriadJanetLayout) * (size_t) new_capacity);
    if (new_layouts == NULL) {
      free(name);
      janet_panic("failed to register layout");
    }
    current_script->layouts = new_layouts;
    current_script->layout_capacity = new_capacity;
  }

  janet_gcroot(janet_wrap_function(function));
  current_script->layouts[current_script->layout_count].name = name;
  current_script->layouts[current_script->layout_count].function = function;
  current_script->layout_count++;
  return janet_wrap_nil();
}

static Janet c_wait_event(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  if (!janet_checktype(argv[0], JANET_KEYWORD)) {
    janet_panic("triad/wait-event expects an event keyword");
  }
  JanetArray *marker = janet_array(2);
  janet_array_push(marker, janet_ckeywordv("triad/wait-event"));
  janet_array_push(marker, argv[0]);
  janet_signalv(JANET_SIGNAL_YIELD, janet_wrap_array(marker));
  return janet_wrap_nil();
}

static Janet c_on(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  if (current_script == NULL) {
    janet_panic("triad/on is only available while loading a persistent script");
  }
  if (!janet_checktype(argv[0], JANET_KEYWORD)) {
    janet_panic("triad/on expects an event keyword");
  }
  if (!janet_checktype(argv[1], JANET_FUNCTION)) {
    janet_panic("triad/on expects a handler function");
  }

  char *event_name = copy_janet_string(janet_unwrap_keyword(argv[0]));
  if (event_name == NULL) janet_panic("failed to register handler");
  JanetFunction *handler = janet_unwrap_function(argv[1]);

  TriadJanetHandlerList *list = NULL;
  for (int i = 0; i < current_script->handler_list_count; i++) {
    if (strcmp(current_script->handler_lists[i].event_name, event_name) == 0) {
      list = &current_script->handler_lists[i];
      break;
    }
  }
  if (list == NULL) {
    if (current_script->handler_list_count == current_script->handler_list_capacity) {
      int new_capacity =
        current_script->handler_list_capacity == 0
          ? 4
          : current_script->handler_list_capacity * 2;
      TriadJanetHandlerList *new_lists = (TriadJanetHandlerList *) realloc(
        current_script->handler_lists,
        sizeof(TriadJanetHandlerList) * (size_t) new_capacity);
      if (new_lists == NULL) {
        free(event_name);
        janet_panic("failed to register handler");
      }
      current_script->handler_lists = new_lists;
      current_script->handler_list_capacity = new_capacity;
    }
    list = &current_script->handler_lists[current_script->handler_list_count++];
    memset(list, 0, sizeof(TriadJanetHandlerList));
    list->event_name = event_name;
    event_name = NULL;
  }
  if (event_name != NULL) free(event_name);

  if (list->handler_count == list->handler_capacity) {
    int new_capacity = list->handler_capacity == 0 ? 4 : list->handler_capacity * 2;
    JanetFunction **new_handlers = (JanetFunction **) realloc(
      list->handlers, sizeof(JanetFunction *) * (size_t) new_capacity);
    if (new_handlers == NULL) janet_panic("failed to register handler");
    list->handlers = new_handlers;
    list->handler_capacity = new_capacity;
  }
  janet_gcroot(janet_wrap_function(handler));
  list->handlers[list->handler_count++] = handler;
  return janet_wrap_nil();
}

static const JanetReg triad_cfuns[] = {
  {"triad/command", c_command, NULL},
  {"triad/def-layout", c_def_layout, NULL},
  {"triad/on", c_on, NULL},
  {"triad/wait-event", c_wait_event, NULL},
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

static JanetSignal pcall_with_timer(
    TriadJanetRuntime *runtime,
    JanetFunction *function,
    int32_t argc,
    const Janet *argv,
    int32_t fuel_limit,
    Janet *out,
    JanetFiber **fiber) {
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
  JanetSignal signal = janet_pcall(function, argc, argv, out, fiber);

  memset(&next_timer, 0, sizeof(next_timer));
  setitimer(ITIMER_REAL, &next_timer, NULL);
  sigaction(SIGALRM, &previous_action, NULL);
  setitimer(ITIMER_REAL, &previous_timer, NULL);

  if (janet_eval_interrupted) {
    set_error(runtime, "Janet script exceeded fuel limit");
    janet_interpreter_interrupt_handled(NULL);
    return JANET_SIGNAL_ERROR;
  }
  return signal;
}

static JanetSignal continue_with_timer(
    TriadJanetRuntime *runtime,
    JanetFiber *fiber,
    Janet input,
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
  JanetSignal signal = janet_continue(fiber, input, out);

  memset(&next_timer, 0, sizeof(next_timer));
  setitimer(ITIMER_REAL, &next_timer, NULL);
  sigaction(SIGALRM, &previous_action, NULL);
  setitimer(ITIMER_REAL, &previous_timer, NULL);

  if (janet_eval_interrupted) {
    set_error(runtime, "Janet script exceeded fuel limit");
    janet_interpreter_interrupt_handled(NULL);
    return JANET_SIGNAL_ERROR;
  }
  return signal;
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

static Janet resolve_env_symbol(JanetTable *env, const char *name) {
  Janet value = janet_wrap_nil();
  if (janet_resolve(env, janet_csymbol(name), &value) == JANET_BINDING_NONE) {
    JanetTable *lookup = janet_env_lookup(env);
    return janet_get(janet_wrap_table(lookup), janet_csymbolv(name));
  }
  return value;
}

static void free_waiter(TriadJanetWaiter *waiter) {
  if (waiter == NULL) return;
  if (waiter->fiber != NULL) {
    janet_gcunroot(janet_wrap_fiber(waiter->fiber));
  }
  if (waiter->event_name != NULL) {
    free(waiter->event_name);
  }
  memset(waiter, 0, sizeof(TriadJanetWaiter));
}

static void clear_waiters(TriadJanetScript *script) {
  if (script == NULL) return;
  for (int i = 0; i < script->waiter_count; i++) {
    free_waiter(&script->waiters[i]);
  }
  script->waiter_count = 0;
}

static void free_handler_list(TriadJanetHandlerList *list) {
  if (list == NULL) return;
  if (list->event_name != NULL) free(list->event_name);
  if (list->handlers != NULL) {
    for (int i = 0; i < list->handler_count; i++) {
      if (list->handlers[i] != NULL) {
        janet_gcunroot(janet_wrap_function(list->handlers[i]));
      }
    }
    free(list->handlers);
  }
  memset(list, 0, sizeof(TriadJanetHandlerList));
}

static void clear_handlers(TriadJanetScript *script) {
  if (script == NULL) return;
  for (int i = 0; i < script->handler_list_count; i++) {
    free_handler_list(&script->handler_lists[i]);
  }
  script->handler_list_count = 0;
}

static void clear_layouts(TriadJanetScript *script) {
  if (script == NULL) return;
  for (int i = 0; i < script->layout_count; i++) {
    if (script->layouts[i].name != NULL) free(script->layouts[i].name);
    if (script->layouts[i].function != NULL) {
      janet_gcunroot(janet_wrap_function(script->layouts[i].function));
    }
  }
  script->layout_count = 0;
}

static JanetFunction *find_layout(TriadJanetScript *script, const char *layout_name) {
  if (script == NULL || layout_name == NULL) return NULL;
  for (int i = 0; i < script->layout_count; i++) {
    if (strcmp(script->layouts[i].name, layout_name) == 0) {
      return script->layouts[i].function;
    }
  }
  return NULL;
}

static int parse_wait_event(Janet value, char **event_name) {
  const Janet *items = NULL;
  int32_t len = 0;
  if (!janet_indexed_view(value, &items, &len) || len != 2) return 0;
  if (!janet_checktype(items[0], JANET_KEYWORD) ||
      janet_cstrcmp(janet_unwrap_keyword(items[0]), "triad/wait-event") != 0) {
    return 0;
  }
  if (!janet_checktype(items[1], JANET_KEYWORD)) return 0;
  *event_name = copy_janet_string(janet_unwrap_keyword(items[1]));
  return *event_name != NULL;
}

static int append_waiter(
    TriadJanetRuntime *runtime,
    TriadJanetScript *script,
    JanetFiber *fiber,
    char *event_name,
    int rooted) {
  if (script->waiter_count >= TRIAD_JANET_MAX_WAITERS) {
    if (rooted) janet_gcunroot(janet_wrap_fiber(fiber));
    free(event_name);
    set_error(runtime, "Janet script exceeded waiter limit");
    return 0;
  }
  if (script->waiter_count == script->waiter_capacity) {
    int new_capacity =
      script->waiter_capacity == 0 ? 4 : script->waiter_capacity * 2;
    TriadJanetWaiter *new_waiters = (TriadJanetWaiter *) realloc(
      script->waiters, sizeof(TriadJanetWaiter) * (size_t) new_capacity);
    if (new_waiters == NULL) {
      if (rooted) janet_gcunroot(janet_wrap_fiber(fiber));
      free(event_name);
      set_error(runtime, "failed to append Janet waiter");
      return 0;
    }
    script->waiters = new_waiters;
    script->waiter_capacity = new_capacity;
  }
  if (!rooted) janet_gcroot(janet_wrap_fiber(fiber));
  TriadJanetWaiter waiter;
  waiter.fiber = fiber;
  waiter.event_name = event_name;
  script->waiters[script->waiter_count++] = waiter;
  return 1;
}

static int signal_failed(TriadJanetRuntime *runtime, JanetSignal signal, Janet out) {
  if (runtime->last_error == NULL || runtime->last_error[0] == '\0') {
    JanetString desc = janet_description(out);
    char *message = copy_janet_string(desc);
    set_error(
      runtime,
      message == NULL || message[0] == '\0' ? janet_signal_names[signal] : message);
    if (message != NULL) free(message);
  }
  return 0;
}

static int handle_signal(
    TriadJanetRuntime *runtime,
    TriadJanetScript *script,
    JanetFiber *fiber,
    JanetSignal signal,
    Janet out,
    int rooted) {
  if (signal == JANET_SIGNAL_OK) {
    if (rooted) janet_gcunroot(janet_wrap_fiber(fiber));
    return 1;
  }
  if (signal == JANET_SIGNAL_YIELD) {
    char *event_name = NULL;
    if (!parse_wait_event(out, &event_name)) {
      if (rooted) janet_gcunroot(janet_wrap_fiber(fiber));
      set_error(runtime, "Janet hook yielded unsupported value");
      return 0;
    }
    return append_waiter(runtime, script, fiber, event_name, rooted);
  }
  if (rooted) janet_gcunroot(janet_wrap_fiber(fiber));
  return signal_failed(runtime, signal, out);
}

static TriadJanetWaiter take_waiter(TriadJanetScript *script, int index) {
  TriadJanetWaiter waiter = script->waiters[index];
  for (int i = index + 1; i < script->waiter_count; i++) {
    script->waiters[i - 1] = script->waiters[i];
  }
  script->waiter_count--;
  memset(&script->waiters[script->waiter_count], 0, sizeof(TriadJanetWaiter));
  return waiter;
}

static int resume_waiters(
    TriadJanetRuntime *runtime,
    TriadJanetScript *script,
    const char *event_name,
    Janet event_value,
    const char *path,
    int32_t fuel_limit) {
  (void) path;
  int index = 0;
  int initial_count = script->waiter_count;
  while (index < script->waiter_count && index < initial_count) {
    if (strcmp(script->waiters[index].event_name, event_name) != 0) {
      index++;
      continue;
    }
    TriadJanetWaiter waiter = take_waiter(script, index);
    Janet out;
    JanetSignal signal = continue_with_timer(
      runtime, waiter.fiber, event_value, fuel_limit, &out);
    free(waiter.event_name);
    waiter.event_name = NULL;
    if (!handle_signal(runtime, script, waiter.fiber, signal, out, 1)) {
      return 0;
    }
    initial_count--;
  }
  return 1;
}

static int dispatch_handlers(
    TriadJanetRuntime *runtime,
    TriadJanetScript *script,
    const char *event_name,
    Janet event_value,
    int32_t fuel_limit) {
  TriadJanetHandlerList *list = NULL;
  for (int i = 0; i < script->handler_list_count; i++) {
    if (strcmp(script->handler_lists[i].event_name, event_name) == 0) {
      list = &script->handler_lists[i];
      break;
    }
  }
  if (list == NULL) return 1;

  int handler_count = list->handler_count;
  for (int32_t i = 0; i < handler_count; i++) {
    Janet out;
    JanetFiber *fiber = NULL;
    JanetSignal signal = pcall_with_timer(
      runtime,
      list->handlers[i],
      1,
      &event_value,
      fuel_limit,
      &out,
      &fiber);
    if (!handle_signal(runtime, script, fiber, signal, out, 0)) {
      return 0;
    }
  }
  return 1;
}

static int janet_number_to_int32(Janet value, int32_t *out) {
  if (!janet_checktype(value, JANET_NUMBER)) return 0;
  double number = janet_unwrap_number(value);
  if (number < (double) INT32_MIN || number > (double) INT32_MAX) return 0;
  int32_t integer = (int32_t) number;
  if ((double) integer != number) return 0;
  *out = integer;
  return 1;
}

static int janet_number_to_uint32(Janet value, uint32_t *out) {
  if (!janet_checktype(value, JANET_NUMBER)) return 0;
  double number = janet_unwrap_number(value);
  if (number < 0.0 || number > (double) UINT32_MAX) return 0;
  uint32_t integer = (uint32_t) number;
  if ((double) integer != number) return 0;
  *out = integer;
  return 1;
}

static Janet get_instruction_field(Janet instruction, const char *name) {
  return janet_get(instruction, janet_ckeywordv(name));
}

static int parse_layout_instruction(
    TriadJanetRuntime *runtime,
    Janet value,
    TriadJanetLayoutInstruction *instruction) {
  Janet window_id = get_instruction_field(value, "window-id");
  if (janet_checktype(window_id, JANET_NIL)) {
    window_id = get_instruction_field(value, "window");
  }
  if (!janet_number_to_uint32(window_id, &instruction->window_id) ||
      !janet_number_to_int32(get_instruction_field(value, "x"), &instruction->x) ||
      !janet_number_to_int32(get_instruction_field(value, "y"), &instruction->y) ||
      !janet_number_to_int32(get_instruction_field(value, "w"), &instruction->w) ||
      !janet_number_to_int32(get_instruction_field(value, "h"), &instruction->h)) {
    set_error(runtime, "Janet layout returned invalid instruction fields");
    return 0;
  }
  return 1;
}

static int extract_layout_result(TriadJanetRuntime *runtime, Janet value) {
  const Janet *items = NULL;
  int32_t len = 0;
  if (!janet_indexed_view(value, &items, &len)) {
    set_error(runtime, "Janet layout must return an indexed sequence");
    return 0;
  }
  for (int32_t i = 0; i < len; i++) {
    TriadJanetLayoutInstruction instruction;
    memset(&instruction, 0, sizeof(instruction));
    if (!parse_layout_instruction(runtime, items[i], &instruction)) {
      return 0;
    }
    if (!append_layout_instruction(runtime, instruction)) {
      set_error(runtime, "failed to append Janet layout instruction");
      return 0;
    }
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
  if (runtime->layout_instructions != NULL) free(runtime->layout_instructions);
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
  current_script = script;
  if (!eval_source(runtime, script->env, bootstrap_source, path)) {
    current_runtime = NULL;
    current_script = NULL;
    triad_janet_script_free(script);
    return NULL;
  }
  Janet out;
  if (!eval_source_with_timer(runtime, script->env, source, path, fuel_limit, &out)) {
    if (runtime->last_error == NULL || runtime->last_error[0] == '\0') {
      set_error(runtime, "Janet script load failed");
    }
    current_runtime = NULL;
    current_script = NULL;
    triad_janet_script_free(script);
    return NULL;
  }
  current_runtime = NULL;
  current_script = NULL;
  clear_runtime(runtime);
  return script;
}

int triad_janet_script_dispatch(void *runtime_ptr, void *script_ptr, const char *event_name, const char *event_source, const char *path, int32_t fuel_limit) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  TriadJanetScript *script = (TriadJanetScript *) script_ptr;
  if (runtime == NULL || script == NULL || script->env == NULL) return 0;
  clear_runtime(runtime);
  harden_sandbox();

  current_runtime = runtime;
  current_script = script;
  if (!eval_source(runtime, script->env, event_source, path)) {
    current_runtime = NULL;
    current_script = NULL;
    return 0;
  }
  Janet event_value =
    resolve_env_symbol(script->env, "triad/current-event");
  if (!resume_waiters(runtime, script, event_name, event_value, path, fuel_limit)) {
    current_runtime = NULL;
    current_script = NULL;
    return 0;
  }
  if (!dispatch_handlers(runtime, script, event_name, event_value, fuel_limit)) {
    current_runtime = NULL;
    current_script = NULL;
    return 0;
  }
  current_runtime = NULL;
  current_script = NULL;
  return 1;
}

int triad_janet_script_has_layout(void *script_ptr, const char *layout_name) {
  TriadJanetScript *script = (TriadJanetScript *) script_ptr;
  return find_layout(script, layout_name) != NULL ? 1 : 0;
}

int triad_janet_script_eval_layout(void *runtime_ptr, void *script_ptr, const char *layout_name, const char *context_source, const char *path, int32_t fuel_limit) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  TriadJanetScript *script = (TriadJanetScript *) script_ptr;
  if (runtime == NULL || script == NULL || script->env == NULL) return 0;
  clear_runtime(runtime);
  harden_sandbox();

  JanetFunction *layout = find_layout(script, layout_name);
  if (layout == NULL) {
    set_error(runtime, "Janet layout is not registered");
    return 0;
  }

  current_runtime = runtime;
  current_script = script;
  if (!eval_source(runtime, script->env, context_source, path)) {
    current_runtime = NULL;
    current_script = NULL;
    return 0;
  }
  Janet context = resolve_env_symbol(script->env, "triad/current-layout-context");
  Janet out;
  JanetFiber *fiber = NULL;
  JanetSignal signal = pcall_with_timer(
    runtime,
    layout,
    1,
    &context,
    fuel_limit,
    &out,
    &fiber);
  current_runtime = NULL;
  current_script = NULL;
  if (signal != JANET_SIGNAL_OK) {
    return signal_failed(runtime, signal, out);
  }
  if (runtime->action_count > 0) {
    set_error(runtime, "Janet layout emitted Triad commands");
    return 0;
  }
  return extract_layout_result(runtime, out);
}

void triad_janet_script_free(void *script_ptr) {
  TriadJanetScript *script = (TriadJanetScript *) script_ptr;
  if (script == NULL) return;
  clear_waiters(script);
  if (script->waiters != NULL) free(script->waiters);
  clear_handlers(script);
  if (script->handler_lists != NULL) free(script->handler_lists);
  clear_layouts(script);
  if (script->layouts != NULL) free(script->layouts);
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

int triad_janet_layout_instruction_count(void *runtime_ptr) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL) return 0;
  return runtime->layout_instruction_count;
}

uint32_t triad_janet_layout_window_id(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->layout_instruction_count) {
    return 0;
  }
  return runtime->layout_instructions[index].window_id;
}

int32_t triad_janet_layout_x(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->layout_instruction_count) {
    return 0;
  }
  return runtime->layout_instructions[index].x;
}

int32_t triad_janet_layout_y(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->layout_instruction_count) {
    return 0;
  }
  return runtime->layout_instructions[index].y;
}

int32_t triad_janet_layout_w(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->layout_instruction_count) {
    return 0;
  }
  return runtime->layout_instructions[index].w;
}

int32_t triad_janet_layout_h(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->layout_instruction_count) {
    return 0;
  }
  return runtime->layout_instructions[index].h;
}
