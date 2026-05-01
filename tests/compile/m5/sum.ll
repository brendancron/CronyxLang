; ModuleID = 'cronyx'
source_filename = "cronyx"

%__slice = type { i64, i64, ptr }
%StringBuilder = type { i64, i64 }

@fmt_int = private constant [6 x i8] c"%lld\0A\00"
@fmt_str = private constant [4 x i8] c"%s\0A\00"
@fmt_int_bare = private constant [5 x i8] c"%lld\00"
@.str.0 = private constant [1 x i8] zeroinitializer
@.str.1 = private constant [2 x i8] c"\0A\00"

declare i32 @printf(ptr, ...)

declare ptr @malloc(i64)

declare void @free(ptr)

declare ptr @realloc(ptr, i64)

declare i64 @strlen(ptr)

declare ptr @strcpy(ptr, ptr)

declare ptr @strcat(ptr, ptr)

declare i32 @strcmp(ptr, ptr)

declare ptr @strstr(ptr, ptr)

declare i32 @sprintf(ptr, ptr, ...)

declare ptr @memcpy(ptr, ptr, i64)

declare i64 @atoll(ptr)

declare void @abort()

define i64 @min(i64 %0, i64 %1) {
entry:
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 4
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 4
  %a1 = load i64, ptr %a, align 4
  %b2 = load i64, ptr %b, align 4
  %lt = icmp slt i64 %a1, %b2
  br i1 %lt, label %then, label %merge

then:                                             ; preds = %entry
  %a3 = load i64, ptr %a, align 4
  ret i64 %a3

merge:                                            ; preds = %entry
  %b4 = load i64, ptr %b, align 4
  ret i64 %b4
}

define i64 @max(i64 %0, i64 %1) {
entry:
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 4
  %b = alloca i64, align 8
  store i64 %1, ptr %b, align 4
  %a1 = load i64, ptr %a, align 4
  %b2 = load i64, ptr %b, align 4
  %gt = icmp sgt i64 %a1, %b2
  br i1 %gt, label %then, label %merge

then:                                             ; preds = %entry
  %a3 = load i64, ptr %a, align 4
  ret i64 %a3

merge:                                            ; preds = %entry
  %b4 = load i64, ptr %b, align 4
  ret i64 %b4
}

define i64 @abs(i64 %0) {
entry:
  %a = alloca i64, align 8
  store i64 %0, ptr %a, align 4
  %a1 = load i64, ptr %a, align 4
  %lt = icmp slt i64 %a1, 0
  br i1 %lt, label %then, label %merge

then:                                             ; preds = %entry
  %a2 = load i64, ptr %a, align 4
  %sub = sub i64 0, %a2
  ret i64 %sub

merge:                                            ; preds = %entry
  %a3 = load i64, ptr %a, align 4
  ret i64 %a3
}

define i64 @substring(i64 %0, i64 %1, i64 %2) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 4
  %start = alloca i64, align 8
  store i64 %1, ptr %start, align 4
  %end = alloca i64, align 8
  store i64 %2, ptr %end, align 4
  %s1 = load i64, ptr %s, align 4
  %int_to_str_ptr = inttoptr i64 %s1 to ptr
  %chars = call ptr @__cronyx_chars(ptr %int_to_str_ptr)
  %chars2 = alloca ptr, align 8
  store ptr %chars, ptr %chars2, align 8
  %ns_call = call ptr @new()
  %sb = alloca ptr, align 8
  store ptr %ns_call, ptr %sb, align 8
  %start3 = load i64, ptr %start, align 4
  %i = alloca i64, align 8
  store i64 %start3, ptr %i, align 4
  br label %loop_cond

loop_cond:                                        ; preds = %loop_body, %entry
  %i4 = load i64, ptr %i, align 4
  %end5 = load i64, ptr %end, align 4
  %lt = icmp slt i64 %i4, %end5
  br i1 %lt, label %loop_body, label %loop_exit

loop_body:                                        ; preds = %loop_cond
  %sb6 = load ptr, ptr %sb, align 8
  %chars7 = load ptr, ptr %chars2, align 8
  %i8 = load i64, ptr %i, align 4
  %len_field = getelementptr %__slice, ptr %chars7, i32 0, i32 0
  %len = load i64, ptr %len_field, align 4
  %is_neg = icmp slt i64 %i8, 0
  %adj_idx = add i64 %len, %i8
  %eff_idx = select i1 %is_neg, i64 %adj_idx, i64 %i8
  %data_field = getelementptr %__slice, ptr %chars7, i32 0, i32 2
  %data = load ptr, ptr %data_field, align 8
  %elem_ptr = getelementptr ptr, ptr %data, i64 %eff_idx
  %elem = load ptr, ptr %elem_ptr, align 8
  %method_call = call i64 @StringBuilder__append(ptr %sb6, ptr %elem)
  %i9 = load i64, ptr %i, align 4
  %add = add i64 %i9, 1
  store i64 %add, ptr %i, align 4
  br label %loop_cond

loop_exit:                                        ; preds = %loop_cond
  %sb10 = load ptr, ptr %sb, align 8
  %method_call11 = call ptr @StringBuilder__build(ptr %sb10)
  %ret_p2i = ptrtoint ptr %method_call11 to i64
  ret i64 %ret_p2i
}

