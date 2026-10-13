/**
 * Generated database types.
 *
 * Regenerate with `npm run db:types` against a linked project, or
 * `node scripts/generate-types.mjs` against the local test database.
 * The hand-maintained shape below is only the container; the contents are
 * produced by the generator so the app and the migrations cannot drift.
 */

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  api: {
    Tables: Record<never, never>
    Views: Record<never, never>
    Functions: {
      admin_ai_providers: { Args: Record<PropertyKey, never>; Returns: Json[] }
      admin_ai_settings: { Args: Record<PropertyKey, never>; Returns: Json[] }
      admin_analytics: {
        Args: {
          p_days?: number
          day?: string
          orders_created?: number
          orders_approved?: number
          revenue_approved?: number
        }
        Returns: Json[]
      }
      admin_auto_providers: { Args: Record<PropertyKey, never>; Returns: Json[] }
      admin_delete_gateway: {
        Args: {
          p_gateway_id: string
        }
        Returns: Json
      }
      admin_delete_page: {
        Args: {
          p_link_id: string
        }
        Returns: Json
      }
      admin_gateway_has_credentials: {
        Args: {
          p_gateway_id: string
        }
        Returns: boolean
      }
      admin_gateways: { Args: Record<PropertyKey, never>; Returns: Json[] }
      admin_order_detail: {
        Args: {
          p_order_id: string
        }
        Returns: Json
      }
      admin_order_duplicate_trxids: {
        Args: {
          p_order_id: string
          field_key?: string
          value_text_norm?: string
          other_order_ids?: string[]
        }
        Returns: Json[]
      }
      admin_order_payments: {
        Args: {
          p_order_id: string
        }
        Returns: Json
      }
      admin_orders: {
        Args: {
          p_status?: string
          p_reference?: string
          p_limit?: number
          id?: string
          slug?: string
          title_en?: string
          title_bn?: string
          kind?: string
          status?: Json
          reference_code?: string
          amount?: number
          phone_e164?: string
          attempt_count?: number
          probe_count?: number
          created_at?: string
          submitted_at?: string
          has_duplicate_trxid?: boolean
        }
        Returns: Json[]
      }
      admin_page_assets: {
        Args: {
          p_page_id: string
          slot_key?: string
          item_index?: number
          storage_path?: string
          public_url?: string
          alt_en?: string
          alt_bn?: string
          brief_en?: string
          brief_bn?: string
        }
        Returns: Json[]
      }
      admin_page_performance: {
        Args: {
          p_limit?: number
          slug?: string
          title_en?: string
          title_bn?: string
          orders_approved?: number
          revenue?: number
        }
        Returns: Json[]
      }
      admin_pages: { Args: Record<PropertyKey, never>; Returns: Json[] }
      admin_remove_page_asset: {
        Args: {
          p_page_id: string
          p_slot_key: string
          p_item_index: number
        }
        Returns: string
      }
      admin_remove_staff: {
        Args: {
          p_user_id: string
        }
        Returns: Json
      }
      admin_reset_probes: {
        Args: {
          p_order_id: string
        }
        Returns: Json
      }
      admin_set_settings: {
        Args: {
          p_settings: Json
        }
        Returns: Json
      }
      admin_set_staff: {
        Args: {
          p_email: string
          p_role: string
        }
        Returns: Json
      }
      admin_settings: { Args: Record<PropertyKey, never>; Returns: Json }
      admin_stats: { Args: Record<PropertyKey, never>; Returns: Json }
      admin_team: { Args: Record<PropertyKey, never>; Returns: Json[] }
      admin_upsert_ai_settings: {
        Args: {
          p_settings: Json
        }
        Returns: Json
      }
      admin_upsert_gateway: {
        Args: {
          p_gateway: Json
        }
        Returns: Json
      }
      admin_upsert_page: {
        Args: {
          p_page: Json
        }
        Returns: Json
      }
      admin_upsert_page_asset: {
        Args: {
          p_page_id: string
          p_slot_key: string
          p_item_index: number
          p_storage_path: string
          p_public_url: string
          p_alt_en: string
          p_alt_bn: string
          p_brief_en: string
          p_brief_bn: string
        }
        Returns: Json
      }
      ai_credential_bundle: { Args: Record<PropertyKey, never>; Returns: Json[] }
      approve_order: {
        Args: {
          p_order_id: string
        }
        Returns: Json
      }
      bkash_claim_refresh: {
        Args: {
          p_bundle_id: string
          p_environment: string
        }
        Returns: boolean
      }
      bkash_fail_session: {
        Args: {
          p_order_id: string
          p_payment_id: string
          p_reason?: string
        }
        Returns: Json
      }
      bkash_payment_claim: {
        Args: {
          p_order_id: string
          p_payment_id: string
        }
        Returns: Json
      }
      bkash_payment_lookup: {
        Args: {
          p_payment_id: string
        }
        Returns: Json
      }
      bkash_payment_start: {
        Args: {
          p_order_id: string
        }
        Returns: Json
      }
      bkash_record_session: {
        Args: {
          p_order_id: string
          p_payment_id: string
          p_amount: number
        }
        Returns: string
      }
      bkash_release_refresh: {
        Args: {
          p_bundle_id: string
          p_environment: string
        }
        Returns: Json
      }
      bkash_settle_order: {
        Args: {
          p_order_id: string
          p_payment_id: string
          p_trx_id: string
          p_payer_account?: string
          p_amount?: number
        }
        Returns: Json
      }
      bkash_store_token: {
        Args: {
          p_bundle_id: string
          p_environment: string
          p_id_token: string
          p_refresh_token: string
          p_expires_in: number
        }
        Returns: Json
      }
      bkash_token_state: {
        Args: {
          p_bundle_id: string
          p_environment: string
        }
        Returns: Json
      }
      claim_pending_recovery: {
        Args: {
          p_limit?: number
          id?: string
          phone_e164?: string
          purpose?: string
          created_at?: string
          expires_at?: string
          previous_attempts?: number
        }
        Returns: Json[]
      }
      create_order: {
        Args: {
          p_slug: string
          p_kind: string
          p_amount: number
        }
        Returns: Json
      }
      create_order_resolved: {
        Args: {
          p_slug: string
          p_kind: string
          p_amount: number
        }
        Returns: Json
      }
      create_order_unchecked: {
        Args: {
          p_slug: string
          p_gateway_id: string
          p_amount: number
        }
        Returns: Json
      }
      detach_order: {
        Args: {
          p_order_id: string
        }
        Returns: Json
      }
      gateway_credential_bundle: {
        Args: {
          p_gateway_id: string
        }
        Returns: string
      }
      get_public_page: {
        Args: {
          p_slug: string
        }
        Returns: Json
      }
      get_public_settings: { Args: Record<PropertyKey, never>; Returns: Json }
      get_unlocked_page: {
        Args: {
          p_slug: string
        }
        Returns: Json
      }
      list_public_pages: { Args: Record<PropertyKey, never>; Returns: Json[] }
      mark_undeliverable: {
        Args: {
          p_request_id: string
          p_reason?: string
        }
        Returns: Json
      }
      my_grants: { Args: Record<PropertyKey, never>; Returns: Json[] }
      my_order_status: {
        Args: {
          p_order_id: string
        }
        Returns: Json
      }
      my_orders: { Args: Record<PropertyKey, never>; Returns: Json[] }
      pay_online_start: {
        Args: {
          p_slug: string
          p_kind: string
          p_amount: number
        }
        Returns: Json
      }
      public_page_payload: {
        Args: {
          p_slug: string
        }
        Returns: Json
      }
      public_page_payload_v1: {
        Args: {
          p_slug: string
        }
        Returns: Json
      }
      record_otp_sent: {
        Args: {
          p_request_id: string
          p_otp_hash: string
          p_ttl_seconds?: number
        }
        Returns: Json
      }
      recover_access: {
        Args: {
          p_phone: string
          p_code: string
        }
        Returns: Json
      }
      reject_order: {
        Args: {
          p_order_id: string
          p_reason: string
          p_reason_bn?: string
          p_code?: string
        }
        Returns: Json
      }
      request_recovery: {
        Args: {
          p_phone: string
        }
        Returns: Json
      }
      secret_bundle_open: {
        Args: {
          p_bundle_id: string
        }
        Returns: Json
      }
      submit_evidence: {
        Args: {
          p_order_id: string
          p_fields: Json
          p_files?: Json
        }
        Returns: Json
      }
    }
    Enums: Record<never, never>
  }
  private: {
    Tables: Record<never, never>
    Views: Record<never, never>
    Functions: {
      audit_order: { Args: Record<PropertyKey, never>; Returns: Json }
      deny_mutation: { Args: Record<PropertyKey, never>; Returns: Json }
      effective_hide_min: {
        Args: {
          p_link: Json
          p_settings: Json
        }
        Returns: boolean
      }
      effective_min: {
        Args: {
          p_link: Json
          p_settings: Json
        }
        Returns: number
      }
      expire_stale_orders: { Args: Record<PropertyKey, never>; Returns: number }
      gen_reference_code: { Args: Record<PropertyKey, never>; Returns: string }
      grant_on_approval: { Args: Record<PropertyKey, never>; Returns: Json }
      guard_ai_provider_known: { Args: Record<PropertyKey, never>; Returns: Json }
      guard_evidence_fields: { Args: Record<PropertyKey, never>; Returns: Json }
      guard_gateway_kind_uniformity: { Args: Record<PropertyKey, never>; Returns: Json }
      guard_order_status: { Args: Record<PropertyKey, never>; Returns: Json }
      guard_page_template: { Args: Record<PropertyKey, never>; Returns: Json }
      guard_provider_known: { Args: Record<PropertyKey, never>; Returns: Json }
      is_owner: { Args: Record<PropertyKey, never>; Returns: boolean }
      is_staff: { Args: Record<PropertyKey, never>; Returns: boolean }
      normalize_bd_phone: {
        Args: {
          p_raw: string
        }
        Returns: string
      }
      normalize_reference: {
        Args: {
          p_raw: string
        }
        Returns: string
      }
      otp_hash: {
        Args: {
          p_plain: string
        }
        Returns: string
      }
      otp_matches: {
        Args: {
          p_plain: string
          p_hash: string
        }
        Returns: boolean
      }
      pick_gateway_for_kind: {
        Args: {
          p_kind: string
        }
        Returns: Json
      }
      provider_field_keys: {
        Args: {
          p_provider: string
          p_subject_kind: string
        }
        Returns: string[][]
      }
      prune_anonymous_users: { Args: Record<PropertyKey, never>; Returns: number }
      reap_stale_claims: { Args: Record<PropertyKey, never>; Returns: number }
      store_credential_bundle: {
        Args: {
          p_subject_kind: string
          p_subject_id: string
          p_provider: string
          p_bundle: Json
        }
        Returns: string
      }
      sweep: { Args: Record<PropertyKey, never>; Returns: Json }
      tidy_blank_to_null: { Args: Record<PropertyKey, never>; Returns: Json }
      to_latin_digits: {
        Args: {
          p_text: string
        }
        Returns: string
      }
      touch_updated_at: { Args: Record<PropertyKey, never>; Returns: Json }
      validate_account_fields: {
        Args: {
          p_fields: Json
        }
        Returns: Json
      }
      validate_evidence_fields: {
        Args: {
          p_fields: Json
        }
        Returns: Json
      }
      validate_evidence_value: {
        Args: {
          p_field: Json
          p_value: string
          p_file_path: string
        }
        Returns: Json
      }
    }
    Enums: Record<never, never>
  }
  public: {
    Tables: {
      access_grants: {
        Row: {
          user_id: string
          link_id: string
          via_order_id: string | null
          granted_at: string
          revoked_at: string | null
        }
        Insert: {
          user_id: string
          link_id: string
          via_order_id?: string | null
          granted_at?: string
          revoked_at?: string | null
        }
        Update: {
          user_id?: string
          link_id?: string
          via_order_id?: string | null
          granted_at?: string
          revoked_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: 'access_grants_link_id_fkey'
            columns: ['link_id']
            isOneToOne: true
            referencedRelation: 'pages'
            referencedColumns: ['id']
          },
          {
            foreignKeyName: 'access_grants_via_order_id_fkey'
            columns: ['via_order_id']
            isOneToOne: true
            referencedRelation: 'orders'
            referencedColumns: ['id']
          },
        ]
      }
      audit_log: {
        Row: {
          id: number
          actor_id: string | null
          action: string
          target_table: string | null
          target_id: string | null
          meta: Json
          created_at: string
        }
        Insert: {
          id: number
          action: string
          actor_id?: string | null
          target_table?: string | null
          target_id?: string | null
          meta?: Json
          created_at?: string
        }
        Update: {
          id?: number
          actor_id?: string | null
          action?: string
          target_table?: string | null
          target_id?: string | null
          meta?: Json
          created_at?: string
        }
        Relationships: []
      }
      customer_contacts: {
        Row: {
          user_id: string
          phone_e164: string
          telegram_chat_id: number | null
          linked_at: string
        }
        Insert: {
          user_id: string
          phone_e164: string
          telegram_chat_id?: number | null
          linked_at?: string
        }
        Update: {
          user_id?: string
          phone_e164?: string
          telegram_chat_id?: number | null
          linked_at?: string
        }
        Relationships: []
      }
      order_evidence: {
        Row: {
          id: number
          order_id: string
          field_key: string
          value_text_raw: string | null
          value_text_norm: string | null
          file_path: string | null
          attempt: number
          created_at: string
        }
        Insert: {
          id: number
          order_id: string
          field_key: string
          attempt: number
          value_text_raw?: string | null
          value_text_norm?: string | null
          file_path?: string | null
          created_at?: string
        }
        Update: {
          id?: number
          order_id?: string
          field_key?: string
          value_text_raw?: string | null
          value_text_norm?: string | null
          file_path?: string | null
          attempt?: number
          created_at?: string
        }
        Relationships: [
          {
            foreignKeyName: 'order_evidence_order_id_fkey'
            columns: ['order_id']
            isOneToOne: true
            referencedRelation: 'orders'
            referencedColumns: ['id']
          },
        ]
      }
      orders: {
        Row: {
          id: string
          user_id: string | null
          link_id: string
          gateway_id: string
          status:
            | 'draft'
            | 'awaiting_proof'
            | 'under_review'
            | 'approved'
            | 'rejected'
            | 'expired'
            | 'locked'
          reference_code: string
          amount: number
          min_amount_snapshot: number
          hide_min_snapshot: boolean
          phone_e164: string | null
          phone_raw: string | null
          attempt_count: number
          probe_count: number
          locked_at: string | null
          created_at: string
          expires_at: string
          submitted_at: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          reject_code: string | null
          reject_reason_en: string | null
          reject_reason_bn: string | null
        }
        Insert: {
          link_id: string
          gateway_id: string
          reference_code: string
          amount: number
          min_amount_snapshot: number
          expires_at: string
          id?: string
          user_id?: string | null
          status?:
            | 'draft'
            | 'awaiting_proof'
            | 'under_review'
            | 'approved'
            | 'rejected'
            | 'expired'
            | 'locked'
          hide_min_snapshot?: boolean
          phone_e164?: string | null
          phone_raw?: string | null
          attempt_count?: number
          probe_count?: number
          locked_at?: string | null
          created_at?: string
          submitted_at?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          reject_code?: string | null
          reject_reason_en?: string | null
          reject_reason_bn?: string | null
        }
        Update: {
          id?: string
          user_id?: string | null
          link_id?: string
          gateway_id?: string
          status?:
            | 'draft'
            | 'awaiting_proof'
            | 'under_review'
            | 'approved'
            | 'rejected'
            | 'expired'
            | 'locked'
          reference_code?: string
          amount?: number
          min_amount_snapshot?: number
          hide_min_snapshot?: boolean
          phone_e164?: string | null
          phone_raw?: string | null
          attempt_count?: number
          probe_count?: number
          locked_at?: string | null
          created_at?: string
          expires_at?: string
          submitted_at?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          reject_code?: string | null
          reject_reason_en?: string | null
          reject_reason_bn?: string | null
        }
        Relationships: [
          {
            foreignKeyName: 'orders_gateway_id_fkey'
            columns: ['gateway_id']
            isOneToOne: true
            referencedRelation: 'payment_gateways'
            referencedColumns: ['id']
          },
          {
            foreignKeyName: 'orders_link_id_fkey'
            columns: ['link_id']
            isOneToOne: true
            referencedRelation: 'pages'
            referencedColumns: ['id']
          },
          {
            foreignKeyName: 'orders_reviewed_by_fkey'
            columns: ['reviewed_by']
            isOneToOne: false
            referencedRelation: 'users'
            referencedColumns: ['id']
          },
        ]
      }
      otp_challenges: {
        Row: {
          id: string
          recovery_request_id: string
          phone_e164: string
          otp_hash: string
          attempt_count: number
          max_attempts: number
          consumed_at: string | null
          expires_at: string
          created_at: string
        }
        Insert: {
          recovery_request_id: string
          phone_e164: string
          otp_hash: string
          expires_at: string
          id?: string
          attempt_count?: number
          max_attempts?: number
          consumed_at?: string | null
          created_at?: string
        }
        Update: {
          id?: string
          recovery_request_id?: string
          phone_e164?: string
          otp_hash?: string
          attempt_count?: number
          max_attempts?: number
          consumed_at?: string | null
          expires_at?: string
          created_at?: string
        }
        Relationships: [
          {
            foreignKeyName: 'otp_challenges_recovery_request_id_fkey'
            columns: ['recovery_request_id']
            isOneToOne: true
            referencedRelation: 'recovery_requests'
            referencedColumns: ['id']
          },
        ]
      }
      pages: {
        Row: {
          id: string
          slug: string
          title_en: string | null
          title_bn: string | null
          teaser_md_en: string | null
          teaser_md_bn: string | null
          unlock_body_md_en: string | null
          unlock_body_md_bn: string | null
          unlock_cta_label_en: string | null
          unlock_cta_label_bn: string | null
          unlock_cta_url: string | null
          min_amount_override: number | null
          hide_min_override: boolean | null
          is_active: boolean
          sort_order: number
          created_at: string
          updated_at: string
          is_listed: boolean
          template: string
          template_config: Json
          amount_presets: Json
          fixed_amount: number | null
        }
        Insert: {
          slug: string
          id?: string
          title_en?: string | null
          title_bn?: string | null
          teaser_md_en?: string | null
          teaser_md_bn?: string | null
          unlock_body_md_en?: string | null
          unlock_body_md_bn?: string | null
          unlock_cta_label_en?: string | null
          unlock_cta_label_bn?: string | null
          unlock_cta_url?: string | null
          min_amount_override?: number | null
          hide_min_override?: boolean | null
          is_active?: boolean
          sort_order?: number
          created_at?: string
          updated_at?: string
          is_listed?: boolean
          template?: string
          template_config?: Json
          amount_presets?: Json
          fixed_amount?: number | null
        }
        Update: {
          id?: string
          slug?: string
          title_en?: string | null
          title_bn?: string | null
          teaser_md_en?: string | null
          teaser_md_bn?: string | null
          unlock_body_md_en?: string | null
          unlock_body_md_bn?: string | null
          unlock_cta_label_en?: string | null
          unlock_cta_label_bn?: string | null
          unlock_cta_url?: string | null
          min_amount_override?: number | null
          hide_min_override?: boolean | null
          is_active?: boolean
          sort_order?: number
          created_at?: string
          updated_at?: string
          is_listed?: boolean
          template?: string
          template_config?: Json
          amount_presets?: Json
          fixed_amount?: number | null
        }
        Relationships: []
      }
      payment_gateways: {
        Row: {
          id: string
          kind: string
          account_number: string | null
          account_name: string | null
          name_en: string
          name_bn: string | null
          instructions_md_en: string | null
          instructions_md_bn: string | null
          reference_prompt_en: string | null
          reference_prompt_bn: string | null
          supports_reference: boolean
          evidence_fields: Json
          is_active: boolean
          sort_order: number
          created_at: string
          updated_at: string
          provider: string | null
          account_fields: Json
          environment: string
          weight: number
          country: string | null
          is_primary_for_country: boolean
          banner_url: string | null
          banner_small_url: string | null
        }
        Insert: {
          kind: string
          name_en: string
          id?: string
          account_number?: string | null
          account_name?: string | null
          name_bn?: string | null
          instructions_md_en?: string | null
          instructions_md_bn?: string | null
          reference_prompt_en?: string | null
          reference_prompt_bn?: string | null
          supports_reference?: boolean
          evidence_fields?: Json
          is_active?: boolean
          sort_order?: number
          created_at?: string
          updated_at?: string
          provider?: string | null
          account_fields?: Json
          environment?: string
          weight?: number
          country?: string | null
          is_primary_for_country?: boolean
          banner_url?: string | null
          banner_small_url?: string | null
        }
        Update: {
          id?: string
          kind?: string
          account_number?: string | null
          account_name?: string | null
          name_en?: string
          name_bn?: string | null
          instructions_md_en?: string | null
          instructions_md_bn?: string | null
          reference_prompt_en?: string | null
          reference_prompt_bn?: string | null
          supports_reference?: boolean
          evidence_fields?: Json
          is_active?: boolean
          sort_order?: number
          created_at?: string
          updated_at?: string
          provider?: string | null
          account_fields?: Json
          environment?: string
          weight?: number
          country?: string | null
          is_primary_for_country?: boolean
          banner_url?: string | null
          banner_small_url?: string | null
        }
        Relationships: []
      }
      payment_sessions: {
        Row: {
          id: string
          order_id: string
          provider: string
          provider_payment_id: string
          provider_trx_id: string | null
          provider_account: string | null
          status: string
          amount: number
          currency: string
          created_at: string
          executed_at: string | null
        }
        Insert: {
          order_id: string
          provider: string
          provider_payment_id: string
          amount: number
          id?: string
          provider_trx_id?: string | null
          provider_account?: string | null
          status?: string
          currency?: string
          created_at?: string
          executed_at?: string | null
        }
        Update: {
          id?: string
          order_id?: string
          provider?: string
          provider_payment_id?: string
          provider_trx_id?: string | null
          provider_account?: string | null
          status?: string
          amount?: number
          currency?: string
          created_at?: string
          executed_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: 'payment_sessions_order_id_fkey'
            columns: ['order_id']
            isOneToOne: true
            referencedRelation: 'orders'
            referencedColumns: ['id']
          },
        ]
      }
      recovery_requests: {
        Row: {
          id: string
          phone_e164: string
          purpose: string
          status: 'pending' | 'sent' | 'verified' | 'expired' | 'failed' | 'undeliverable'
          requester_user_id: string | null
          request_ip_hash: string | null
          attempt_count: number
          sent_at: string | null
          verified_at: string | null
          expires_at: string
          created_at: string
        }
        Insert: {
          phone_e164: string
          expires_at: string
          id?: string
          purpose?: string
          status?: 'pending' | 'sent' | 'verified' | 'expired' | 'failed' | 'undeliverable'
          requester_user_id?: string | null
          request_ip_hash?: string | null
          attempt_count?: number
          sent_at?: string | null
          verified_at?: string | null
          created_at?: string
        }
        Update: {
          id?: string
          phone_e164?: string
          purpose?: string
          status?: 'pending' | 'sent' | 'verified' | 'expired' | 'failed' | 'undeliverable'
          requester_user_id?: string | null
          request_ip_hash?: string | null
          attempt_count?: number
          sent_at?: string | null
          verified_at?: string | null
          expires_at?: string
          created_at?: string
        }
        Relationships: []
      }
      site_settings: {
        Row: {
          id: number
          min_amount: number
          hide_min_amount: boolean
          default_lang: string
          recovery_enabled: boolean
          contact: string | null
          updated_at: string
          maintenance_mode: boolean
          currency: string
          index_heading_en: string | null
          index_heading_bn: string | null
          index_subheading_en: string | null
          index_subheading_bn: string | null
        }
        Insert: {
          id?: number
          min_amount?: number
          hide_min_amount?: boolean
          default_lang?: string
          recovery_enabled?: boolean
          contact?: string | null
          updated_at?: string
          maintenance_mode?: boolean
          currency?: string
          index_heading_en?: string | null
          index_heading_bn?: string | null
          index_subheading_en?: string | null
          index_subheading_bn?: string | null
        }
        Update: {
          id?: number
          min_amount?: number
          hide_min_amount?: boolean
          default_lang?: string
          recovery_enabled?: boolean
          contact?: string | null
          updated_at?: string
          maintenance_mode?: boolean
          currency?: string
          index_heading_en?: string | null
          index_heading_bn?: string | null
          index_subheading_en?: string | null
          index_subheading_bn?: string | null
        }
        Relationships: []
      }
      staff: {
        Row: {
          user_id: string
          role: 'staff' | 'owner'
          created_at: string
        }
        Insert: {
          user_id: string
          role: 'staff' | 'owner'
          created_at?: string
        }
        Update: {
          user_id?: string
          role?: 'staff' | 'owner'
          created_at?: string
        }
        Relationships: [
          {
            foreignKeyName: 'staff_user_id_fkey'
            columns: ['user_id']
            isOneToOne: false
            referencedRelation: 'users'
            referencedColumns: ['id']
          },
        ]
      }
    }
    Views: {
      pages_public: {
        Row: {
          id: string | null
          slug: string | null
          title_en: string | null
          title_bn: string | null
          teaser_md_en: string | null
          teaser_md_bn: string | null
          unlock_cta_label_en: string | null
          unlock_cta_label_bn: string | null
          unlock_cta_url: string | null
          template: string | null
          template_config: Json | null
          sort_order: number | null
        }
        Relationships: []
      }
      payment_gateways_public: {
        Row: {
          id: string | null
          kind: string | null
          provider: string | null
          name_en: string | null
          name_bn: string | null
          sort_order: number | null
          country: string | null
          is_primary_for_country: boolean | null
          banner_url: string | null
          banner_small_url: string | null
        }
        Relationships: []
      }
    }
    Functions: Record<never, never>
    Enums: {
      evidence_type: 'text' | 'textarea' | 'number' | 'image'
      field_validator: 'bd_phone' | 'trxid' | 'numeric'
      order_status:
        'draft' | 'awaiting_proof' | 'under_review' | 'approved' | 'rejected' | 'expired' | 'locked'
      recovery_status: 'pending' | 'sent' | 'verified' | 'expired' | 'failed' | 'undeliverable'
      staff_role: 'staff' | 'owner'
    }
  }
}

