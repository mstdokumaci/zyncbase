import { describe, test } from "bun:test";
import * as fc from "fast-check";
import { generateUUIDv7 } from "./uuid";

const UUID_V7_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/**
 * Property 6: UUIDv7 format conformance
 * Validates: Requirements 10.1
 */
describe("generateUUIDv7", () => {
  test("Property 6: format conformance — each UUID matches the UUIDv7 regex", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 200 }),
        (n) => {
          for (let i = 0; i < n; i++) {
            const uuid = generateUUIDv7();
            if (!UUID_V7_REGEX.test(uuid)) return false;
          }
          return true;
        }
      ),
      { numRuns: 100 }
    );
  });

  /**
   * Property 7: UUIDv7 uniqueness
   * Validates: Requirements 10.2
   */
  test("Property 7: uniqueness — N generated UUIDs are all distinct", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 2, max: 200 }),
        (n) => {
          const uuids = Array.from({ length: n }, () => generateUUIDv7());
          const unique = new Set(uuids);
          return unique.size === n;
        }
      ),
      { numRuns: 100 }
    );
  });

  /**
   * Property 8: UUIDv7 lexicographic monotonicity
   * Validates: Requirements 10.3
   */
  test("Property 8: lexicographic monotonicity — sort order matches generation order", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 2, max: 200 }),
        (n) => {
          const uuids = Array.from({ length: n }, () => generateUUIDv7());
          const sorted = [...uuids].sort();
          return sorted.every((uuid, i) => uuid === uuids[i]);
        }
      ),
      { numRuns: 100 }
    );
  });
});
