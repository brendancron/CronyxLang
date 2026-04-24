; ModuleID = 'cronyx'
source_filename = "cronyx"

@fmt_int = private constant [6 x i8] c"%lld\0A\00"

declare i32 @printf(ptr, ...)

declare void @abort()

define i64 @factorial(i64 %0) {
entry:
  %n = alloca i64, align 8
  store i64 %0, ptr %n, align 4
  %result = alloca i64, align 8
  store i64 1, ptr %result, align 4
  %i = alloca i64, align 8
  store i64 1, ptr %i, align 4
  br label %loop_cond

loop_cond:                                        ; preds = %loop_body, %entry
  %i1 = load i64, ptr %i, align 4
  %n2 = load i64, ptr %n, align 4
  %lte = icmp sle i64 %i1, %n2
  br i1 %lte, label %loop_body, label %loop_exit

loop_body:                                        ; preds = %loop_cond
  %result3 = load i64, ptr %result, align 4
  %i4 = load i64, ptr %i, align 4
  %mul = mul i64 %result3, %i4
  store i64 %mul, ptr %result, align 4
  %i5 = load i64, ptr %i, align 4
  %add = add i64 %i5, 1
  store i64 %add, ptr %i, align 4
  br label %loop_cond

loop_exit:                                        ; preds = %loop_cond
  %result6 = load i64, ptr %result, align 4
  ret i64 %result6
}

define i32 @main() {
entry:
  %call = call i64 @factorial(i64 10)
  %printf_ret = call i32 (ptr, ...) @printf(ptr @fmt_int, i64 %call)
  ret i32 0
}
