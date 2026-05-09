; RUN: opt -S -passes=sink < %s | FileCheck %s

; Verify that the Sink pass does not move read-only calls past atomic
; operations whose ordering creates a synchronization barrier. This is a
; regression test for a bug in
; AAResults::getModRefInfo(const Instruction *, const CallBase *), which
; previously skipped the atomic-ordering check that the instruction-specific
; getModRefInfo handlers perform, returning NoModRef for atomic ops whose
; address did not alias the call's accessed memory. The Sink pass would then
; sink the call past the atomic, breaking the release/acquire ordering.

declare i32 @read_arg(ptr) nounwind willreturn memory(argmem: read)
declare i32 @read_inaccessible() nounwind willreturn memory(inaccessiblemem: read)

; A release store must act as a memory barrier for preceding loads, even when
; the call accesses a noalias location. The call must remain in entry.
define i32 @no_sink_past_release_store(ptr noalias %flag, ptr %data, i1 %cond) {
; CHECK-LABEL: @no_sink_past_release_store(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[V:%.*]] = call i32 @read_arg(ptr %data)
; CHECK-NEXT:    store atomic i32 1, ptr %flag release, align 4
; CHECK-NEXT:    br i1 %cond, label %then, label %else
entry:
  %v = call i32 @read_arg(ptr %data)
  store atomic i32 1, ptr %flag release, align 4
  br i1 %cond, label %then, label %else

then:
  ret i32 %v

else:
  ret i32 0
}

; An unordered store has no ordering effect, so the call IS allowed to sink.
; This proves the fix is targeted at ordered atomics and not over-conservative.
define i32 @sink_past_unordered_store(ptr noalias %flag, ptr %data, i1 %cond) {
; CHECK-LABEL: @sink_past_unordered_store(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    store atomic i32 1, ptr %flag unordered, align 4
; CHECK-NEXT:    br i1 %cond, label %then, label %else
; CHECK:       then:
; CHECK-NEXT:    [[V:%.*]] = call i32 @read_arg(ptr %data)
; CHECK-NEXT:    ret i32 [[V]]
entry:
  %v = call i32 @read_arg(ptr %data)
  store atomic i32 1, ptr %flag unordered, align 4
  br i1 %cond, label %then, label %else

then:
  ret i32 %v

else:
  ret i32 0
}

; A seq_cst cmpxchg synchronizes arbitrary addresses; the call must not sink.
define i32 @no_sink_past_seqcst_cmpxchg(ptr noalias %lock, i1 %cond) {
; CHECK-LABEL: @no_sink_past_seqcst_cmpxchg(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[X:%.*]] = call i32 @read_inaccessible()
; CHECK-NEXT:    [[PAIR:%.*]] = cmpxchg ptr %lock, i32 0, i32 1 seq_cst seq_cst, align 4
; CHECK-NEXT:    br i1 %cond, label %then, label %else
entry:
  %x = call i32 @read_inaccessible()
  %pair = cmpxchg ptr %lock, i32 0, i32 1 seq_cst seq_cst
  br i1 %cond, label %then, label %else

then:
  ret i32 %x

else:
  ret i32 0
}

; An acq_rel atomicrmw synchronizes arbitrary addresses; the call must not sink.
define i32 @no_sink_past_acqrel_atomicrmw(ptr noalias %counter, i1 %cond) {
; CHECK-LABEL: @no_sink_past_acqrel_atomicrmw(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[X:%.*]] = call i32 @read_inaccessible()
; CHECK-NEXT:    [[OLD:%.*]] = atomicrmw add ptr %counter, i32 1 acq_rel, align 4
; CHECK-NEXT:    br i1 %cond, label %then, label %else
entry:
  %x = call i32 @read_inaccessible()
  %old = atomicrmw add ptr %counter, i32 1 acq_rel
  br i1 %cond, label %then, label %else

then:
  ret i32 %x

else:
  ret i32 0
}

; A monotonic atomicrmw has no ordering effects on arbitrary addresses, so
; the call IS allowed to sink past it (provided the addresses are noalias).
define i32 @sink_past_monotonic_atomicrmw(ptr noalias %counter, i1 %cond) {
; CHECK-LABEL: @sink_past_monotonic_atomicrmw(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[OLD:%.*]] = atomicrmw add ptr %counter, i32 1 monotonic, align 4
; CHECK-NEXT:    br i1 %cond, label %then, label %else
; CHECK:       then:
; CHECK-NEXT:    [[X:%.*]] = call i32 @read_inaccessible()
; CHECK-NEXT:    ret i32 [[X]]
entry:
  %x = call i32 @read_inaccessible()
  %old = atomicrmw add ptr %counter, i32 1 monotonic
  br i1 %cond, label %then, label %else

then:
  ret i32 %x

else:
  ret i32 0
}

; An acquire load also has ordering effects on arbitrary addresses; a call
; that follows it must not be reordered before via sinking.
define i32 @no_sink_past_acquire_load(ptr noalias %flag, ptr %data, i1 %cond) {
; CHECK-LABEL: @no_sink_past_acquire_load(
; CHECK-NEXT:  entry:
; CHECK-NEXT:    [[V:%.*]] = call i32 @read_arg(ptr %data)
; CHECK-NEXT:    [[F:%.*]] = load atomic i32, ptr %flag acquire, align 4
; CHECK-NEXT:    br i1 %cond, label %then, label %else
entry:
  %v = call i32 @read_arg(ptr %data)
  %f = load atomic i32, ptr %flag acquire, align 4
  br i1 %cond, label %then, label %else

then:
  ret i32 %v

else:
  ret i32 %f
}