define i64 @index_of(i64 %0, i64 %1) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 4
  %sub = alloca i64, align 8
  store i64 %1, ptr %sub, align 4
  %s1 = load i64, ptr %s, align 4
  %int_to_slice_ptr = inttoptr i64 %s1 to ptr
  %len_f = getelementptr %__slice, ptr %int_to_slice_ptr, i32 0, i32 0
  %len = load i64, ptr %len_f, align 4
  %slen = alloca i64, align 8
  store i64 %len, ptr %slen, align 4
  %sub2 = load i64, ptr %sub, align 4
  %int_to_slice_ptr3 = inttoptr i64 %sub2 to ptr
  %len_f4 = getelementptr %__slice, ptr %int_to_slice_ptr3, i32 0, i32 0
  %len5 = load i64, ptr %len_f4, align 4
  %sublen = alloca i64, align 8
  store i64 %len5, ptr %sublen, align 4
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 4
  br label %loop_cond

loop_cond:                                        ; preds = %merge, %entry
  %i6 = load i64, ptr %i, align 4
  %slen7 = load i64, ptr %slen, align 4
  %sublen8 = load i64, ptr %sublen, align 4
  %sub9 = sub i64 %slen7, %sublen8
  %lte = icmp sle i64 %i6, %sub9
  br i1 %lte, label %loop_body, label %loop_exit

loop_body:                                        ; preds = %loop_cond
  %s10 = load i64, ptr %s, align 4
  %i11 = load i64, ptr %i, align 4
  %i12 = load i64, ptr %i, align 4
  %sublen13 = load i64, ptr %sublen, align 4
  %add = add i64 %i12, %sublen13
  %call = call i64 @substring(i64 %s10, i64 %i11, i64 %add)
  %sub14 = load i64, ptr %sub, align 4
  %eq = icmp eq i64 %call, %sub14
  br i1 %eq, label %then, label %merge

loop_exit:                                        ; preds = %loop_cond
  ret i64 -1

then:                                             ; preds = %loop_body
  %i15 = load i64, ptr %i, align 4
  ret i64 %i15

merge:                                            ; preds = %loop_body
  %i16 = load i64, ptr %i, align 4
  %add17 = add i64 %i16, 1
  store i64 %add17, ptr %i, align 4
  br label %loop_cond
}

define i64 @repeat(i64 %0, i64 %1) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 4
  %n = alloca i64, align 8
  store i64 %1, ptr %n, align 4
  %ns_call = call ptr @new()
  %sb = alloca ptr, align 8
  store ptr %ns_call, ptr %sb, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 4
  br label %loop_cond

loop_cond:                                        ; preds = %loop_body, %entry
  %i1 = load i64, ptr %i, align 4
  %n2 = load i64, ptr %n, align 4
  %lt = icmp slt i64 %i1, %n2
  br i1 %lt, label %loop_body, label %loop_exit

loop_body:                                        ; preds = %loop_cond
  %sb3 = load ptr, ptr %sb, align 8
  %s4 = load i64, ptr %s, align 4
  %method_call = call i64 @StringBuilder__append(ptr %sb3, i64 %s4)
  %i5 = load i64, ptr %i, align 4
  %add = add i64 %i5, 1
  store i64 %add, ptr %i, align 4
  br label %loop_cond

loop_exit:                                        ; preds = %loop_cond
  %sb6 = load ptr, ptr %sb, align 8
  %method_call7 = call ptr @StringBuilder__build(ptr %sb6)
  %ret_p2i = ptrtoint ptr %method_call7 to i64
  ret i64 %ret_p2i
}

define i64 @pad_left(i64 %0, i64 %1, i64 %2) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 4
  %width = alloca i64, align 8
  store i64 %1, ptr %width, align 4
  %pad_char = alloca i64, align 8
  store i64 %2, ptr %pad_char, align 4
  %width1 = load i64, ptr %width, align 4
  %s2 = load i64, ptr %s, align 4
  %int_to_slice_ptr = inttoptr i64 %s2 to ptr
  %len_f = getelementptr %__slice, ptr %int_to_slice_ptr, i32 0, i32 0
  %len = load i64, ptr %len_f, align 4
  %sub = sub i64 %width1, %len
  %diff = alloca i64, align 8
  store i64 %sub, ptr %diff, align 4
  %diff3 = load i64, ptr %diff, align 4
  %lte = icmp sle i64 %diff3, 0
  br i1 %lte, label %then, label %merge

then:                                             ; preds = %entry
  %s4 = load i64, ptr %s, align 4
  ret i64 %s4

merge:                                            ; preds = %entry
  %pad_char5 = load i64, ptr %pad_char, align 4
  %diff6 = load i64, ptr %diff, align 4
  %call = call i64 @repeat(i64 %pad_char5, i64 %diff6)
  %s7 = load i64, ptr %s, align 4
  %add = add i64 %call, %s7
  ret i64 %add
}

