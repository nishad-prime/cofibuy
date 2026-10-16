import type { ChartOptions } from 'chart.js'

export const CHART_COLORS = {
  brand: '#0f766e',
  brandSoft: 'rgba(13, 148, 136, 0.38)',
  brandPale: '#5eead4',
  slate: '#94a3b8',
  amber: '#f59e0b',
  rose: '#f43f5e',
  sky: '#38bdf8',
  grid: 'rgba(255, 255, 255, 0.07)',
  text: '#a8a29e',
  tooltipBg: '#1c1917',
} as const

export function makeChartOptions<TType extends 'bar' | 'line' | 'doughnut'>(
  overrides: ChartOptions<TType> = {} as ChartOptions<TType>,
): ChartOptions<TType> {
  return {
    responsive: true,
    maintainAspectRatio: false,
    color: CHART_COLORS.text,
    plugins: {
      legend: {
        labels: { color: CHART_COLORS.text, usePointStyle: true, boxWidth: 8 },
      },
      tooltip: {
        backgroundColor: CHART_COLORS.tooltipBg,
        titleColor: '#fafaf9',
        bodyColor: '#d6d3d1',
        borderColor: 'rgba(255,255,255,.12)',
        borderWidth: 1,
        padding: 10,
        displayColors: true,
      },
    },
    ...overrides,
  } as ChartOptions<TType>
}
