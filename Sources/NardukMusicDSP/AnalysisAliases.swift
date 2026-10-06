import NardukSoundAnalysis

// NardukSoundAnalysis owns the analysis primitives (narduk-libs#1568); these aliases keep existing
// `import NardukMusicDSP` code compiling.
public typealias SpectrumAnalyzer = NardukSoundAnalysis.SpectrumAnalyzer
public typealias SPSCRing<Element: BitwiseCopyable> = NardukSoundAnalysis.SPSCRing<Element>