define i64 @pad_right(i64 %0, i64 %1, i64 %2) {
entry:
  %s = alloca i64, align 8
  store i64 %0, ptr %s, align 4
  %width = alloca i64, align 8
  store i64 %1, ptr %width, align 4
  %pad_char = alloca i64, align 8
  store i64 %2, ptr %pad_char, align 4
  %width1 = load i64, ptr %width, align 4
  %s2 = load i64, ptr %s, align 4
  %int_to_slice_ptr = inttoptr i64 %s2 to ptr
  %len_f = getelementptr %__slice, ptr %int_to_slice_ptr, i32 0, i32 0
  %len = load i64, ptr %len_f, align 4
  %sub = sub i64 %width1, %len
  %diff = alloca i64, align 8
  store i64 %sub, ptr %diff, align 4
  %diff3 = load i64, ptr %diff, align 4
  %lte = icmp sle i64 %diff3, 0
  br i1 %lte, label %then, label %merge

then:                                             ; preds = %entry
  %s4 = load i64, ptr %s, align 4
  ret i64 %s4

merge:                                            ; preds = %entry
  %s5 = load i64, ptr %s, align 4
  %pad_char6 = load i64, ptr %pad_char, align 4
  %diff7 = load i64, ptr %diff, align 4
  %call = call i64 @repeat(i64 %pad_char6, i64 %diff7)
  %add = add i64 %s5, %call
  ret i64 %add
}

define i64 @is_digit(ptr %0) {
entry:
  %c = alloca ptr, align 8
  store ptr %0, ptr %c, align 8
  %c1 = load ptr, ptr %c, align 8
  %ord_byte = load i8, ptr %c1, align 1
  %ord_val = zext i8 %ord_byte to i64
  %o = alloca i64, align 8
  store i64 %ord_val, ptr %o, align 4
  %o2 = load i64, ptr %o, align 4
  %gte = icmp sge i64 %o2, 48
  %o3 = load i64, ptr %o, align 4
  %lte = icmp sle i64 %o3, 57
  %and = and i1 %gte, %lte
  %and_ext = zext i1 %and to i64
  ret i64 %and_ext
}

define i64 @is_upper(ptr %0) {
entry:
  %c = alloca ptr, align 8
  store ptr %0, ptr %c, align 8
  %c1 = load ptr, ptr %c, align 8
  %ord_byte = load i8, ptr %c1, align 1
  %ord_val = zext i8 %ord_byte to i64
  %o = alloca i64, align 8
  store i64 %ord_val, ptr %o, align 4
  %o2 = load i64, ptr %o, align 4
  %gte = icmp sge i64 %o2, 65
  %o3 = load i64, ptr %o, align 4
  %lte = icmp sle i64 %o3, 90
  %and = and i1 %gte, %lte
  %and_ext = zext i1 %and to i64
  ret i64 %and_ext
}

define i64 @is_lower(ptr %0) {
entry:
  %c = alloca ptr, align 8
  store ptr %0, ptr %c, align 8
  %c1 = load ptr, ptr %c, align 8
  %ord_byte = load i8, ptr %c1, align 1
  %ord_val = zext i8 %ord_byte to i64
  %o = alloca i64, align 8
  store i64 %ord_val, ptr %o, align 4
  %o2 = load i64, ptr %o, align 4
  %gte = icmp sge i64 %o2, 97
  %o3 = load i64, ptr %o, align 4
  %lte = icmp sle i64 %o3, 122
  %and = and i1 %gte, %lte
  %and_ext = zext i1 %and to i64
  ret i64 %and_ext
}

define i64 @is_alpha(ptr %0) {
entry:
  %c = alloca ptr, align 8
  store ptr %0, ptr %c, align 8
  %c1 = load ptr, ptr %c, align 8
  %call = call i64 @is_upper(ptr %c1)
  %tobool = icmp ne i64 %call, 0
  %c2 = load ptr, ptr %c, align 8
  %call3 = call i64 @is_lower(ptr %c2)
  %tobool4 = icmp ne i64 %call3, 0
  %or = or i1 %tobool, %tobool4
  %or_ext = zext i1 %or to i64
  ret i64 %or_ext
}

define i64 @is_alphanumeric(ptr %0) {
entry:
  %c = alloca ptr, align 8
  store ptr %0, ptr %c, align 8
  %c1 = load ptr, ptr %c, align 8
  %call = call i64 @is_alpha(ptr %c1)
  %tobool = icmp ne i64 %call, 0
  %c2 = load ptr, ptr %c, align 8
  %call3 = call i64 @is_digit(ptr %c2)
  %tobool4 = icmp ne i64 %call3, 0
  %or = or i1 %tobool, %tobool4
  %or_ext = zext i1 %or to i64
  ret i64 %or_ext
}

define i64 @is_whitespace(ptr %0) {
entry:
  %c = alloca ptr, align 8
  store ptr %0, ptr %c, align 8
  %c1 = load ptr, ptr %c, align 8
  %ord_byte = load i8, ptr %c1, align 1
  %ord_val = zext i8 %ord_byte to i64
  %o = alloca i64, align 8
  store i64 %ord_val, ptr %o, align 4
  %o2 = load i64, ptr %o, align 4
  %eq = icmp eq i64 %o2, 32
  %o3 = load i64, ptr %o, align 4
  %eq4 = icmp eq i64 %o3, 9
  %or = or i1 %eq, %eq4
  %or_ext = zext i1 %or to i64
  %tobool = icmp ne i64 %or_ext, 0
  %o5 = load i64, ptr %o, align 4
  %eq6 = icmp eq i64 %o5, 10
  %or7 = or i1 %tobool, %eq6
  %or_ext8 = zext i1 %or7 to i64
  %tobool9 = icmp ne i64 %or_ext8, 0
  %o10 = load i64, ptr %o, align 4
  %eq11 = icmp eq i64 %o10, 13
  %or12 = or i1 %tobool9, %eq11
  %or_ext13 = zext i1 %or12 to i64
  ret i64 %or_ext13
}

