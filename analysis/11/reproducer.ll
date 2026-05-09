; GlobalsAA operand-bundle memory-effects reproducer.
;
; This CHECK documents the current buggy behavior: `opt` incorrectly folds
; @globalsaa_operand_bundle_bug to return 0.
;
; RUN: opt -S -aa-pipeline=basic-aa,globals-aa \
; RUN:   -passes='require<globals-aa>,early-cse<memssa>' < %s | FileCheck %s

define internal void @leaf() memory(none) nounwind willreturn {
entry:
  ret void
}

define internal void @wrapper_with_unknown_bundle(ptr %p) nounwind willreturn {
entry:
  ; The unknown operand bundle gives this call unknown heap read/write effects
  ; unless a callsite memory attribute overrides them.
  call void @leaf() [ "unknown"(ptr %p) ]
  ret void
}

define i32 @globalsaa_operand_bundle_bug(ptr %p) {
; CHECK-LABEL: define i32 @globalsaa_operand_bundle_bug(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[BEFORE:%.*]] = load i32, ptr [[P:%.*]], align 4
; CHECK-NEXT:    call void @wrapper_with_unknown_bundle(ptr [[P]])
; CHECK-NEXT:    ret i32 0
entry:
  %before = load i32, ptr %p, align 4
  call void @wrapper_with_unknown_bundle(ptr %p)
  %after = load i32, ptr %p, align 4
  %diff = sub i32 %after, %before
  ret i32 %diff
}
