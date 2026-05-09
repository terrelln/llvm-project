; Test: Can ScopedNoAliasAA incorrectly return NoModRef for
; getModRefInfo(CallBase, MemoryLocation) when the call has !noalias
; metadata and the location has a matching !alias.scope?
;
; If a call has memory(errnomem: write) and the location's alias.scope
; is covered by the call's !noalias, ScopedNoAliasAA returns NoModRef.
; Then the errno write effect is masked out. If the location actually
; IS errno, this is wrong.
;
; RUN: opt -aa-pipeline=basic-aa,scoped-noalias-aa \
; RUN:   -passes='early-cse<memssa>' -S < %s | FileCheck %s

target triple = "x86_64-unknown-linux-gnu"

; @set_errno only writes errno memory.
declare void @set_errno() memory(errnomem: write)

; CHECK-LABEL: define i32 @scoped_noalias_errno
define i32 @scoped_noalias_errno(ptr %errno_ptr) {
; The two loads should NOT be CSE'd because @set_errno may write to
; the memory at %errno_ptr (if it is errno).
;
; CHECK:       %v1 = load i32, ptr %errno_ptr
; CHECK-NEXT:  call void @set_errno()
; CHECK-NEXT:  %v2 = load i32, ptr %errno_ptr
; CHECK-NEXT:  %diff = sub i32 %v2, %v1
; CHECK-NEXT:  ret i32 %diff
  %v1 = load i32, ptr %errno_ptr, align 4, !alias.scope !2
  call void @set_errno(), !noalias !2
  %v2 = load i32, ptr %errno_ptr, align 4, !alias.scope !2
  %diff = sub i32 %v2, %v1
  ret i32 %diff
}

!0 = !{!"domain"}
!1 = !{!1, !0, !"scope_errno"}
!2 = !{!1}