define ptr @new() {
entry:
  %malloc = call ptr @malloc(i64 ptrtoint (ptr getelementptr (%StringBuilder, ptr null, i32 1) to i64))
  %parts_ptr = getelementptr %StringBuilder, ptr %malloc, i32 0, i32 0
  %data_malloc = call ptr @malloc(i64 0)
  %slice_malloc = call ptr @malloc(i64 ptrtoint (ptr getelementptr (%__slice, ptr null, i32 1) to i64))
  %len_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 0
  store i64 0, ptr %len_ptr, align 4
  %cap_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 1
  store i64 0, ptr %cap_ptr, align 4
  %data_field_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 2
  store ptr %data_malloc, ptr %data_field_ptr, align 8
  %parts_p2i = ptrtoint ptr %slice_malloc to i64
  store i64 %parts_p2i, ptr %parts_ptr, align 4
  %length_ptr = getelementptr %StringBuilder, ptr %malloc, i32 0, i32 1
  store i64 0, ptr %length_ptr, align 4
  ret ptr %malloc
}

define ptr @sb_build(i64 %0) {
entry:
  %sb = alloca i64, align 8
  store i64 %0, ptr %sb, align 4
  %result = alloca ptr, align 8
  store ptr @.str.0, ptr %result, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 4
  %sb1 = load i64, ptr %sb, align 4
  %int_to_struct_ptr = inttoptr i64 %sb1 to ptr
  %parts_ptr = getelementptr %StringBuilder, ptr %int_to_struct_ptr, i32 0, i32 0
  %parts = load i64, ptr %parts_ptr, align 4
  %parts_ptr_val = inttoptr i64 %parts to ptr
  %parts2 = alloca ptr, align 8
  store ptr %parts_ptr_val, ptr %parts2, align 8
  br label %loop_cond

loop_cond:                                        ; preds = %loop_body, %entry
  %i3 = load i64, ptr %i, align 4
  %parts4 = load ptr, ptr %parts2, align 8
  %strlen = call i64 @strlen(ptr %parts4)
  %lt = icmp slt i64 %i3, %strlen
  br i1 %lt, label %loop_body, label %loop_exit

loop_body:                                        ; preds = %loop_cond
  %result5 = load ptr, ptr %result, align 8
  %parts6 = load ptr, ptr %parts2, align 8
  %i7 = load i64, ptr %i, align 4
  %si_len = call i64 @strlen(ptr %parts6)
  %si_neg = icmp slt i64 %i7, 0
  %si_adj = add i64 %si_len, %i7
  %si_eff = select i1 %si_neg, i64 %si_adj, i64 %i7
  %si_cp = getelementptr i8, ptr %parts6, i64 %si_eff
  %si_ch = load i8, ptr %si_cp, align 1
  %si_buf = call ptr @malloc(i64 2)
  %si_p0 = getelementptr i8, ptr %si_buf, i64 0
  store i8 %si_ch, ptr %si_p0, align 1
  %si_p1 = getelementptr i8, ptr %si_buf, i64 1
  store i8 0, ptr %si_p1, align 1
  %len_l = call i64 @strlen(ptr %result5)
  %len_r = call i64 @strlen(ptr %si_buf)
  %cat_len = add i64 %len_l, %len_r
  %cat_total = add i64 %cat_len, 1
  %cat_buf = call ptr @malloc(i64 %cat_total)
  %strcpy = call ptr @strcpy(ptr %cat_buf, ptr %result5)
  %strcat = call ptr @strcat(ptr %cat_buf, ptr %si_buf)
  store ptr %cat_buf, ptr %result, align 8
  %i8 = load i64, ptr %i, align 4
  %add = add i64 %i8, 1
  store i64 %add, ptr %i, align 4
  br label %loop_cond

loop_exit:                                        ; preds = %loop_cond
  %result9 = load ptr, ptr %result, align 8
  ret ptr %result9
}

define i64 @StringBuilder__append(ptr %0, i64 %1) {
entry:
  %self = alloca ptr, align 8
  store ptr %0, ptr %self, align 8
  %s = alloca i64, align 8
  store i64 %1, ptr %s, align 4
  %self1 = load ptr, ptr %self, align 8
  %parts_ptr = getelementptr %StringBuilder, ptr %self1, i32 0, i32 0
  %parts = load i64, ptr %parts_ptr, align 4
  %parts_ptr_val = inttoptr i64 %parts to ptr
  %s2 = load i64, ptr %s, align 4
  %len_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  %len = load i64, ptr %len_f, align 4
  %cap_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 1
  %cap = load i64, ptr %cap_f, align 4
  %need_grow = icmp sge i64 %len, %cap
  br i1 %need_grow, label %push_grow, label %push_store

push_grow:                                        ; preds = %entry
  %cap_doubled = mul i64 %cap, 2
  %is_zero = icmp eq i64 %cap_doubled, 0
  %new_cap = select i1 %is_zero, i64 1, i64 %cap_doubled
  %new_size = mul i64 %new_cap, 8
  %data_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  %data = load ptr, ptr %data_f, align 8
  %realloc = call ptr @realloc(ptr %data, i64 %new_size)
  %data_f3 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  store ptr %realloc, ptr %data_f3, align 8
  %cap_f4 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 1
  store i64 %new_cap, ptr %cap_f4, align 4
  br label %push_store

push_store:                                       ; preds = %push_grow, %entry
  %data_f5 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  %data6 = load ptr, ptr %data_f5, align 8
  %len_f7 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  %len8 = load i64, ptr %len_f7, align 4
  %push_slot = getelementptr i64, ptr %data6, i64 %len8
  store i64 %s2, ptr %push_slot, align 4
  %new_len = add i64 %len8, 1
  %len_f9 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  store i64 %new_len, ptr %len_f9, align 4
  %da_obj = load ptr, ptr %self, align 8
  %self10 = load ptr, ptr %self, align 8
  %length_ptr = getelementptr %StringBuilder, ptr %self10, i32 0, i32 1
  %length = load i64, ptr %length_ptr, align 4
  %s11 = load i64, ptr %s, align 4
  %int_to_slice_ptr = inttoptr i64 %s11 to ptr
  %len_f12 = getelementptr %__slice, ptr %int_to_slice_ptr, i32 0, i32 0
  %len13 = load i64, ptr %len_f12, align 4
  %add = add i64 %length, %len13
  %length_fptr = getelementptr %StringBuilder, ptr %da_obj, i32 0, i32 1
  store i64 %add, ptr %length_fptr, align 4
  ret i64 0
}

