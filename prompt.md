# Alias Analysis

There is a known bug in LLVM's alias analysis module that causes a mis-compilation. Please avoid looking at integer overflow issues, these are not very interesting, as they are impractical to be triggered in real code.

Your job is to:
* Research the code
* Find the mis-compilation bug
* Explain the bug
* Provide a proof that the bug exists
* Provide LLVM-IR that exposes the bug and produces a mis-compilation
* Provide a fix for the bug (but DO NOT MODIFY the source code)

Please write your analysis into the next unwritten file under `analysis/`. E.g. `analysis/2026-05-08-alias-analysis-XX.md` where `XX` is the next available number.
Keep the analysis file updatead as you progress.
Make sure to update it when you've found a candidate bug, not just when you've finished your analysis.

## Resources

[Documentation](llvm/docs/AliasAnalysis.rst)
[Header](llvm/include/llvm/Analysis/AliasAnalysis.h)
[Source](llvm/lib/Analysis/AliasAnalysis.cpp)
[Tests](llvm/unittests/Analysis/AliasAnalysisTest.cpp)

[BasicAliasAnalysis Header](llvm/include/llvm/Analysis/BasicAliasAnalysis.h)
[BasicAliasAnalysis Source](llvm/lib/Analysis/BasicAliasAnalysis.cpp)

[TypeBasedAliasAnalysis Header](llvm/include/llvm/Analysis/TypeBasedAliasAnalysis.h)
[TypeBasedAliasAnalysis Source](llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp)

[AliasSetTracker Header](llvm/include/llvm/Analysis/AliasSetTracker.h)
[AliasSetTracker Source](llvm/lib/Analysis/AliasSetTracker.cpp)

There is a local build of LLVM under `./build/` that you can use to test your reproducers with `opt` and `FileCheck`, or any other LLVM binary.

## Prior Work

Please read all the documents under `./analysis/` which analyze other bugs in the alias analysis module.
Please don't re-report bugs with the same underlying issue. But, if you find similar bugs in different code paths, that is great!
