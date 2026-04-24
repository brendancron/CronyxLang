; ModuleID = 'cronyx'
source_filename = "cronyx"

%Point = type { i64, i64 }

@fmt_int = private constant [6 x i8] c"%lld\0A\00"

declare i32 @printf(ptr, ...)

declare ptr @malloc(i64)

declare void @free(ptr)

declare void @abort()

define i64 @distance_sq(ptr %0) {
entry:
  %p = alloca ptr, align 8
  store ptr %0, ptr %p, align 8
  %p1 = load ptr, ptr %p, align 8
  %x_ptr = getelementptr %Point, ptr %p1, i32 0, i32 0
  %x = load i64, ptr %x_ptr, align 4
  %p2 = load ptr, ptr %p, align 8
  %x_ptr3 = getelementptr %Point, ptr %p2, i32 0, i32 0
  %x4 = load i64, ptr %x_ptr3, align 4
  %mul = mul i64 %x, %x4
  %p5 = load ptr, ptr %p, align 8
  %y_ptr = getelementptr %Point, ptr %p5, i32 0, i32 1
  %y = load i64, ptr %y_ptr, align 4
  %p6 = load ptr, ptr %p, align 8
  %y_ptr7 = getelementptr %Point, ptr %p6, i32 0, i32 1
  %y8 = load i64, ptr %y_ptr7, align 4
  %mul9 = mul i64 %y, %y8
  %add = add i64 %mul, %mul9
  ret i64 %add
}

define i32 @main() {
entry:
  %malloc = call ptr @malloc(i64 ptrtoint (ptr getelementptr (%Point, ptr null, i32 1) to i64))
  %x_ptr = getelementptr %Point, ptr %malloc, i32 0, i32 0
  store i64 3, ptr %x_ptr, align 4
  %y_ptr = getelementptr %Point, ptr %malloc, i32 0, i32 1
  store i64 4, ptr %y_ptr, align 4
  %p = alloca ptr, align 8
  store ptr %malloc, ptr %p, align 8
  %p1 = load ptr, ptr %p, align 8
  %call = call i64 @distance_sq(ptr %p1)
  %printf_ret = call i32 (ptr, ...) @printf(ptr @fmt_int, i64 %call)
  %p2 = load ptr, ptr %p, align 8
  call void @free(ptr %p2)
  ret i32 0
}