define i64 @StringBuilder__append_int(ptr %0, i64 %1) {
entry:
  %self = alloca ptr, align 8
  store ptr %0, ptr %self, align 8
  %n = alloca i64, align 8
  store i64 %1, ptr %n, align 4
  %n1 = load i64, ptr %n, align 4
  %tostr_buf = call ptr @malloc(i64 32)
  %sprintf_ret = call i32 (ptr, ptr, ...) @sprintf(ptr %tostr_buf, ptr @fmt_int_bare, i64 %n1)
  %s = alloca ptr, align 8
  store ptr %tostr_buf, ptr %s, align 8
  %self2 = load ptr, ptr %self, align 8
  %parts_ptr = getelementptr %StringBuilder, ptr %self2, i32 0, i32 0
  %parts = load i64, ptr %parts_ptr, align 4
  %parts_ptr_val = inttoptr i64 %parts to ptr
  %s3 = load ptr, ptr %s, align 8
  %push_p2i = ptrtoint ptr %s3 to i64
  %len_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  %len = load i64, ptr %len_f, align 4
  %cap_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 1
  %cap = load i64, ptr %cap_f, align 4
  %need_grow = icmp sge i64 %len, %cap
  br i1 %need_grow, label %push_grow, label %push_store

push_grow:                                        ; preds = %entry
  %cap_doubled = mul i64 %cap, 2
  %is_zero = icmp eq i64 %cap_doubled, 0
  %new_cap = select i1 %is_zero, i64 1, i64 %cap_doubled
  %new_size = mul i64 %new_cap, 8
  %data_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  %data = load ptr, ptr %data_f, align 8
  %realloc = call ptr @realloc(ptr %data, i64 %new_size)
  %data_f4 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  store ptr %realloc, ptr %data_f4, align 8
  %cap_f5 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 1
  store i64 %new_cap, ptr %cap_f5, align 4
  br label %push_store

push_store:                                       ; preds = %push_grow, %entry
  %data_f6 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  %data7 = load ptr, ptr %data_f6, align 8
  %len_f8 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  %len9 = load i64, ptr %len_f8, align 4
  %push_slot = getelementptr i64, ptr %data7, i64 %len9
  store i64 %push_p2i, ptr %push_slot, align 4
  %new_len = add i64 %len9, 1
  %len_f10 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  store i64 %new_len, ptr %len_f10, align 4
  %da_obj = load ptr, ptr %self, align 8
  %self11 = load ptr, ptr %self, align 8
  %length_ptr = getelementptr %StringBuilder, ptr %self11, i32 0, i32 1
  %length = load i64, ptr %length_ptr, align 4
  %s12 = load ptr, ptr %s, align 8
  %strlen = call i64 @strlen(ptr %s12)
  %add = add i64 %length, %strlen
  %length_fptr = getelementptr %StringBuilder, ptr %da_obj, i32 0, i32 1
  store i64 %add, ptr %length_fptr, align 4
  ret i64 0
}

