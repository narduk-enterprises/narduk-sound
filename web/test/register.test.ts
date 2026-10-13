import { describe, expect, it } from "vitest";
import { registerVisualizer, VISUALIZERS, visualizer, visualizers } from "../src/index.js";

describe("registerVisualizer", () => {
  it("puts an app's own look first and resolves it by id", () => {
    registerVisualizer({ id: "test-look", title: "Test", glsl: "void main() { fragColor = vec4(1.0); }", image: "/a.png" });
    expect(visualizers()[0].id).toBe("test-look");
    expect(visualizers()).toHaveLength(VISUALIZERS.length + 1);
    expect(visualizer("test-look").image).toBe("/a.png");
  });

  it("replaces a look registered again under the same id", () => {
    registerVisualizer({ id: "test-look", title: "Test 2", glsl: "" });
    expect(visualizers().filter((v) => v.id === "test-look")).toHaveLength(1);
    expect(visualizer("test-look").title).toBe("Test 2");
  });

  it("refuses to shadow a built-in port", () => {
    expect(() => registerVisualizer({ id: "halo", title: "Halo", glsl: "" })).toThrow(/built-in/);
  });
});
