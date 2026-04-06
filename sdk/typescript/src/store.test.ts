import { describe, test, expect } from "bun:test";
import * as fc from "fast-check";
import { flatten, unflatten } from "./store";

/** Recursively check that no nested object is empty (would be lost in flatten/unflatten) */
function hasNoEmptyObjects(val: unknown): boolean {
  if (val === null || typeof val !== "object" || Array.isArray(val)) return true;
  const obj = val as Record<string, unknown>;
  if (Object.keys(obj).length === 0) return false;
  return Object.values(obj).every(hasNoEmptyObjects);
}

/**
 * Property 14: Flatten/unflatten round-trip
 * Validates: Requirements 5.1
 *
 * Constraints:
 * - Keys must not contain `_` (single underscore), because a key ending/starting with `_`
 *   adjacent to the `__` separator creates ambiguous splits (e.g. key `_` + `__` = `___`)
 * - No empty nested objects (they produce no flat keys and are lost on unflatten)
 * - Leaf values are primitives only (no nested objects inside arrays)
 */
describe("flatten/unflatten", () => {
  test("Property 14: unflatten(flatten(obj)) deep-equals the original for objects with primitive leaf values", () => {
    fc.assert(
      fc.property(
        fc
          .object({
            key: fc
              .string({ minLength: 1 })
              .filter((k) => !k.includes("_")),
            values: [fc.string(), fc.integer(), fc.boolean(), fc.constant(null)],
          })
          .filter(hasNoEmptyObjects),
        (obj) => {
          const result = unflatten(flatten(obj));
          expect(result).toEqual(obj);
        }
      ),
      { numRuns: 100 }
    );
  });
});
