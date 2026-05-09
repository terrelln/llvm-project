// This source demonstrates the closest Clang-generated shape I found:
// an ObjC ARC retain intrinsic with a funclet operand bundle.
//
// It is not a full source-level reproducer for the ObjCARCAA miscompile in
// analysis.md, because "funclet" is not a heap-clobbering operand bundle and
// does not carry the pointer being loaded/stored. The real miscompile requires
// a memory-affecting call-site bundle such as an unknown bundle on the ARC
// runtime call.
//
// Example IR generation:
//   build/bin/clang -cc1 -triple x86_64-windows-msvc \
//     -x objective-c++ -fobjc-arc -fobjc-exceptions \
//     -fexceptions -fcxx-exceptions -emit-llvm -o - \
//     analysis/21/objc-funclet-retain.mm

@class Ety;
void opaque(void);

void test_catch_with_objc_intrinsic(void) {
  @try {
    opaque();
  } @catch (Ety *ex) {
    (void)ex;
  }
}
