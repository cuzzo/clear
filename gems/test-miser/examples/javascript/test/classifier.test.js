import assert from "node:assert/strict";
import { classify } from "../src/classifier.js";

describe("classify", () => {
  it("positive_primary", () => assert.equal(classify(5), "positive"));
  it("positive_duplicate", () => assert.equal(classify(5), "positive"));
  it("high", () => assert.equal(classify(11), "high"));
  it("nonpositive", () => assert.equal(classify(0), "nonpositive"));
  it("smoke", () => assert.ok(true));
});
