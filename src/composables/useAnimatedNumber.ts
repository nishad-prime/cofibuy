import { computed, onUnmounted, ref } from 'vue'

export const STEP_THRESHOLD = 15
export const STEP_MS = 130
export const MAX_TWEEN_MS = 900

const easeOutCubic = (t: number): number => 1 - Math.pow(1 - t, 3)

export function stepValue(from: number, to: number, elapsed: number): number {
  const delta = to - from
  if (delta === 0) return to
  if (Math.abs(delta) <= STEP_THRESHOLD) {
    const steps = Math.abs(delta)
    const progress = Math.min(elapsed / (steps * STEP_MS), 1)
    return from + Math.sign(delta) * Math.round(progress * steps)
  }
  const duration = Math.min(MAX_TWEEN_MS, 250 + Math.abs(delta) * 4)
  const progress = Math.min(elapsed / duration, 1)
  return Math.round(from + delta * easeOutCubic(progress))
}

export function useAnimatedNumber(initial: number) {
  const target = ref(initial)
  const displayed = ref(initial)
  let raf: ReturnType<typeof requestAnimationFrame> | null = null
  let animFrom = initial
  let startTime: number | null = null

  const frame = (now: number): void => {
    if (startTime === null) startTime = now
    const value = stepValue(animFrom, target.value, now - startTime)
    displayed.value = value
    if (value === target.value) {
      raf = null
      startTime = null
      return
    }
    raf = requestAnimationFrame(frame)
  }

  const set = (next: number): void => {
    if (next === target.value) return
    if (raf !== null) cancelAnimationFrame(raf)
    animFrom = displayed.value
    startTime = null
    target.value = next
    raf = requestAnimationFrame(frame)
  }

  const seed = (value: number): void => {
    if (raf !== null) {
      cancelAnimationFrame(raf)
      raf = null
    }
    animFrom = value
    target.value = value
    displayed.value = value
    startTime = null
  }

  onUnmounted(() => {
    if (raf !== null) cancelAnimationFrame(raf)
  })

  return { displayed: computed(() => displayed.value), set, seed }
}
