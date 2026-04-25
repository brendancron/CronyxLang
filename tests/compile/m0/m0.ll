; ModuleID = 'cronyx'
source_filename = "cronyx"

@fmt_int = private constant [6 x i8] c"%lld\0A\00"

declare i32 @printf(ptr, ...)

declare void @abort()

define i32 @main() {
entry:
  %printf_ret = call i32 (ptr, ...) @printf(ptr @fmt_int, i64 3)
  ret i32 0
}
