import { describe, expect, it } from "vitest";
import { canonicalize, hashJson } from "./index";

describe("JCS", () => {
  it("ordena claves y es estable ante el orden de entrada", () => {
    expect(canonicalize({ b: 1, a: [true, null, "x"] })).toBe('{"a":[true,null,"x"],"b":1}');
    expect(hashJson({ a: 1, b: 2 })).toBe(hashJson({ b: 2, a: 1 }));
  });
  it("rechaza valores no JSON", () => {
    expect(() => canonicalize({ a: Number.NaN })).toThrow();
    expect(() => canonicalize({ a: undefined })).toThrow();
    expect(() => canonicalize(new Date())).toThrow();
  });
  it("serializa números como ECMAScript (RFC 8785)", () => {
    expect(canonicalize([1e21, 0.1, -0, 2500])).toBe("[1e+21,0.1,0,2500]");
  });
});
