#include <janet.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum {
  TRIAD_JANET_MOVE_TO_TAG = 1,
  TRIAD_JANET_MOVE_TO_WORKSPACE = 2,
  TRIAD_JANET_FOCUS_TAG = 3,
  TRIAD_JANET_SET_LAYOUT = 4,
  TRIAD_JANET_TOGGLE_FLOATING = 5,
  TRIAD_JANET_SPAWN = 6,
  TRIAD_JANET_MOVE_WINDOW_TO_TAG = 7,
  TRIAD_JANET_MOVE_WINDOW_TO_WORKSPACE = 8,
  TRIAD_JANET_SET_WINDOW_FLOATING = 9,
  TRIAD_JANET_SET_LAYOUT_FOR_WORKSPACE = 10,
  TRIAD_JANET_FOCUS_WINDOW = 11,
  TRIAD_JANET_SET_WINDOW_MAXIMIZED = 12
};

typedef struct {
  int kind;
  uint32_t u32_value;
  uint32_t u32_value2;
  int bool_value;
  char *text;
  int argc;
  char **argv;
} TriadJanetAction;

typedef struct {
  TriadJanetAction *actions;
  int action_count;
  int action_capacity;
  char *last_error;
} TriadJanetRuntime;

static TriadJanetRuntime *current_runtime = NULL;
static int janet_init_count = 0;

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

