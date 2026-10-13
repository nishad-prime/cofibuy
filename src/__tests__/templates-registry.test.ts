import { describe, expect, it } from 'vitest'
import { normalizeConfig } from '@/pages/templates/registry'

describe('normalizeConfig (sales-landing)', () => {
  it('defaults the video fields for a config saved before they existed', () => {
    const config = normalizeConfig('sales-landing', {
      hero_title_en: 'Old page',
    })
    expect(config['video_url']).toBe('')
    expect(config['hero_video_cta_en']).toBe('')
    expect(config['hero_video_cta_bn']).toBe('')
    expect(config['video_heading_en']).toBe('')
    expect(config['video_heading_bn']).toBe('')
  })

  it('keeps a stored video url and drops a non-string one', () => {
    const kept = normalizeConfig('sales-landing', { video_url: 'https://r2.example/video.mp4' })
    expect(kept['video_url']).toBe('https://r2.example/video.mp4')

    const dropped = normalizeConfig('sales-landing', { video_url: 42 })
    expect(dropped['video_url']).toBe('')
  })

  it('normalizes an empty or non-object config to all-default video fields', () => {
    const config = normalizeConfig('sales-landing', null)
    expect(config['video_url']).toBe('')
  })
})
