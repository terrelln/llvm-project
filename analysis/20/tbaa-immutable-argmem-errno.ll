; Reproducer for the TypeBasedAA immutable-call path dropping explicit
; errnomem effects from a call.
;
; Correct behavior: the second load must remain, because the call may write
; errno independently of its immutable argument-memory read.
;
; Current buggy behavior:
;   build/bin/opt -S -aa-pipeline=basic-aa,tbaa \
;     -passes='early-cse<memssa>,instcombine,simplifycfg' %s
; folds the function to `call @read_const_float_and_set_errno(...); ret i32 0`.
;
; BasicAA alone keeps the loads:
;   build/bin/opt -S -aa-pipeline=basic-aa \
;     -passes='early-cse<memssa>,instcombine,simplifycfg' %s

target triple = "x86_64-unknown-linux-gnu"

; The call reads through %f using an immutable float TBAA tag. Independently, it
; may write errno.
declare void @read_const_float_and_set_errno(ptr) memory(argmem: read, errnomem: write)

define i32 @tbaa_immutable_call_hides_errno(ptr %errno_ptr, ptr %f) {
entry:
  %before = load i32, ptr %errno_ptr, align 4, !tbaa !3
  call void @read_const_float_and_set_errno(ptr %f), !tbaa !5
  %after = load i32, ptr %errno_ptr, align 4, !tbaa !3
  %diff = sub i32 %after, %before
  ret i32 %diff
}

!0 = !{!"Simple C/C++ TBAA"}
!1 = !{!"omnipotent char", !0}
!2 = !{!"int", !1}
!5 = !{!"const float", !1, i64 1}
!3 = !{!2, !2, i64 0}
