import { onMounted, onUnmounted, ref } from 'vue'
import { rpc } from '@/lib/rpc'

export interface LiveSnapshot {
  views_total: number
  views_today: number
  orders_created_30d: number
  awaiting_review: number
  revenue_30d: number
  customers: number
}

const POLL_MS = 3000

export function useLiveStats() {
  const snapshot = ref<LiveSnapshot | null>(null)
  const lastUpdated = ref<number | null>(null)
  const connected = ref(false)

  let timer: ReturnType<typeof setTimeout> | null = null
  let inFlight = false
  let requestId = 0
  let stopped = false

  const tick = async (): Promise<void> => {
    if (inFlight || stopped || document.visibilityState !== 'visible') return
    inFlight = true
    const id = ++requestId
    try {
      const { data, error } = await rpc<LiveSnapshot>('admin_live_snapshot')
      if (error || !data) {
        connected.value = false
        return
      }
      if (id < requestId) return
      snapshot.value = data
      lastUpdated.value = Date.now()
      connected.value = true
    } catch {
      connected.value = false
    } finally {
      inFlight = false
    }
  }

  const schedule = (): void => {
    if (stopped) return
    timer = setTimeout(async () => {
      await tick()
      schedule()
    }, POLL_MS)
  }

  const onVisibility = (): void => {
    if (document.visibilityState === 'visible') {
      void tick()
    }
  }

  const start = (): void => {
    stopped = false
    document.addEventListener('visibilitychange', onVisibility)
    void tick()
    schedule()
  }

  const stop = (): void => {
    stopped = true
    if (timer) clearTimeout(timer)
    timer = null
    document.removeEventListener('visibilitychange', onVisibility)
  }

  onMounted(start)
  onUnmounted(stop)

  return { snapshot, lastUpdated, connected, refresh: tick }
}