static void free_action(TriadJanetAction *action) {
  if (action->text != NULL) free(action->text);
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

static uint32_t get_u32_arg(Janet *argv, int32_t n) {
  double value = janet_getnumber(argv, n);
  if (value <= 0 || value > 4294967295.0 || floor(value) != value) {
    janet_panic("expected a positive 32 bit unsigned integer");
  }
  return (uint32_t) value;
}

static int get_optional_bool_arg(Janet *argv, int32_t argc, int32_t n, int fallback) {
  if (argc <= n) return fallback;
  return janet_getboolean(argv, n) ? 1 : 0;
}

static Janet c_move_to_tag(int32_t argc, Janet *argv) {
  janet_arity(argc, 1, 1);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_MOVE_TO_TAG;
  action.u32_value = get_u32_arg(argv, 0);
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static Janet c_move_to_workspace(int32_t argc, Janet *argv) {
  janet_arity(argc, 1, 1);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_MOVE_TO_WORKSPACE;
  action.u32_value = get_u32_arg(argv, 0);
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static Janet c_focus_tag(int32_t argc, Janet *argv) {
  janet_arity(argc, 1, 1);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_FOCUS_TAG;
  action.u32_value = get_u32_arg(argv, 0);
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static Janet c_set_layout(int32_t argc, Janet *argv) {
  janet_arity(argc, 1, 1);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_SET_LAYOUT;
  action.text = copy_cstring(janet_getcstring(argv, 0));
  if (action.text == NULL || !append_action(current_runtime, action)) {
    free_action(&action);
    janet_panic("failed to append action");
  }
  return janet_wrap_nil();
}

static Janet c_toggle_floating(int32_t argc, Janet *argv) {
  (void) argv;
  janet_arity(argc, 0, 0);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_TOGGLE_FLOATING;
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static Janet c_spawn(int32_t argc, Janet *argv) {
  janet_arity(argc, 1, INT32_MAX);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_SPAWN;
  action.argc = argc;
  action.argv = (char **) calloc((size_t) argc, sizeof(char *));
  if (action.argv == NULL) janet_panic("failed to append action");
  for (int32_t i = 0; i < argc; i++) {
    action.argv[i] = copy_cstring(janet_getcstring(argv, i));
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

static Janet c_move_window_to_tag(int32_t argc, Janet *argv) {
  janet_arity(argc, 2, 3);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_MOVE_WINDOW_TO_TAG;
  action.u32_value = get_u32_arg(argv, 0);
  action.u32_value2 = get_u32_arg(argv, 1);
  action.bool_value = get_optional_bool_arg(argv, argc, 2, 0);
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static Janet c_move_window_to_workspace(int32_t argc, Janet *argv) {
  janet_arity(argc, 2, 3);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_MOVE_WINDOW_TO_WORKSPACE;
  action.u32_value = get_u32_arg(argv, 0);
  action.u32_value2 = get_u32_arg(argv, 1);
  action.bool_value = get_optional_bool_arg(argv, argc, 2, 0);
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static Janet c_set_window_floating(int32_t argc, Janet *argv) {
  janet_arity(argc, 2, 2);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_SET_WINDOW_FLOATING;
  action.u32_value = get_u32_arg(argv, 0);
  action.bool_value = janet_getboolean(argv, 1) ? 1 : 0;
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static Janet c_set_window_maximized(int32_t argc, Janet *argv) {
  janet_arity(argc, 2, 2);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_SET_WINDOW_MAXIMIZED;
  action.u32_value = get_u32_arg(argv, 0);
  action.bool_value = janet_getboolean(argv, 1) ? 1 : 0;
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static Janet c_set_layout_for_workspace(int32_t argc, Janet *argv) {
  janet_arity(argc, 2, 2);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_SET_LAYOUT_FOR_WORKSPACE;
  action.u32_value = get_u32_arg(argv, 0);
  action.text = copy_cstring(janet_getcstring(argv, 1));
  if (action.text == NULL || !append_action(current_runtime, action)) {
    free_action(&action);
    janet_panic("failed to append action");
  }
  return janet_wrap_nil();
}

static Janet c_focus_window(int32_t argc, Janet *argv) {
  janet_arity(argc, 1, 1);
  TriadJanetAction action;
  memset(&action, 0, sizeof(action));
  action.kind = TRIAD_JANET_FOCUS_WINDOW;
  action.u32_value = get_u32_arg(argv, 0);
  if (!append_action(current_runtime, action)) janet_panic("failed to append action");
  return janet_wrap_nil();
}

static const JanetReg triad_cfuns[] = {
  {"triad/move-to-tag", c_move_to_tag, NULL},
  {"triad/move-to-workspace", c_move_to_workspace, NULL},
  {"triad/focus-tag", c_focus_tag, NULL},
  {"triad/set-layout", c_set_layout, NULL},
  {"triad/toggle-floating", c_toggle_floating, NULL},
  {"triad/spawn", c_spawn, NULL},
  {"triad/move-window-to-tag", c_move_window_to_tag, NULL},
  {"triad/move-window-to-workspace", c_move_window_to_workspace, NULL},
  {"triad/set-window-floating", c_set_window_floating, NULL},
  {"triad/set-window-maximized", c_set_window_maximized, NULL},
  {"triad/set-layout-for-workspace", c_set_layout_for_workspace, NULL},
  {"triad/focus-window", c_focus_window, NULL},
  {NULL, NULL, NULL}
};

static void remove_symbol(JanetTable *env, const char *name) {
  janet_table_remove(env, janet_csymbolv(name));
}

static void scrub_env(JanetTable *env) {
  const char *blocked[] = {
    "dofile", "require", "import", "use", "os/execute", "os/spawn", "os/shell",
    "os/exit", "os/getenv", "os/setenv", "os/environ", "file/open", "file/read",
    "file/write", "file/close", "file/seek", "file/stat", "file/rm", "file/mkdir",
    "file/temp", "slurp", "spit", "native", "native/lookup", "native/load",
    "ffi/open", "ffi/lookup", "net/connect", "net/listen", NULL
  };
  for (int i = 0; blocked[i] != NULL; i++) {
    remove_symbol(env, blocked[i]);
  }
}

static int script_has_blocked_loop(const char *source) {
  return strstr(source, "(while") != NULL || strstr(source, "(forever") != NULL;
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
  (void) fuel_limit;
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL) return 0;
  clear_runtime(runtime);
  if (script_has_blocked_loop(source)) {
    set_error(runtime, "script contains a loop form blocked by the current Janet runtime guard");
    return 0;
  }

  JanetTable *env = janet_core_env(NULL);
  scrub_env(env);
  janet_cfuns(env, NULL, triad_cfuns);

  Janet out;
  current_runtime = runtime;
  int status = janet_dostring(env, snapshot_source, path, &out);
  if (status == 0) {
    status = janet_dostring(env, source, path, &out);
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

uint32_t triad_janet_action_u32(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->action_count) return 0;
  return runtime->actions[index].u32_value;
}

uint32_t triad_janet_action_u32_b(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->action_count) return 0;
  return runtime->actions[index].u32_value2;
}

int triad_janet_action_bool(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->action_count) return 0;
  return runtime->actions[index].bool_value;
}

const char *triad_janet_action_text(void *runtime_ptr, int index) {
  TriadJanetRuntime *runtime = (TriadJanetRuntime *) runtime_ptr;
  if (runtime == NULL || index < 0 || index >= runtime->action_count) return "";
  return runtime->actions[index].text == NULL ? "" : runtime->actions[index].text;
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
