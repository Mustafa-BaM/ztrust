/** Role package key (system templates or custom packages created by the owner). */
export type Role = string
export type BusinessType = 'retail' | 'food' | 'services' | 'mixed'
export type Tender = 'cash' | 'card' | 'on_account' | 'payment_link' | 'bank_transfer' | 'store_credit' | 'platform' | 'loyalty' | 'package' | 'deposit' | 'gift_card' | 'cod' | 'other'

export interface Country {
  code: string; name_en: string; name_ar: string; currency: string; currency_decimals: number
  vat_rate: number; prices_include_tax: boolean; einvoice_regime: string | null; default_language: string; timezone: string
}

export interface Tenant {
  id: string; name: string; name_ar: string | null; country_code: string; currency: string; currency_decimals: number
  default_language: string; business_type: BusinessType; tax_number: string | null; vat_rate: number
  prices_include_tax: boolean; brand_color: string | null; logo_url: string | null; plan: string; trial_ends_at: string
  settings?: TenantSettings
  business_profile: string
  features: Record<string, boolean>
  addons?: Record<string, boolean>
}

export interface TenantSettings {
  pos_show_images?: boolean
  receipt_phones?: string; receipt_address?: string; receipt_cr?: string; receipt_website?: string
  receipt_header?: string; receipt_footer?: string; receipt_terms?: string
  logo_show?: boolean; logo_size?: 's' | 'm' | 'l'; logo_mono_url?: string
  receipt_font?: string; receipt_font_size?: 's' | 'm' | 'l'
  scale_prefix?: string; scale_plu_len?: number; scale_mode?: 'weight' | 'price'
  loyalty_earn?: number; loyalty_point_value?: number; loyalty_min_points?: number
  booking_online?: boolean; booking_step?: number; gift_card_months?: number; qr_ordering?: boolean
}

export interface ModifierGroup { id: string; name: string; name_ar: string | null; min_select: number; max_select: number; sort: number }
export interface ModifierOption { id: string; group_id: string; name: string; name_ar: string | null; price: number; item_id: string | null; qty: number; is_active: boolean; sort: number }
export interface Promotion {
  id: string; name: string; name_ar: string | null; kind: 'percent' | 'amount' | 'bxgy' | 'bundle'
  params: { percent?: number; amount?: number; min_amount?: number; buy?: number; get?: number; price?: number; components?: { item_id: string; qty: number }[] }
  item_ids: string[] | null; category_ids: string[] | null; min_qty: number; coupon_code: string | null
  starts_on: string | null; ends_on: string | null; weekdays: number[] | null; time_from: string | null; time_to: string | null; is_active: boolean
}
export interface CustomerPackage { id: string; customer_id: string; item_id: string; name: string; kind: string; sessions_total: number | null; sessions_used: number; price_paid: number; released: number; covers: string[] | null; expires_on: string; status: string }
export interface WorkOrder {
  id: string; branch_id: string; kind: 'job' | 'preorder'; number: string; customer_id: string | null; status: 'received' | 'in_progress' | 'ready' | 'collected' | 'cancelled'
  due_at: string | null; reference: string | null; tags: string | null; note: string | null; lines: { item_id: string; name: string; name_ar: string | null; qty: number; unit_price: number; note: string | null }[]
  total: number; deposit_paid: number; deposit_used: number; sale_id: string | null; created_at: string; ready_at: string | null
}
export interface OpenOrder { id: string; branch_id: string; table_id: string | null; label: string; guests: number | null; customer_id: string | null; lines: (CartLine & { modifiers?: string[]; modifier_names?: string | null })[]; status: string; opened_at: string }
export interface DiningTable { id: string; branch_id: string; area: string; name: string; seats: number; x: number; y: number; shape: 'square' | 'round' | 'long'; is_active: boolean; qr_token?: string }

export interface FeatureModule { key: string; name_en: string; name_ar: string; built: boolean; sort: number; universal?: boolean }
export interface BusinessProfile {
  key: string; name_en: string; name_ar: string; family: 'food' | 'retail' | 'services' | 'wholesale'
  pos_mode: 'grid' | 'scan' | 'calendar' | 'ticket'; launch: boolean; modules: Record<string, 1 | 2>; sort: number
}

export interface Membership {
  tenant_id: string; user_id: string; role: Role; display_name: string; branch_ids: string[] | null; is_active: boolean
  pin_hash?: string | null; tenants?: Tenant
}

export interface Branch { id: string; tenant_id: string; code: string; name: string; name_ar: string | null; timezone: string; lat?: number | null; lng?: number | null; geofence_m?: number }
export interface Category { id: string; tenant_id: string; name: string; name_ar: string | null; color: string | null; sort: number; station_id?: string | null }

export interface Item {
  id: string; tenant_id: string; category_id: string | null; name: string; name_ar: string | null; sku: string | null
  barcode: string | null; price: number; cost: number; tax_rate: number | null; track_stock: boolean; is_active: boolean
  image_url: string | null; item_type?: 'standard' | 'ingredient' | 'recipe' | 'service' | 'package' | 'gift_card'; unit?: string; reorder_point?: number | null
  parent_id?: string | null; is_template?: boolean; variant_attrs?: Record<string, string> | null; sold_by_weight?: boolean; plu?: string | null
  track_expiry?: boolean; commission_pct?: number | null; duration_min?: number | null
}

