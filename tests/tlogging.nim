import chronicles, options, unittest
import ../src/utils/runtime_log

suite "Runtime logging":
  test "parses supported log levels":
    check parseLogLevel("trace").get() == TRACE
    check parseLogLevel("DEBUG").get() == DEBUG
    check parseLogLevel("info").get() == INFO
    check parseLogLevel("notice").get() == NOTICE
    check parseLogLevel("warning").get() == WARN
    check parseLogLevel("error").get() == ERROR
    check parseLogLevel("fatal").get() == FATAL

  test "rejects invalid log levels":
    check parseLogLevel("").isNone
    check parseLogLevel("verbose").isNone
    check parseLogLevel("everything").isNone
