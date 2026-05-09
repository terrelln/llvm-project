; Reproducer for TypeBasedAA dropping explicit errnomem effects from a call
; when call-level TBAA is disjoint from the queried location's TBAA.
;
; Correct behavior: the second load must remain, because @touch_float may write
; errno and %errno_ptr may be the address of errno.
;
; Current buggy behavior:
;   build/bin/opt -S -aa-pipeline=basic-aa,tbaa \
;     -passes='early-cse<memssa>,instcombine,simplifycfg' %s
; folds the function to `call @touch_float(...); ret i32 0`.
;
; BasicAA alone keeps the loads:
;   build/bin/opt -S -aa-pipeline=basic-aa \
;     -passes='early-cse<memssa>,instcombine,simplifycfg' %s

target triple = "x86_64-unknown-linux-gnu"

; The ordinary pointer access of @touch_float is through %f and has float TBAA.
; Independently, the call may write errno.
declare void @touch_float(ptr) memory(argmem: read, errnomem: write)

define i32 @tbaa_call_metadata_hides_errno(ptr %errno_ptr, ptr %f) {
entry:
  %before = load i32, ptr %errno_ptr, align 4, !tbaa !3
  call void @touch_float(ptr %f), !tbaa !4
  %after = load i32, ptr %errno_ptr, align 4, !tbaa !3
  %diff = sub i32 %after, %before
  ret i32 %diff
}

!0 = !{!"Simple C/C++ TBAA"}
!1 = !{!"omnipotent char", !0}
!2 = !{!"int", !1}
!5 = !{!"float", !1}
!3 = !{!2, !2, i64 0}
!4 = !{!5, !5, i64 0}
