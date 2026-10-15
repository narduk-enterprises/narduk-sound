import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { Aux, FRAGMENT_PRELUDE, PRESENT_SHADER, UNIFORM_NAMES, VERTEX_SHADER, VISUALIZERS } from "../src/index.js";

const repo = new URL("../../", import.meta.url);
const read = (path: string) => readFileSync(new URL(path, repo), "utf8");

/** glslangValidator, from GLSLANG_VALIDATOR or the PATH. CI installs a pinned release and requires it. */
function validator(): string | null {
  const candidates = [process.env.GLSLANG_VALIDATOR, "glslangValidator"].filter(Boolean) as string[];
  for (const candidate of candidates) {
    try {
      execFileSync(candidate, ["--version"], { stdio: "ignore" });
      return candidate;
    } catch {
      /* try the next */
    }
  }
  return null;
}

describe("the GLSL ports", () => {
  it.each(VISUALIZERS.map((v) => [v.id, v] as const))("%s is in sync with its Metal source", (_, port) => {
    const hash = createHash("sha256").update(readFileSync(new URL(port.metalSource, repo))).digest("hex");
    expect(
      hash,
      `${port.metalSource} changed since the GLSL port was made. Re-port the change (docs/web-port.md), then set metalSha256 to ${hash}.`,
    ).toBe(port.metalSha256);
  });

  it.each(VISUALIZERS.map((v) => [v.id, v] as const))("%s has no Metal left in it", (_, port) => {
    const leftovers = [/\bfloat[234]\b/, /\bconstant\b/, /\bthread\b/, /\batan2\(/, /\bin\.uv\b/, /\[\[/, /\bstatic\b/, /\bfmod\(/, /\bsaturate\(/];
    for (const pattern of leftovers) expect(port.glsl, `${port.id} still says ${pattern}`).not.toMatch(pattern);
    // pow(x, 2.0) is undefined for negative x in GLSL; ports square with sq().
    expect(port.glsl).not.toMatch(/pow\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*,\s*2\.0\)/);
  });

  it("declares the uniform block in the Metal order", () => {
    const metal = read("Sources/NardukSoundVisuals/Intense/IntenseShaderCommon.swift");
    const metalFields = [...metal.slice(metal.indexOf("struct IntenseUniforms")).matchAll(/float4 (\w+);/g)]
      .slice(0, 10)
      .map((m) => m[1]);
    const glslFields = [...FRAGMENT_PRELUDE.slice(FRAGMENT_PRELUDE.indexOf("struct IntenseUniforms")).matchAll(/vec4 (\w+);/g)]
      .slice(0, 10)
      .map((m) => m[1]);
    expect(metalFields).toEqual([...UNIFORM_NAMES]);
    expect(glslFields).toEqual([...UNIFORM_NAMES]);
  });

  it("lays out the aux scalars as IntenseAux does", () => {
    const metal = read("Sources/NardukSoundVisuals/Intense/IntenseAux.swift");
    for (const [name, index] of Object.entries(Aux)) {
      const match = metal.match(new RegExp(`static let ${name} = (\\d+)\\b`));
      expect(match, `IntenseAux.${name}`).not.toBeNull();
      expect(Number(match![1]), `IntenseAux.${name}`).toBe(index);
    }
    expect(read("Sources/NardukSoundVisuals/Intense/ScopeMetal/ScopeMetalShader.swift")).toContain("aux[118]");
  });

  it("compiles every shader as GLSL ES 3.00", () => {
    const glslang = validator();
    if (!glslang) {
      if (process.env.CI) throw new Error("glslangValidator is required in CI (set GLSLANG_VALIDATOR)");
      console.warn("glslangValidator not found; GLSL compile check skipped");
      return;
    }
    const dir = mkdtempSync(join(tmpdir(), "sound-web-glsl-"));
    const sources: [string, string][] = [
      ["fullscreen.vert", VERTEX_SHADER],
      ["present.frag", PRESENT_SHADER],
      ...VISUALIZERS.map((v) => [`${v.id}.frag`, FRAGMENT_PRELUDE + v.glsl] as [string, string]),
    ];
    for (const [name, source] of sources) {
      const path = join(dir, name);
      writeFileSync(path, source);
      try {
        execFileSync(glslang, [path], { encoding: "utf8" });
      } catch (error) {
        const out = (error as { stdout?: string }).stdout ?? String(error);
        throw new Error(`${name} does not compile:\n${out}`);
      }
    }
  });
});
