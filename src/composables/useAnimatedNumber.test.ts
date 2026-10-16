import { describe, it, expect } from 'vitest'
import { stepValue, STEP_THRESHOLD, STEP_MS, MAX_TWEEN_MS } from './useAnimatedNumber'

describe('stepValue', () => {
  it('holds steady at zero delta', () => {
    expect(stepValue(10, 10, 500)).toBe(10)
  })

  it('counts one by one for small deltas', () => {
    const steps = 3
    const total = steps * STEP_MS
    expect(stepValue(11, 14, 0)).toBe(11)
    expect(stepValue(11, 14, total * 0.2)).toBe(12)
    expect(stepValue(11, 14, total * 0.6)).toBe(13)
    expect(stepValue(11, 14, total)).toBe(14)
  })

  it('lands exactly on the target when elapsed reaches the budget', () => {
    expect(stepValue(0, STEP_THRESHOLD, STEP_THRESHOLD * STEP_MS)).toBe(STEP_THRESHOLD)
    expect(stepValue(0, -STEP_THRESHOLD, STEP_THRESHOLD * STEP_MS)).toBe(-STEP_THRESHOLD)
  })

  it('never overshoots a small delta', () => {
    for (let elapsed = 0; elapsed < 5000; elapsed += 37) {
      const v = stepValue(100, 104, elapsed)
      expect(v).toBeGreaterThanOrEqual(100)
      expect(v).toBeLessThanOrEqual(104)
    }
  })

  it('tweens smoothly for large deltas and finishes inside the cap', () => {
    const duration = Math.min(MAX_TWEEN_MS, 250 + 900 * 4)
    expect(duration).toBeLessThanOrEqual(MAX_TWEEN_MS)
    expect(stepValue(0, 900, 0)).toBe(0)
    expect(stepValue(0, 900, duration / 2)).toBeGreaterThan(450)
    expect(stepValue(0, 900, duration)).toBe(900)
  })

  it('clamps past the end of the tween', () => {
    expect(stepValue(0, 500, 99999)).toBe(500)
  })

  it('handles negative large deltas symmetrically', () => {
    const duration = Math.min(MAX_TWEEN_MS, 250 + 900 * 4)
    expect(stepValue(900, 0, duration)).toBe(0)
    expect(stepValue(900, 0, duration / 2)).toBeLessThan(450)
  })
})
