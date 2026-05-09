; Reproducer for ObjCARCAA dropping operand-bundle effects.
;
; RUN: opt -passes=verify -disable-output %s
; RUN: opt -aa-pipeline=basic-aa,objc-arc-aa -passes=aa-eval \
; RUN:   -print-all-alias-modref-info -disable-output %s 2>&1 | \
; RUN:   FileCheck %s --check-prefix=AA
; RUN: opt -S -aa-pipeline=basic-aa \
; RUN:   -passes='early-cse<memssa>,instcombine,simplifycfg' %s | \
; RUN:   FileCheck %s --check-prefix=BASIC
; RUN: opt -S -aa-pipeline=basic-aa,objc-arc-aa \
; RUN:   -passes='early-cse<memssa>,instcombine,simplifycfg' %s | \
; RUN:   FileCheck %s --check-prefix=BUG

target triple = "x86_64-apple-macosx14.0.0"

declare ptr @llvm.objc.retain(ptr)

define i32 @objc_arc_bundle_clobber(ptr %p, ptr %obj) {
; AA: NoModRef:{{.*}}Ptr: i32* %p{{.*}}call ptr @llvm.objc.retain
;
; BASIC-LABEL: define i32 @objc_arc_bundle_clobber(
; BASIC:         call ptr @llvm.objc.retain
; BASIC-NEXT:    %after = load i32, ptr %p
; BASIC-NEXT:    ret i32 %after
;
; BUG-LABEL: define i32 @objc_arc_bundle_clobber(
; BUG:         call ptr @llvm.objc.retain
; BUG-NEXT:    ret i32 1
entry:
  store i32 1, ptr %p, align 4
  %r = call ptr @llvm.objc.retain(ptr %obj) [ "unknown"(ptr %p) ]
  %after = load i32, ptr %p, align 4
  ret i32 %after
}
