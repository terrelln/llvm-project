; Reproducer for analysis 17: getModRefInfo(Instruction, Instruction) bypasses
; atomic ordering checks for the second instruction (I2).
;
; aa-eval populates OtherMemOps with CallBase + atomic instructions, then tests
; all pairs via getModRefInfo(MemOpA, MemOpB) — the two-instruction overload.
;
; RUN: opt -aa-pipeline=basic-aa -passes=aa-eval -print-all-alias-modref-info -disable-output < %s 2>&1 | FileCheck %s

; @reader only reads its pointer argument — it does NOT access %flag.
declare void @reader(ptr %data) memory(argmem: read)

; CHECK-LABEL: Function: call_vs_release_store
define void @call_vs_release_store(ptr noalias %flag, ptr noalias %data) {
  call void @reader(ptr %data)
  store atomic i32 1, ptr %flag release, align 4
  ret void
}

; BUG: getModRefInfo(call @reader, store atomic release) returns NoModRef.
; The release store has ordering properties that affect arbitrary addresses,
; but I2's ordering is never checked — I2 is converted to MemoryLocation{%flag,4}
; and the CallBase handler for I1 only sees that @reader doesn't access %flag.
;
; CHECK:   NoModRef:   call void @reader(ptr %data) <->   store atomic i32 1, ptr %flag release, align 4
;
; Correct answer: ModRef (or at least Ref), because the release store's ordering
; affects all preceding memory operations.

; For comparison: two atomics with strong ordering produce the CORRECT result
; because I1's ordering is caught by I1's instruction-specific handler.
; CHECK-LABEL: Function: release_store_vs_acquire_load
define void @release_store_vs_acquire_load(ptr noalias %x, ptr noalias %y) {
  store atomic i32 1, ptr %x release, align 4
  %v = load atomic i32, ptr %y acquire, align 4
  ret void
}
; CHECK:   Both ModRef:   store atomic i32 1, ptr %x release, align 4 <->   %v = load atomic i32, ptr %y acquire, align 4
; CHECK:   Both ModRef:   %v = load atomic i32, ptr %y acquire, align 4 <->   store atomic i32 1, ptr %x release, align 4
