# Alias Analysis

There is a known bug in LLVM's alias analysis module that causes a mis-compilation. Please avoid looking at integer overflow issues, these are not very interesting, as they are impractical to be triggered in real code.

Your job is to:
* Research the code
* Find the mis-compilation bug
* Explain the bug
* Provide a proof that the bug exists
* Provide LLVM-IR that exposes the bug and produces a mis-compilation
* Provide a fix for the bug (but DO NOT MODIFY the source code)

Keep `analysis.md` updated with your progress and findings.

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

Please read the following documents which analyze other bugs in the alias analysis module. Please don't re-report bugs with the same underlying issue. But, if you find similar bugs in different code paths, that is great!

[Analysis 1](/home/terrelln/.llms/2026-05-08-alias-analysis.md)
[Analysis 2](/home/terrelln/.llms/2026-05-08-alias-analysis-2.md)
[Analysis 3](/home/terrelln/.llms/2026-05-08-alias-analysis-3.md)
[Analysis 4](/home/terrelln/.llms/2026-05-08-alias-analysis-4.md)
[Analysis 5](/home/terrelln/.llms/2026-05-08-alias-analysis-5.md)
[Analysis 6](/home/terrelln/.llms/2026-05-08-alias-analysis-6.md)
[Analysis 7](/home/terrelln/.llms/2026-05-08-alias-analysis-7.md)
[Analysis 8](/home/terrelln/.llms/2026-05-08-alias-analysis-8.md)
[Analysis 9](/home/terrelln/.llms/2026-05-08-alias-analysis-9.md)
