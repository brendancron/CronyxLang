; ModuleID = 'cronyx'
source_filename = "cronyx"

%__slice = type { i64, i64, ptr }

@fmt_int = private constant [6 x i8] c"%lld\0A\00"

declare i32 @printf(ptr, ...)

declare ptr @malloc(i64)

declare void @free(ptr)

define i64 @sum(ptr %0) {
entry:
  %xs = alloca ptr, align 8
  store ptr %0, ptr %xs, align 8
  %total = alloca i64, align 8
  store i64 0, ptr %total, align 4
  %xs1 = load ptr, ptr %xs, align 8
  %len_ptr = getelementptr %__slice, ptr %xs1, i32 0, i32 0
  %len = load i64, ptr %len_ptr, align 4
  %data_field_ptr = getelementptr %__slice, ptr %xs1, i32 0, i32 2
  %data = load ptr, ptr %data_field_ptr, align 8
  %__i = alloca i64, align 8
  store i64 0, ptr %__i, align 4
  %x = alloca i64, align 8
  br label %foreach_cond

foreach_cond:                                     ; preds = %foreach_body, %entry
  %i = load i64, ptr %__i, align 4
  %lt = icmp slt i64 %i, %len
  br i1 %lt, label %foreach_body, label %foreach_exit

foreach_body:                                     ; preds = %foreach_cond
  %i2 = load i64, ptr %__i, align 4
  %elem_ptr = getelementptr i64, ptr %data, i64 %i2
  %x3 = load i64, ptr %elem_ptr, align 4
  store i64 %x3, ptr %x, align 4
  %total4 = load i64, ptr %total, align 4
  %x5 = load i64, ptr %x, align 4
  %add = add i64 %total4, %x5
  store i64 %add, ptr %total, align 4
  %i6 = load i64, ptr %__i, align 4
  %i_next = add i64 %i6, 1
  store i64 %i_next, ptr %__i, align 4
  br label %foreach_cond

foreach_exit:                                     ; preds = %foreach_cond
  %total7 = load i64, ptr %total, align 4
  ret i64 %total7
}

define i32 @main() {
entry:
  %data_malloc = call ptr @malloc(i64 40)
  %elem0_ptr = getelementptr i64, ptr %data_malloc, i64 0
  store i64 1, ptr %elem0_ptr, align 4
  %elem1_ptr = getelementptr i64, ptr %data_malloc, i64 1
  store i64 2, ptr %elem1_ptr, align 4
  %elem2_ptr = getelementptr i64, ptr %data_malloc, i64 2
  store i64 3, ptr %elem2_ptr, align 4
  %elem3_ptr = getelementptr i64, ptr %data_malloc, i64 3
  store i64 4, ptr %elem3_ptr, align 4
  %elem4_ptr = getelementptr i64, ptr %data_malloc, i64 4
  store i64 5, ptr %elem4_ptr, align 4
  %slice_malloc = call ptr @malloc(i64 ptrtoint (ptr getelementptr (%__slice, ptr null, i32 1) to i64))
  %len_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 0
  store i64 5, ptr %len_ptr, align 4
  %cap_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 1
  store i64 5, ptr %cap_ptr, align 4
  %data_field_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 2
  store ptr %data_malloc, ptr %data_field_ptr, align 8
  %nums = alloca ptr, align 8
  store ptr %slice_malloc, ptr %nums, align 8
  %nums1 = load ptr, ptr %nums, align 8
  %call = call i64 @sum(ptr %nums1)
  %printf_ret = call i32 (ptr, ...) @printf(ptr @fmt_int, i64 %call)
  %nums2 = load ptr, ptr %nums, align 8
  call void @free(ptr %nums2)
  ret i32 0
}
