; RUN: opt -aa-pipeline=basic-aa -passes='print<memoryssa>' -disable-output < %s 2>&1 | FileCheck %s --check-prefix=BASIC
; RUN: opt -aa-pipeline=basic-aa,tbaa -passes='print<memoryssa>' -disable-output < %s 2>&1 | FileCheck %s --check-prefix=TBAA
; RUN: opt -aa-pipeline=basic-aa,tbaa -passes='early-cse<memssa>,instcombine,simplifycfg' -S < %s | FileCheck %s --check-prefix=OPT

declare void @leaf() memory(none)

define i32 @tbaa_operand_bundle_clobber(ptr %p) {
; BASIC-LABEL: MemorySSA for function: tbaa_operand_bundle_clobber
; BASIC:      ; 1 = MemoryDef(liveOnEntry)
; BASIC-NEXT:   store i32 1, ptr %p, align 4, !tbaa
; BASIC-NEXT: ; 2 = MemoryDef(1)
; BASIC-NEXT:   call void @leaf() [ "unknown"(ptr %p) ], !tbaa
; BASIC-NEXT: ; MemoryUse(2)
; BASIC-NEXT:   %after = load i32, ptr %p, align 4, !tbaa
;
; TBAA-LABEL: MemorySSA for function: tbaa_operand_bundle_clobber
; TBAA:      ; 1 = MemoryDef(liveOnEntry)
; TBAA-NEXT:   store i32 1, ptr %p, align 4, !tbaa
; TBAA-NEXT: ; 2 = MemoryDef(1)
; TBAA-NEXT:   call void @leaf() [ "unknown"(ptr %p) ], !tbaa
; TBAA-NEXT: ; MemoryUse(1)
; TBAA-NEXT:   %after = load i32, ptr %p, align 4, !tbaa
;
; OPT-LABEL: define i32 @tbaa_operand_bundle_clobber(
; OPT:         store i32 1, ptr %p, align 4, !tbaa
; OPT-NEXT:    call void @leaf() [ "unknown"(ptr %p) ], !tbaa
; OPT-NEXT:    ret i32 1
entry:
  store i32 1, ptr %p, align 4, !tbaa !1
  call void @leaf() [ "unknown"(ptr %p) ], !tbaa !2
  %after = load i32, ptr %p, align 4, !tbaa !1
  ret i32 %after
}

!0 = !{!"root"}
!1 = !{!"int", !0}
!2 = !{!"float", !0}
