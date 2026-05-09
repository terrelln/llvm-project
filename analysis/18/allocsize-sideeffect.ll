; Reproducer candidate for BasicAA's malloc/calloc-like ModRef shortcut.

@G = global i32 0, align 4

declare noalias ptr @custom_alloc_and_clobber(i64) allocsize(0)

define i32 @allocsize_can_clobber_global() {
entry:
  store i32 1, ptr @G, align 4
  %p = call ptr @custom_alloc_and_clobber(i64 4)
  %v = load i32, ptr @G, align 4
  ret i32 %v
}