define i64 @StringBuilder__append_line(ptr %0, i64 %1) {
entry:
  %self = alloca ptr, align 8
  store ptr %0, ptr %self, align 8
  %s = alloca i64, align 8
  store i64 %1, ptr %s, align 4
  %self1 = load ptr, ptr %self, align 8
  %parts_ptr = getelementptr %StringBuilder, ptr %self1, i32 0, i32 0
  %parts = load i64, ptr %parts_ptr, align 4
  %parts_ptr_val = inttoptr i64 %parts to ptr
  %s2 = load i64, ptr %s, align 4
  %len_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  %len = load i64, ptr %len_f, align 4
  %cap_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 1
  %cap = load i64, ptr %cap_f, align 4
  %need_grow = icmp sge i64 %len, %cap
  br i1 %need_grow, label %push_grow, label %push_store

push_grow:                                        ; preds = %entry
  %cap_doubled = mul i64 %cap, 2
  %is_zero = icmp eq i64 %cap_doubled, 0
  %new_cap = select i1 %is_zero, i64 1, i64 %cap_doubled
  %new_size = mul i64 %new_cap, 8
  %data_f = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  %data = load ptr, ptr %data_f, align 8
  %realloc = call ptr @realloc(ptr %data, i64 %new_size)
  %data_f3 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  store ptr %realloc, ptr %data_f3, align 8
  %cap_f4 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 1
  store i64 %new_cap, ptr %cap_f4, align 4
  br label %push_store

push_store:                                       ; preds = %push_grow, %entry
  %data_f5 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 2
  %data6 = load ptr, ptr %data_f5, align 8
  %len_f7 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  %len8 = load i64, ptr %len_f7, align 4
  %push_slot = getelementptr i64, ptr %data6, i64 %len8
  store i64 %s2, ptr %push_slot, align 4
  %new_len = add i64 %len8, 1
  %len_f9 = getelementptr %__slice, ptr %parts_ptr_val, i32 0, i32 0
  store i64 %new_len, ptr %len_f9, align 4
  %self10 = load ptr, ptr %self, align 8
  %parts_ptr11 = getelementptr %StringBuilder, ptr %self10, i32 0, i32 0
  %parts12 = load i64, ptr %parts_ptr11, align 4
  %parts_ptr_val13 = inttoptr i64 %parts12 to ptr
  %len_f14 = getelementptr %__slice, ptr %parts_ptr_val13, i32 0, i32 0
  %len15 = load i64, ptr %len_f14, align 4
  %cap_f16 = getelementptr %__slice, ptr %parts_ptr_val13, i32 0, i32 1
  %cap17 = load i64, ptr %cap_f16, align 4
  %need_grow20 = icmp sge i64 %len15, %cap17
  br i1 %need_grow20, label %push_grow18, label %push_store19

push_grow18:                                      ; preds = %push_store
  %cap_doubled21 = mul i64 %cap17, 2
  %is_zero22 = icmp eq i64 %cap_doubled21, 0
  %new_cap23 = select i1 %is_zero22, i64 1, i64 %cap_doubled21
  %new_size24 = mul i64 %new_cap23, 8
  %data_f25 = getelementptr %__slice, ptr %parts_ptr_val13, i32 0, i32 2
  %data26 = load ptr, ptr %data_f25, align 8
  %realloc27 = call ptr @realloc(ptr %data26, i64 %new_size24)
  %data_f28 = getelementptr %__slice, ptr %parts_ptr_val13, i32 0, i32 2
  store ptr %realloc27, ptr %data_f28, align 8
  %cap_f29 = getelementptr %__slice, ptr %parts_ptr_val13, i32 0, i32 1
  store i64 %new_cap23, ptr %cap_f29, align 4
  br label %push_store19

push_store19:                                     ; preds = %push_grow18, %push_store
  %data_f30 = getelementptr %__slice, ptr %parts_ptr_val13, i32 0, i32 2
  %data31 = load ptr, ptr %data_f30, align 8
  %len_f32 = getelementptr %__slice, ptr %parts_ptr_val13, i32 0, i32 0
  %len33 = load i64, ptr %len_f32, align 4
  %push_slot34 = getelementptr i64, ptr %data31, i64 %len33
  store i64 ptrtoint (ptr @.str.1 to i64), ptr %push_slot34, align 4
  %new_len35 = add i64 %len33, 1
  %len_f36 = getelementptr %__slice, ptr %parts_ptr_val13, i32 0, i32 0
  store i64 %new_len35, ptr %len_f36, align 4
  %da_obj = load ptr, ptr %self, align 8
  %self37 = load ptr, ptr %self, align 8
  %length_ptr = getelementptr %StringBuilder, ptr %self37, i32 0, i32 1
  %length = load i64, ptr %length_ptr, align 4
  %s38 = load i64, ptr %s, align 4
  %int_to_slice_ptr = inttoptr i64 %s38 to ptr
  %len_f39 = getelementptr %__slice, ptr %int_to_slice_ptr, i32 0, i32 0
  %len40 = load i64, ptr %len_f39, align 4
  %add = add i64 %length, %len40
  %add41 = add i64 %add, 1
  %length_fptr = getelementptr %StringBuilder, ptr %da_obj, i32 0, i32 1
  store i64 %add41, ptr %length_fptr, align 4
  ret i64 0
}

define ptr @StringBuilder__build(ptr %0) {
entry:
  %self = alloca ptr, align 8
  store ptr %0, ptr %self, align 8
  %self1 = load ptr, ptr %self, align 8
  %arg_p2i = ptrtoint ptr %self1 to i64
  %call = call ptr @sb_build(i64 %arg_p2i)
  ret ptr %call
}

define i64 @StringBuilder__len(ptr %0) {
entry:
  %self = alloca ptr, align 8
  store ptr %0, ptr %self, align 8
  %self1 = load ptr, ptr %self, align 8
  %length_ptr = getelementptr %StringBuilder, ptr %self1, i32 0, i32 1
  %length = load i64, ptr %length_ptr, align 4
  ret i64 %length
}