type DefaultSchema = Database[Extract<keyof Database, 'public'>]

export type Tables<
  PublicTableNameOrOptions extends
    keyof (Database['public']['Tables'] & Database['public']['Views']) | { schema: keyof Database },
  TableName extends (PublicTableNameOrOptions extends { schema: keyof Database }
    ? keyof (Database[PublicTableNameOrOptions['schema']]['Tables'] &
        Database[PublicTableNameOrOptions['schema']]['Views'])
    : never) = never,
> = PublicTableNameOrOptions extends { schema: keyof Database }
  ? (Database[PublicTableNameOrOptions['schema']]['Tables'] &
      Database[PublicTableNameOrOptions['schema']]['Views'])[TableName] & {
      Row: Record<string, unknown>
      Insert: Record<string, unknown>
      Update: Record<string, unknown>
    }
  : PublicTableNameOrOptions extends keyof (DefaultSchema['Tables'] & DefaultSchema['Views'])
    ? (DefaultSchema['Tables'] & DefaultSchema['Views'])[PublicTableNameOrOptions] & {
        Row: Record<string, unknown>
        Insert: Record<string, unknown>
        Update: Record<string, unknown>
      }
    : never

export type TablesInsert<PublicTableName extends keyof DefaultSchema['Tables']> =
  (DefaultSchema['Tables'][PublicTableName] & { Insert: unknown })['Insert']

export type TablesUpdate<PublicTableName extends keyof DefaultSchema['Tables']> =
  (DefaultSchema['Tables'][PublicTableName] & { Update: unknown })['Update']

export type Enums<PublicEnumName extends keyof DefaultSchema['Enums']> =
  DefaultSchema['Enums'][PublicEnumName]
