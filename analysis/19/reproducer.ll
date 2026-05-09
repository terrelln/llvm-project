; RUN: opt -passes='globals-aa,gvn' -S < %s | FileCheck %s
;
; Bug: GlobalsModRef doesn't account for errnomem write effects from external
; calls. When a function calls an external function with `errnomem: write`
; (like fmodf) and doesn't callback into the module (nosync nocallback),
; GlobalsModRef keeps tracking per-global info but doesn't add a Mod for
; the errno global. Its getModRefInfoForGlobal returns only Ref (from
; MayReadAnyGlobal), missing the Mod from the errnomem effect.
;
; This causes the AA chain to intersect BasicAA's ModRef with GlobalsModRef's
; Ref, yielding just Ref. GVN then forwards a stale store value past the
; errno-writing call.

@my_errno = internal global i32 0

; fmodf writes errno (errnomem: write), doesn't callback (nosync nocallback)
declare float @fmodf(float, float) nosync nocallback memory(errnomem: write)

define internal void @wrapper(ptr %out, float %x, float %y) {
  %r = call float @fmodf(float %x, float %y)
  store float %r, ptr %out
  ret void
}

define i32 @test(float %x, float %y) {
  store i32 0, ptr @my_errno
  %buf = alloca float
  call void @wrapper(ptr %buf, float %x, float %y)
  ; The load should NOT be forwarded from the store of 0, because
  ; @wrapper -> @fmodf writes errno (my_errno).
  ; CHECK: %e = load i32, ptr @my_errno
  %e = load i32, ptr @my_errno
  ret i32 %e
}