define i64 @StringBuilder__clear(ptr %0) {
entry:
  %self = alloca ptr, align 8
  store ptr %0, ptr %self, align 8
  %da_obj = load ptr, ptr %self, align 8
  %data_malloc = call ptr @malloc(i64 0)
  %slice_malloc = call ptr @malloc(i64 ptrtoint (ptr getelementptr (%__slice, ptr null, i32 1) to i64))
  %len_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 0
  store i64 0, ptr %len_ptr, align 4
  %cap_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 1
  store i64 0, ptr %cap_ptr, align 4
  %data_field_ptr = getelementptr %__slice, ptr %slice_malloc, i32 0, i32 2
  store ptr %data_malloc, ptr %data_field_ptr, align 8
  %da_p2i = ptrtoint ptr %slice_malloc to i64
  %parts_fptr = getelementptr %StringBuilder, ptr %da_obj, i32 0, i32 0
  store i64 %da_p2i, ptr %parts_fptr, align 4
  %da_obj1 = load ptr, ptr %self, align 8
  %length_fptr = getelementptr %StringBuilder, ptr %da_obj1, i32 0, i32 1
  store i64 0, ptr %length_fptr, align 4
  ret i64 0
}

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
  %elem_raw = load i64, ptr %elem_ptr, align 4
  store i64 %elem_raw, ptr %x, align 4
  %total3 = load i64, ptr %total, align 4
  %x4 = load i64, ptr %x, align 4
  %add = add i64 %total3, %x4
  store i64 %add, ptr %total, align 4
  %i5 = load i64, ptr %__i, align 4
  %i_next = add i64 %i5, 1
  store i64 %i_next, ptr %__i, align 4
  br label %foreach_cond

foreach_exit:                                     ; preds = %foreach_cond
  %total6 = load i64, ptr %total, align 4
  ret i64 %total6
}

define private ptr @__cronyx_trim(ptr %0) {
entry:
  %slen = call i64 @strlen(ptr %0)
  %start = alloca i64, align 8
  store i64 0, ptr %start, align 4
  br label %fwd

fwd:                                              ; preds = %fwd_inc, %entry
  %fwd_i = load i64, ptr %start, align 4
  %fwd_cmp = icmp slt i64 %fwd_i, %slen
  br i1 %fwd_cmp, label %fwd_chk, label %rev_ini

fwd_chk:                                          ; preds = %fwd
  %fwd_ptr = getelementptr i8, ptr %0, i64 %fwd_i
  %fwd_c = load i8, ptr %fwd_ptr, align 1
  %sp = icmp eq i8 %fwd_c, 32
  %tab = icmp eq i8 %fwd_c, 9
  %cr = icmp eq i8 %fwd_c, 13
  %nl = icmp eq i8 %fwd_c, 10
  %ws1 = or i1 %sp, %tab
  %ws2 = or i1 %ws1, %cr
  %ws3 = or i1 %ws2, %nl
  br i1 %ws3, label %fwd_inc, label %rev_ini

fwd_inc:                                          ; preds = %fwd_chk
  %fwd_next = add i64 %fwd_i, 1
  store i64 %fwd_next, ptr %start, align 4
  br label %fwd

rev_ini:                                          ; preds = %fwd_chk, %fwd
  %start_val = load i64, ptr %start, align 4
  %end_slot = alloca i64, align 8
  %last = sub i64 %slen, 1
  store i64 %last, ptr %end_slot, align 4
  br label %rev

rev:                                              ; preds = %rev_dec, %rev_ini
  %rev_e = load i64, ptr %end_slot, align 4
  %rev_cmp = icmp sge i64 %rev_e, %start_val
  br i1 %rev_cmp, label %rev_chk, label %empty

rev_chk:                                          ; preds = %rev
  %rev_ptr = getelementptr i8, ptr %0, i64 %rev_e
  %rev_c = load i8, ptr %rev_ptr, align 1
  %rsp = icmp eq i8 %rev_c, 32
  %rtab = icmp eq i8 %rev_c, 9
  %rcr = icmp eq i8 %rev_c, 13
  %rnl = icmp eq i8 %rev_c, 10
  %rws1 = or i1 %rsp, %rtab
  %rws2 = or i1 %rws1, %rcr
  %rws3 = or i1 %rws2, %rnl
  br i1 %rws3, label %rev_dec, label %alloc

rev_dec:                                          ; preds = %rev_chk
  %rev_dec1 = sub i64 %rev_e, 1
  store i64 %rev_dec1, ptr %end_slot, align 4
  br label %rev

alloc:                                            ; preds = %rev_chk
  %s_val = load i64, ptr %start, align 4
  %e_val = load i64, ptr %end_slot, align 4
  %new_len0 = sub i64 %e_val, %s_val
  %new_len1 = add i64 %new_len0, 1
  %buf_sz = add i64 %new_len1, 1
  %buf = call ptr @malloc(i64 %buf_sz)
  %src = getelementptr i8, ptr %0, i64 %s_val
  %mc = call ptr @memcpy(ptr %buf, ptr %src, i64 %new_len1)
  %null_pos = getelementptr i8, ptr %buf, i64 %new_len1
  store i8 0, ptr %null_pos, align 1
  ret ptr %buf

empty:                                            ; preds = %rev
  %ebuf = call ptr @malloc(i64 1)
  %enull = getelementptr i8, ptr %ebuf, i64 0
  store i8 0, ptr %enull, align 1
  ret ptr %ebuf
}

