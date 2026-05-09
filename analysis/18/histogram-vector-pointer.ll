; RUN: opt -aa-pipeline=basic-aa -passes=aa-eval -print-all-alias-modref-info -disable-output %s 2>&1 | FileCheck %s --check-prefix=BUG-AA
; RUN: opt -passes=gvn -S %s | FileCheck %s --check-prefix=BUG-GVN
; RUN: opt -passes='scalarize-masked-mem-intrin,instcombine,simplifycfg' -S %s | FileCheck %s --check-prefix=SCALARIZED

; The active histogram lane increments the i32 stored at %p. The final load
; must therefore observe a value written by the intrinsic, not the preceding
; store of 10.
;
; BUG-AA: Function: histogram_add_clobbers_scalar: 1 pointers, 1 call sites
; BUG-AA: NoModRef: Ptr: i32* %p
;
; BUG-GVN-LABEL: define i32 @histogram_add_clobbers_scalar(
; BUG-GVN: call void @llvm.experimental.vector.histogram.add.v2p0.i32
; BUG-GVN-NEXT: ret i32 10
;
; SCALARIZED-LABEL: define i32 @histogram_add_clobbers_scalar(
; SCALARIZED: store i32 11, ptr %p
; SCALARIZED-NEXT: ret i32 11
define i32 @histogram_add_clobbers_scalar(ptr %p) {
entry:
  store i32 10, ptr %p, align 4
  %ptrs.0 = insertelement <2 x ptr> poison, ptr %p, i32 0
  %ptrs.1 = insertelement <2 x ptr> %ptrs.0, ptr %p, i32 1
  call void @llvm.experimental.vector.histogram.add.v2p0.i32(
      <2 x ptr> %ptrs.1, i32 1, <2 x i1> <i1 true, i1 false>)
  %after = load i32, ptr %p, align 4
  ret i32 %after
}

declare void @llvm.experimental.vector.histogram.add.v2p0.i32(<2 x ptr>, i32, <2 x i1>)
