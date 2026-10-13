export { Loudness, PortableFFT, SoundAnalyzer, SpectrumAnalyzer, WINDOW_GAIN } from "./analysis.js";
export type { SpectrumWindow } from "./analysis.js";
export { AudioTap, audioContextClass, createStreamElement } from "./audio.js";
export type { SampleSource, SoundSourceInput } from "./audio.js";
export { FrameGovernor, RENDER_SCALES, SoundRenderBudget, isLowEndDevice } from "./budget.js";
export type { DeviceHints, GovernorDecision, SoundThermalState } from "./budget.js";
export { Canvas2DRenderer } from "./canvas2d.js";
export { SoundFrameLayout, emptyFrame } from "./frame.js";
export type { SoundFrame } from "./frame.js";
export { HIT_LANE_COUNT, Instrument, SoundMusicInference, emptyMusicContext } from "./inference.js";
export type { MusicContext } from "./inference.js";
export { isStatic, watchReducedMotion } from "./motion.js";
export type { MotionPreference } from "./motion.js";
export {
  DefaultSoundPaletteProvider,
  fromOklab,
  mixed,
  mixedPerceptually,
  oklab,
  sample,
  saturated,
} from "./palette.js";
export type { RGB, SongSection, SoundPalette, SoundPaletteDriver, SoundPaletteProvider } from "./palette.js";
export { mountSoundPlayer } from "./player.js";
export type { SoundPlayer, SoundPlayerOptions } from "./player.js";
export type { SoundRenderer } from "./renderer.js";
export { FlashLimiter, LumaWatchdog, calmIntensity, intenseDrive } from "./safety.js";
export type { IntenseDrive } from "./safety.js";
export { FRAGMENT_PRELUDE, PRESENT_SHADER, VERTEX_SHADER, VISUALIZERS, visualizer } from "./shaders/index.js";
export type { VisualizerId, VisualizerPort } from "./shaders/index.js";
export { SoundVisualState, wirewatcherConfiguration } from "./state.js";
export type { SoundVisualConfiguration, SoundVisualOptions } from "./state.js";
export { Aux, DATA_ROWS, DATA_WIDTH, DataRow, ShaderInputs, UNIFORM_NAMES, scopeTrigger } from "./uniforms.js";
export { SoundVisualizer } from "./visualizer.js";
export type { SoundVisualizerOptions, VisualizerStatus } from "./visualizer.js";
export { WebGLRenderer, WebGLUnavailableError } from "./webgl.js";
export { SyntheticSource } from "./synthetic.js";
