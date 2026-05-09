; Reproducer under investigation for masked scatter/gather vector-pointer
; ModRef handling.

declare void @llvm.masked.scatter.v2i32.v2p0(<2 x i32>, <2 x ptr>, i32, <2 x i1>)
declare <2 x i32> @llvm.masked.gather.v2i32.v2p0(<2 x ptr>, i32, <2 x i1>, <2 x i32>)

define i32 @masked_scatter_clobbers_alloca() {
entry:
  %a = alloca i32, align 4
  store i32 1, ptr %a, align 4
  %ptrs0 = insertelement <2 x ptr> poison, ptr %a, i32 0
  %ptrs = insertelement <2 x ptr> %ptrs0, ptr %a, i32 1
  call void @llvm.masked.scatter.v2i32.v2p0(
      <2 x i32> <i32 2, i32 3>,
      <2 x ptr> %ptrs,
      i32 4,
      <2 x i1> <i1 true, i1 false>)
  %after = load i32, ptr %a, align 4
  ret i32 %after
}

define i32 @masked_gather_reads_alloca() {
entry:
  %a = alloca i32, align 4
  store i32 7, ptr %a, align 4
  %ptrs0 = insertelement <2 x ptr> poison, ptr %a, i32 0
  %ptrs = insertelement <2 x ptr> %ptrs0, ptr %a, i32 1
  %v = call <2 x i32> @llvm.masked.gather.v2i32.v2p0(
      <2 x ptr> %ptrs,
      i32 4,
      <2 x i1> <i1 true, i1 false>,
      <2 x i32> poison)
  %lane0 = extractelement <2 x i32> %v, i32 0
  ret i32 %lane0
}