define private ptr @__cronyx_chars(ptr %0) {
entry:
  %n = call i64 @strlen(ptr %0)
  %data_sz = mul i64 %n, 8
  %data_buf = call ptr @malloc(i64 %data_sz)
  %slice_ptr = call ptr @malloc(i64 24)
  %lp = getelementptr %__slice, ptr %slice_ptr, i32 0, i32 0
  store i64 %n, ptr %lp, align 4
  %cp = getelementptr %__slice, ptr %slice_ptr, i32 0, i32 1
  store i64 %n, ptr %cp, align 4
  %dp = getelementptr %__slice, ptr %slice_ptr, i32 0, i32 2
  store ptr %data_buf, ptr %dp, align 8
  %i = alloca i64, align 8
  store i64 0, ptr %i, align 4
  br label %loop

loop:                                             ; preds = %body, %entry
  %ci = load i64, ptr %i, align 4
  %cond = icmp slt i64 %ci, %n
  br i1 %cond, label %body, label %exit

body:                                             ; preds = %loop
  %cp_i = getelementptr i8, ptr %0, i64 %ci
  %ch = load i8, ptr %cp_i, align 1
  %ch_buf = call ptr @malloc(i64 2)
  %p0 = getelementptr i8, ptr %ch_buf, i64 0
  store i8 %ch, ptr %p0, align 1
  %p1 = getelementptr i8, ptr %ch_buf, i64 1
  store i8 0, ptr %p1, align 1
  %elem_ptr = getelementptr ptr, ptr %data_buf, i64 %ci
  store ptr %ch_buf, ptr %elem_ptr, align 8
  %ci_next = add i64 %ci, 1
  store i64 %ci_next, ptr %i, align 4
  br label %loop

exit:                                             ; preds = %loop
  ret ptr %slice_ptr
}

define private ptr @__cronyx_split(ptr %0, ptr %1) {
entry:
  %dlen = call i64 @strlen(ptr %1)
  %cnt1 = alloca i64, align 8
  store i64 0, ptr %cnt1, align 4
  %pos = alloca ptr, align 8
  store ptr %0, ptr %pos, align 8
  br label %cnt

cnt:                                              ; preds = %cnt_b, %entry
  %cur = load ptr, ptr %pos, align 8
  %found = call ptr @strstr(ptr %cur, ptr %1)
  %fi = ptrtoint ptr %found to i64
  %nn = icmp ne i64 %fi, 0
  br i1 %nn, label %cnt_b, label %alloc

cnt_b:                                            ; preds = %cnt
  %oc = load i64, ptr %cnt1, align 4
  %nc = add i64 %oc, 1
  store i64 %nc, ptr %cnt1, align 4
  %next_pos = getelementptr i8, ptr %found, i64 %dlen
  store ptr %next_pos, ptr %pos, align 8
  br label %cnt

alloc:                                            ; preds = %cnt
  %cnt2 = load i64, ptr %cnt1, align 4
  %n_parts = add i64 %cnt2, 1
  %dsz = mul i64 %n_parts, 8
  %dbuf = call ptr @malloc(i64 %dsz)
  %sptr = call ptr @malloc(i64 24)
  %slp = getelementptr %__slice, ptr %sptr, i32 0, i32 0
  store i64 %n_parts, ptr %slp, align 4
  %scp = getelementptr %__slice, ptr %sptr, i32 0, i32 1
  store i64 %n_parts, ptr %scp, align 4
  %sdp = getelementptr %__slice, ptr %sptr, i32 0, i32 2
  store ptr %dbuf, ptr %sdp, align 8
  %idx = alloca i64, align 8
  store i64 0, ptr %idx, align 4
  store ptr %0, ptr %pos, align 8
  br label %fill

fill:                                             ; preds = %fill_b, %alloc
  %fp = load ptr, ptr %pos, align 8
  %fnxt = call ptr @strstr(ptr %fp, ptr %1)
  %fi2 = ptrtoint ptr %fnxt to i64
  %fnn = icmp ne i64 %fi2, 0
  br i1 %fnn, label %fill_b, label %last

fill_b:                                           ; preds = %fill
  %fpi = ptrtoint ptr %fp to i64
  %fni = ptrtoint ptr %fnxt to i64
  %slen = sub i64 %fni, %fpi
  %ssz = add i64 %slen, 1
  %sbuf = call ptr @malloc(i64 %ssz)
  %mcp = call ptr @memcpy(ptr %sbuf, ptr %fp, i64 %slen)
  %np = getelementptr i8, ptr %sbuf, i64 %slen
  store i8 0, ptr %np, align 1
  %fi3 = load i64, ptr %idx, align 4
  %ep = getelementptr ptr, ptr %dbuf, i64 %fi3
  store ptr %sbuf, ptr %ep, align 8
  %fin = add i64 %fi3, 1
  store i64 %fin, ptr %idx, align 4
  %nxtp = getelementptr i8, ptr %fnxt, i64 %dlen
  store ptr %nxtp, ptr %pos, align 8
  br label %fill

fill_e:                                           ; No predecessors!
  br label %done

last:                                             ; preds = %fill
  %lp2 = load ptr, ptr %pos, align 8
  %rem = call i64 @strlen(ptr %lp2)
  %remsz = add i64 %rem, 1
  %rbuf = call ptr @malloc(i64 %remsz)
  %rmcp = call ptr @memcpy(ptr %rbuf, ptr %lp2, i64 %rem)
  %rnull = getelementptr i8, ptr %rbuf, i64 %rem
  store i8 0, ptr %rnull, align 1
  %ri = load i64, ptr %idx, align 4
  %rep = getelementptr ptr, ptr %dbuf, i64 %ri
  store ptr %rbuf, ptr %rep, align 8
  br label %done

done:                                             ; preds = %last, %fill_e
  ret ptr %sptr
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