export interface Customer { id: string; tenant_id: string; name: string; phone: string | null; email: string | null; credit_limit: number; address?: string | null }

export interface SaleLine {
  id: string; item_id: string | null; name: string; qty: number; unit_price: number; discount: number; tax_rate: number
  net_amount: number; tax_amount: number; line_total: number; original_line_id: string | null
}
export interface Payment { id: string; tender: Tender; amount: number; status: string; reference: string | null; created_at: string }
export interface PayLink { token: string; amount: number; status: string; expires_at: string }

export interface Sale {
  id: string; tenant_id: string; branch_id: string; shift_id: string | null; client_id: string; doc_type: 'invoice' | 'credit_note'
  number: string; original_sale_id: string | null; customer_id: string | null; subtotal: number; discount_total: number
  tax_total: number; total: number; paid_total: number; refunded_total: number; status: string; reason: string | null
  created_by: string; created_at: string
  lines?: SaleLine[]; payments?: Payment[]; links?: PayLink[]; customer?: Customer | null
  offline?: boolean
}

export interface CartLine {
  key: string; item_id: string | null; name: string; name_ar: string | null; qty: number; unit_price: number
  list_price: number; discount: number; tax_rate: number; note?: string
  /** chosen add-ons (prices already included in unit_price / list_price) */
  modifiers?: { id: string; name: string; name_ar: string | null; price: number }[]
  /** discount from a promotion, filled by the promotion engine */
  promo_discount?: number; promo_name?: string
  staff_id?: string | null
  /** a session from a customer package: the line is worth package_value, VAT was charged on the package */
  customer_package_id?: string | null; package_value?: number | null
  /** open order (table) line already sent to the kitchen */
  fired?: boolean
  /** gift card sold: the code of a pre-printed card (optional) */
  gift_code?: string
}
export interface TenderEntry { tender: Tender; amount: number; reference?: string; channel_id?: string; /** card network or wallet: K-Net, mada, Apple Pay… */ method?: string }

export interface RolePkg { tenant_id: string; key: string; name_en: string; name_ar: string; description_en: string | null; description_ar: string | null; template: string | null; is_system: boolean; sort: number }
export interface PermDef { key: string; module: string; name_en: string; name_ar: string; limit_kind: 'pct' | 'money' | null; sort: number }
export interface RoleTemplate { key: string; name_en: string; name_ar: string; description_en: string; description_ar: string; sort: number; perms: Record<string, number | null> }
export interface Station { id: string; tenant_id: string; branch_id: string; name: string; name_ar: string | null; mode: 'kds' | 'printer' | 'both'; alert_minutes: number; is_default: boolean; is_active: boolean; sort: number; printer_ip?: string | null; printer_port?: number; printer_width?: number }
export interface KitchenItem { id: string; name: string; name_ar: string | null; qty: number; note: string | null; done: boolean }
export interface KitchenTicket {
  id: string; station_id: string; sale_id: string | null; order_ref: string; order_type: 'dine_in' | 'takeaway' | 'delivery' | 'pickup'
  table_no: string | null; customer_name: string | null; note: string | null; status: 'new' | 'preparing' | 'ready' | 'served' | 'cancelled'
  created_at: string; started_at: string | null; ready_at: string | null; served_at: string | null; kitchen_ticket_items: KitchenItem[]
}
export interface Supplier { id: string; tenant_id: string; name: string; name_ar: string | null; phone: string | null; email: string | null; tax_number: string | null; payment_terms_days: number; is_active: boolean }
export interface PoLine { id: string; item_id: string; qty: number; unit_cost: number; received_qty: number }
export interface PurchaseOrder {
  id: string; tenant_id: string; branch_id: string; supplier_id: string; number: string
  status: 'draft' | 'approved' | 'partially_received' | 'received' | 'cancelled'; total: number; note: string | null
  created_by: string; approved_by: string | null; approved_at: string | null; created_at: string; cancelled_reason: string | null
  purchase_order_lines?: PoLine[]; suppliers?: { name: string } | null
}

export interface DeliveryChannel { id: string; tenant_id: string; branch_id: string; platform: string; display_name: string; store_ref: string | null; is_active: boolean; auto_accept: boolean; prep_minutes: number; commission_pct: number; webhook_token_hash: string | null }

export interface OnlineOrder { id: string; branch_id: string; table_id: string | null; source: 'qr' | 'kiosk'; number: number; name: string | null; phone: string | null; note: string | null
  lines: { key: string; item_id: string; name: string; qty: number; unit_price: number; modifiers: string[]; note: string | null }[]; total: number; status: string; created_at: string }
export interface DeliveryRow { id: string; branch_id: string; sale_id: string; customer_id: string | null; address: string | null; phone: string | null; note: string | null
  driver_id: string | null; status: 'pending' | 'assigned' | 'picked_up' | 'delivered' | 'failed'; cash_to_collect: number; cash_settled: boolean; created_at: string; sales?: { number: string; total: number } | null }
