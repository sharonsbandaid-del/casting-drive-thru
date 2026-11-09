# Casting Drive-Thru

大廣 CR 部門 × Casting 公司的小演員預約平台。

- Casting 公司：維護演員庫（含肖像權期間、拍攝費、授權條件）、確認檔期、標記已拍攝、請款
- 大廣創意／業務：瀏覽演員、預約拍攝、取消／恢復素材、匯出契約者一覽表
- 每 7 個拍攝人次為一期，集滿即請款

技術：GitHub Pages（前端）＋ Supabase（資料庫、登入、照片儲存）

## 檔案

- `index.html`：網站畫面
- `app.js`：網站程式（登入、讀寫 Supabase）
- `config.js`：Supabase 網址與 publishable key（可公開；**secret key 絕對不能放進來**）
- `supabase/schema.sql`：資料庫結構與所有規則（全新安裝執行這個就好）
- `supabase/00x_*.sql`：舊版資料庫的升級檔，依序執行

## 角色

| 角色 | 誰 | 可以做 |
|---|---|---|
| casting | 三根木 | 維護演員庫、確認檔期、標記已拍攝、請款 |
| agency | 大廣創意、業務 | 預約、編輯、取消、刪除（需原因）、OA 日、發票日期、備考 |
| admin | Casting 管理者 | 以上全部＋刪除演員、撤銷請款、帳號管理 |

新帳號在 Supabase → Authentication → Users 建立，第一次登入後預設為 agency，由管理者在網站「帳號」分頁調整。
