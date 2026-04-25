; ModuleID = 'cronyx'
source_filename = "cronyx"

@fmt_int = private constant [6 x i8] c"%lld\0A\00"
@fmt_str = private constant [4 x i8] c"%s\0A\00"
@fmt_int_bare = private constant [5 x i8] c"%lld\00"
@.str.0 = private constant [10 x i8] c"Blastoff!\00"

declare i32 @printf(ptr, ...)

declare ptr @malloc(i64)

declare void @free(ptr)

declare i64 @strlen(ptr)

declare ptr @strcpy(ptr, ptr)

declare ptr @strcat(ptr, ptr)

declare i32 @strcmp(ptr, ptr)

declare ptr @strstr(ptr, ptr)

declare i32 @sprintf(ptr, ptr, ...)

declare ptr @memcpy(ptr, ptr, i64)

declare i64 @atoll(ptr)

declare void @abort()

define i64 @count_down(i64 %0) {
entry:
  %n = alloca i64, align 8
  store i64 %0, ptr %n, align 4
  %n1 = load i64, ptr %n, align 4
  %i = alloca i64, align 8
  store i64 %n1, ptr %i, align 4
  br label %loop_cond

loop_cond:                                        ; preds = %loop_body, %entry
  %i2 = load i64, ptr %i, align 4
  %gt = icmp sgt i64 %i2, 0
  br i1 %gt, label %loop_body, label %loop_exit

loop_body:                                        ; preds = %loop_cond
  %i3 = load i64, ptr %i, align 4
  %printf_ret = call i32 (ptr, ...) @printf(ptr @fmt_int, i64 %i3)
  %i4 = load i64, ptr %i, align 4
  %sub = sub i64 %i4, 1
  store i64 %sub, ptr %i, align 4
  br label %loop_cond

loop_exit:                                        ; preds = %loop_cond
  %printf_ret5 = call i32 (ptr, ...) @printf(ptr @fmt_str, ptr @.str.0)
  ret i64 0
}

define i32 @main() {
entry:
  %call = call i64 @count_down(i64 3)
  ret i32 0
}
