/** Role package key (system templates or custom packages created by the owner). */
export type Role = string
export type BusinessType = 'retail' | 'food' | 'services' | 'mixed'
export type Tender = 'cash' | 'card' | 'on_account' | 'payment_link' | 'bank_transfer' | 'store_credit' | 'platform' | 'other'

export interface Country {
  code: string; name_en: string; name_ar: string; currency: string; currency_decimals: number
  vat_rate: number; prices_include_tax: boolean; einvoice_regime: string | null; default_language: string; timezone: string
}

export interface Tenant {
  id: string; name: string; name_ar: string | null; country_code: string; currency: string; currency_decimals: number
  default_language: string; business_type: BusinessType; tax_number: string | null; vat_rate: number
  prices_include_tax: boolean; brand_color: string | null; logo_url: string | null; plan: string; trial_ends_at: string
  settings?: TenantSettings
}

export interface TenantSettings {
  pos_show_images?: boolean
  receipt_phones?: string; receipt_address?: string; receipt_cr?: string; receipt_website?: string
  receipt_header?: string; receipt_footer?: string; receipt_terms?: string
}

export interface Membership {
  tenant_id: string; user_id: string; role: Role; display_name: string; branch_ids: string[] | null; is_active: boolean
  pin_hash?: string | null; tenants?: Tenant
}

export interface Branch { id: string; tenant_id: string; code: string; name: string; name_ar: string | null; timezone: string }
export interface Category { id: string; tenant_id: string; name: string; name_ar: string | null; color: string | null; sort: number; station_id?: string | null }

export interface Item {
  id: string; tenant_id: string; category_id: string | null; name: string; name_ar: string | null; sku: string | null
  barcode: string | null; price: number; cost: number; tax_rate: number | null; track_stock: boolean; is_active: boolean
  image_url: string | null; item_type?: 'standard' | 'ingredient' | 'recipe'; unit?: string; reorder_point?: number | null
}

export interface Customer { id: string; tenant_id: string; name: string; phone: string | null; email: string | null; credit_limit: number }

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
}
export interface TenderEntry { tender: Tender; amount: number; reference?: string; channel_id?: string }

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
