; ModuleID = 'cronyx'
source_filename = "cronyx"

@fmt_int = private constant [6 x i8] c"%lld\0A\00"

declare i32 @printf(ptr, ...)

declare void @abort()

define i64 @fib(i64 %0) {
entry:
  %n = alloca i64, align 8
  store i64 %0, ptr %n, align 4
  %n1 = load i64, ptr %n, align 4
  %lte = icmp sle i64 %n1, 1
  br i1 %lte, label %then, label %merge

then:                                             ; preds = %entry
  %n2 = load i64, ptr %n, align 4
  ret i64 %n2

merge:                                            ; preds = %entry
  %n3 = load i64, ptr %n, align 4
  %sub = sub i64 %n3, 1
  %call = call i64 @fib(i64 %sub)
  %n4 = load i64, ptr %n, align 4
  %sub5 = sub i64 %n4, 2
  %call6 = call i64 @fib(i64 %sub5)
  %add = add i64 %call, %call6
  ret i64 %add
}

define i32 @main() {
entry:
  %call = call i64 @fib(i64 10)
  %printf_ret = call i32 (ptr, ...) @printf(ptr @fmt_int, i64 %call)
  ret i32 0
}
