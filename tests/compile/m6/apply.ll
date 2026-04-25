; ModuleID = 'cronyx'
source_filename = "cronyx"

%__closure = type { ptr, ptr }

@fmt_int = private constant [6 x i8] c"%lld\0A\00"

declare i32 @printf(ptr, ...)

declare ptr @malloc(i64)

declare void @free(ptr)

declare void @abort()

define i64 @__lambda_9(ptr %0, i64 %1) {
entry:
  %x = alloca i64, align 8
  store i64 %1, ptr %x, align 4
  %x1 = load i64, ptr %x, align 4
  %mul = mul i64 %x1, 2
  ret i64 %mul
}

define i64 @apply(ptr %0, i64 %1) {
entry:
  %f = alloca ptr, align 8
  store ptr %0, ptr %f, align 8
  %x = alloca i64, align 8
  store i64 %1, ptr %x, align 4
  %closure = load ptr, ptr %f, align 8
  %fn_ptr_field = getelementptr %__closure, ptr %closure, i32 0, i32 0
  %fn_ptr = load ptr, ptr %fn_ptr_field, align 8
  %env_ptr_field = getelementptr %__closure, ptr %closure, i32 0, i32 1
  %env_ptr = load ptr, ptr %env_ptr_field, align 8
  %x1 = load i64, ptr %x, align 4
  %closure_call = call i64 %fn_ptr(ptr %env_ptr, i64 %x1)
  ret i64 %closure_call
}

define i32 @main() {
entry:
  %closure_malloc = call ptr @malloc(i64 ptrtoint (ptr getelementptr (%__closure, ptr null, i32 1) to i64))
  %fn_ptr_field = getelementptr %__closure, ptr %closure_malloc, i32 0, i32 0
  store ptr @__lambda_9, ptr %fn_ptr_field, align 8
  %env_ptr_field = getelementptr %__closure, ptr %closure_malloc, i32 0, i32 1
  store ptr null, ptr %env_ptr_field, align 8
  %double = alloca ptr, align 8
  store ptr %closure_malloc, ptr %double, align 8
  %double1 = load ptr, ptr %double, align 8
  %call = call i64 @apply(ptr %double1, i64 21)
  %printf_ret = call i32 (ptr, ...) @printf(ptr @fmt_int, i64 %call)
  ret i32 0
}
