import { ref, watch, onUnmounted, type Ref } from 'vue'
import { getSupabase } from '@/lib/supabase'
import type { Database } from '@/lib/database.types'

type OrderStatus = Database['public']['Enums']['order_status']

interface OrderStatusResponse {
  status: OrderStatus
  expires_at: string | null
  locked_until: string | null
  attempts: number
  reference_code: string | null
  reject_reason: string | null
  approved_at: string | null
  rejected_at: string | null
  evidence_submitted_at: string | null
}

export interface OrderPollingState {
  status: Ref<OrderStatus | null>
  order: Ref<OrderStatusResponse | null>
  error: Ref<string | null>
  isPolling: Ref<boolean>
  refresh: () => Promise<void>
  startPolling: () => void
  stopPolling: () => void
}

const TERMINAL_STATUSES: OrderStatus[] = ['approved', 'rejected', 'expired', 'locked']

export function useOrderPolling(orderId: string): OrderPollingState {
  const supabase = getSupabase()
  const status = ref<OrderStatus | null>(null)
  const order = ref<OrderStatusResponse | null>(null)
  const error = ref<string | null>(null)
  const isPolling = ref(false)

  let pollInterval: number | null = null

  const refresh = async (): Promise<void> => {
    try {
      const { data, error: rpcError } = await (supabase.rpc as any)('my_order_status', {
        p_order_id: orderId,
      })

      if (rpcError) {
        error.value = rpcError.message
        return
      }

      if (data) {
        const parsed = data as unknown as OrderStatusResponse
        order.value = parsed
        status.value = parsed.status
        error.value = null
      }
    } catch (err) {
      error.value = err instanceof Error ? err.message : 'Unknown error'
    }
  }

  const stopPolling = (): void => {
    if (pollInterval !== null) {
      clearInterval(pollInterval)
      pollInterval = null
    }
    isPolling.value = false
  }

  const startPolling = (): void => {
    if (isPolling.value) {
      return
    }
    isPolling.value = true
    void refresh()

    pollInterval = window.setInterval(() => {
      void refresh()
    }, 5000)
  }

  watch(status, (newStatus) => {
    if (newStatus && TERMINAL_STATUSES.includes(newStatus)) {
      stopPolling()
    }
  })

  onUnmounted(() => {
    stopPolling()
  })

  return {
    status,
    order,
    error,
    isPolling,
    refresh,
    startPolling,
    stopPolling,
  }
}
