# รายงานผลการทดลอง: Database Indexing Lab
**วิชา:** 8903316 Web Application Development  
**หัวข้อ:** การทำ Indexing ใน Database เพื่อจัดการข้อมูลขนาดใหญ่ (1,000,000 rows) และเพิ่มความเร็วในการ Query

---

## 1. ภาพรวมของระบบและสภาพแวดล้อมการทดลอง (Lab Environment)

การทดลองใช้ฐานข้อมูล PostgreSQL 16 จำนวน 2 ตัว รันผ่าน Docker Compose บนข้อมูลธุรกรรม (`transactions`) ปริมาณ **1,000,000 แถว** (ชุดข้อมูลเดียวกันด้วย `setseed(0.42)`):

| Service | Port | รายละเอียด Index | ประโยชน์ในการทดสอบ |
|---|---|---|---|
| `pg_with_index` | 5432 | Primary Key (`id`), `idx_tx_date` (`transaction_date`), `idx_tx_customer` (`customer_id`) | ตัวแทนระบบที่ออกแบบ Index ไว้รองรับ |
| `pg_no_index` | 5433 | มีเฉพาะ Primary Key (`id`) | ตัวแทนระบบที่ไม่มี Secondary Index (Baseline) |

### โครงสร้างตาราง `transactions`
```sql
CREATE TABLE transactions (
  id               BIGSERIAL PRIMARY KEY,
  transaction_date DATE           NOT NULL,
  customer_id      INT            NOT NULL,
  amount           NUMERIC(10, 2) NOT NULL,
  status           VARCHAR(10)    NOT NULL,
  description      VARCHAR(255)
);
```

---

## 2. ผลการทดลองแต่ละชุด (Lab Experiments 01 - 07)

### Lab 01: เปรียบเทียบ Query Plan และ Execution Time
รัน `01-explain.sql` เพื่อเปรียบเทียบการทำงานระหว่าง **ไม่มี Index** กับ **มี Index**:

| กรณีทดสอบ (Query Test) | `pg_no_index` (ไม่มี Index) | `pg_with_index` (มี Index) | ผลลัพธ์และการวิเคราะห์ |
|---|---|---|---|
| **Test 1: Exact match วันที่** (`transaction_date = '2026-09-10'`) | 23.72 ms<br>*(Parallel Seq Scan)* | 19.44 ms<br>*(Bitmap Index Scan)* | มี Index เร็วกว่า ใช้ `idx_tx_date` ช่วยระบุ block ที่มีข้อมูล |
| **Test 2: หาตามลูกค้า** (`customer_id = 42`) | 23.60 ms<br>*(Parallel Seq Scan)* | **0.50 ms**<br>*(Bitmap Index Scan)* | **เร็วกว่า ~47 เท่า!** เนื่องจากความหลากหลายของลูกค้าสูง (High Cardinality) Index กรองได้แม่นยำมาก |
| **Test 3: Range แคบ (7 วัน ≈ 2%)** | 24.48 ms<br>*(Parallel Seq Scan)* | 68.14 ms<br>*(Bitmap Index Scan)* | Range กว้างขึ้น ต้องเปิด Heap Blocks จำนวนมาก |
| **Test 4: Range กว้าง (6 เดือน ≈ 50%)** | 82.35 ms<br>*(Seq Scan)* | 84.65 ms<br>*(Bitmap Index Scan)* | เมื่อเลือกข้อมูลปริมาณมาก (~50%) Index ไม่ได้ช่วยให้เร็วขึ้นอย่างมีนัยสำคัญ เพราะต้องอ่านแทบทุก Block ของตาราง |
| **Test 5: COUNT ต่อวัน** (`count(*) WHERE transaction_date = ...`) | 18.38 ms<br>*(Parallel Seq Scan)* | **0.30 ms**<br>*(Index Only Scan)* | **เร็วกว่า ~61 เท่า!** อ่านนับจำนวนจาก Index Tree โดยตรง ไม่ต้องแตะ Table Heap เลย (Heap Fetches: 0) |

---

### Lab 01b: ทดสอบผลกระทบกับระบบงานจริง (Live Index Demo)
จำลองลูกค้า 100 คนเปิดหน้าประวัติการซื้อพร้อมกัน (`generate_series(1, 100)`):
- **ก่อนสร้าง Index (`pg_no_index`):** ใช้เวลาประมาณ **4 - 8 วินาที** (เกิด Sequential Scan ตาราง 1 ล้านแถว ซ้ำกัน 100 รอบ)
- **หลังสร้าง Index `idx_tx_customer`:** ใช้เวลาเหลือเพียง **0.015 วินาที (~15 ms)** (ลดลงกว่า 250 เท่า)

---

### Lab 02: ขนาดพื้นที่จัดเก็บ (Storage Cost of Indexes)
รัน `02-size.sql` เพื่อดู Overhead ของ Index ต่อพื้นที่ Disk:

| ฐานข้อมูล | ขนาด Table (`transactions`) | ขนาด Index ทั้งหมด | ขนาดรวม (Total) |
|---|---|---|---|
| `pg_no_index` | 68 MB | 21 MB (เฉพาะ PK) | 90 MB |
| `pg_with_index` | 68 MB | 35 MB (PK + 2 Indexes) | 103 MB |

> **สรุป:** การสร้าง Index เพิ่ม 2 ตัว (`idx_tx_date` ~7MB และ `idx_tx_customer` ~7MB) ทำให้ใช้พื้นที่ Disk เพิ่มขึ้นประมาณ **14 MB (~15%)**

---

### Lab 03: ต้นทุนในการเขียนข้อมูล (Write/INSERT Overhead)
รัน `03-insert-cost.sql` โดยการจำลอง Bulk INSERT ข้อมูลจำนวน **200,000 แถว**:
- **บน `pg_no_index`:** ใช้เวลา **539 ms** (อัปเดตเฉพาะ PK index 1 ตัว)
- **บน `pg_with_index`:** ใช้เวลา **1,340 ms** (1.34 วินาที)

> **ข้อสังเกต:** การมี Secondary Index เพิ่มขึ้น 2 ตัว ทำให้การ INSERT ข้อมูลช้าลงประมาณ **2.5 เท่า** เนื่องจาก Database Engine ต้องคำนวณและอัปเดต B-tree Index ทุกตัวตามแถวใหม่ที่เพิ่มเข้ามา

---

### Lab 04: ข้อผิดพลาดที่ทำให้มี Index แต่ไม่ถูกใช้งาน (Index Pitfalls)

| รูปแบบคำสั่งที่ผิดพลาด | ผลลัพธ์ Query Plan | สาเหตุและวิธีแก้ไขที่ถูกต้อง |
|---|---|---|
| **4.1 ใช้ฟังก์ชันครอบ Column**<br>`WHERE EXTRACT(MONTH FROM transaction_date) = 9` | **Parallel Seq Scan** (~60 ms) | **สาเหตุ:** B-tree เก็บค่า date ดิบ ไม่ได้เก็บผลลัพธ์ของฟังก์ชัน<br>**วิธีแก้:** เปรียบเทียบกับค่า date โดยตรง เช่น `WHERE transaction_date = '2026-09-10'` (ลดเหลือ ~2.2 ms) |
| **4.2 มีการคำนวณทางคณิตศาสตร์บน Column**<br>`WHERE customer_id + 0 = 42` | **Parallel Seq Scan** (~26 ms) | **สาเหตุ:** มี operation บน column ทำให้ไม่สามารถ search บน index tree ได้<br>**วิธีแก้:** ย้ายตัวคำนวณไปฝั่งขวา หรือเขียน `WHERE customer_id = 42` |
| **4.3 LIKE ขึ้นต้นด้วย Wildcard `%`**<br>`WHERE description LIKE '%12345'` | **Parallel Seq Scan** (~48 ms) | **สาเหตุ:** B-tree เรียงตามลำดับตัวอักษรจากซ้ายไปขวา ถ้าไม่รู้ตัวหน้าสุดจะไม่สามารถ traverse tree ได้<br>**เปรียบเทียบ:** ถ้าค้นแบบ Prefix `LIKE 'txn-12345%'` จะใช้ **Index Scan** ได้รวดเร็ว (~0.05 ms) |
| **4.4 Column ที่มีค่าซ้ำกันเยอะ (Low Cardinality)**<br>`WHERE status = 'paid'` (ครอบคลุม ~60% ของตาราง) | **Seq Scan** (~98 ms) | **สาเหตุ:** เมื่อเงื่อนไขคืนค่าแถวข้อมูลส่วนใหญ่ของตาราง Planner จะเลือก Seq Scan เพราะคุ้มกว่าการกระโดดอ่าน Index สลับกับ Table Block |

---

### Lab 05: Composite Index และ Leftmost Prefix Rule
ทดสอบ Composite Index: `(customer_id, transaction_date)`:
1. **ใช้ column ซ้ายสุด (`WHERE customer_id = 42`):**  
   ✅ ใช้งานได้ -> **Bitmap Index Scan** (~0.12 ms)
2. **ใช้ครบทั้งสอง column (`WHERE customer_id = 42 AND transaction_date >= ...`):**  
   ✅ ใช้งานได้เต็มประสิทธิภาพ -> **Bitmap Index Scan** (~0.03 ms)
3. **ข้าม column ซ้ายสุด (`WHERE transaction_date = '2026-09-10'`):**  
   ⚠️ **ไม่สามารถใช้ Composite Index ตัวนี้ได้** ตกไปเป็น **Parallel Seq Scan** (~16.5 ms)
4. **ORDER BY + LIMIT ตรงตามลำดับ Index (`WHERE customer_id = 42 ORDER BY transaction_date DESC LIMIT 10`):**  
   ✅ ใช้งานได้ดีเยี่ยม -> **Index Scan Backward** (~0.02 ms) **ไม่ต้องเสียเวลา Sort!**

---

### Lab 07: การเลือก Column ทำ Index / ทำไมไม่ทำทุก Column
- ตรวจสอบ Cardinality:
  - `customer_id`: 10,000 ค่า (ความหลากหลายสูงมาก เหมาะทำ Index)
  - `transaction_date`: 366 ค่า (ความหลากหลายปานกลาง เหมาะทำ Range Index)
  - `status`: 3 ค่า (ความหลากหลายต่ำมาก ไม่เหมาะทำ B-tree Index เดี่ยวๆ)
- หากสร้าง Index ทุก Column ขนาด Index จะพุ่งขึ้นเป็น **114 MB** (ใหญ่กว่าขนาดข้อมูลตารางจริง 94 MB) และทำให้การ INSERT ข้อมูลช้าลงอย่างมาก

---

## 3. เฉลยและผลการทำแบบฝึกหัด (Lab 06: Workshop)

### โจทย์ 1: ปรับปรุง Query ที่ช้าให้ออกแบบ Index และพิสูจน์ด้วย EXPLAIN ANALYZE

#### คำสั่ง Query ต้นฉบับ:
```sql
EXPLAIN ANALYZE
SELECT transaction_date, sum(amount)
FROM transactions
WHERE status = 'pending' AND transaction_date >= '2026-09-01'
GROUP BY transaction_date
ORDER BY transaction_date;
```

#### การวิเคราะห์ปัญหา:
- เงื่อนไขใน `WHERE` มีการกรอง 2 ส่วน คือ `status = 'pending'` (Equality) และ `transaction_date >= '2026-09-01'` (Range)
- เดิมมีเฉพาะ `idx_tx_date` ทำให้ Query Planner ดึงข้อมูลทุกรายการตั้งแต่วันที่ 2026-09-01 ขึ้นมาก่อน จากนั้นต้องมากรองแถวที่ไม่ใช่ `'pending'` ทิ้งใน Heap Scan (`Rows Removed by Filter: 53,791 rows`)
- จากนั้นต้องนำข้อมูลที่เหลือไปทำ `HashAggregate` และ `quicksort` อีกทอดหนึ่ง

#### การออกแบบ Index:
1. **แนวทางที่ 1 (Composite Index):** `CREATE INDEX idx_tx_status_date ON transactions (status, transaction_date);`  
   - วาง `status` ไว้ซ้ายสุดตามกฎ *Equality First, Range Second*
2. **แนวทางที่ 2 (Covering Index - แนะนำสำหรับ Best Performance):**  
   ```sql
   CREATE INDEX idx_tx_status_date_amount ON transactions (status, transaction_date, amount);
   ```
   - นำ `amount` มารวมใน Index ด้วย ทำให้ได้คุณสมบัติ **Index Only Scan** ไม่ต้องดึงข้อมูลจาก Table Heap เลย
   - เนื่องจาก Index เรียงลำดับตาม `transaction_date` ไว้อยู่แล้ว Database จึงใช้ **GroupAggregate** ได้ทันทีโดยไม่ต้องทำการ Sort เพิ่มเติม

#### ผลการเปรียบเทียบ ก่อน vs หลัง:

| การวัดผล | ก่อนสร้าง Index | หลังสร้าง Covering Index |
|---|---|---|
| **Query Plan** | Bitmap Heap Scan + HashAggregate + Quicksort | **Index Only Scan + GroupAggregate** |
| **Heap Blocks Fetches** | 8,743 Blocks | **0 Blocks (Heap Fetches: 0)** |
| **Rows Removed by Filter** | 53,791 Rows | **0 Rows** |
| **Execution Time** | **25.29 ms** (หรือ ~69 ms ก่อน cache) | **2.50 ms** |
| **ประสิทธิภาพ** | Baseline | **เร็วขึ้นกว่า 10 - 27 เท่า!** |

---

### โจทย์ 2: ลูกค้า 5 อันดับที่ยอดสูงสุดในเดือน 2026-08

#### คำสั่ง SQL ที่เขียน:
```sql
SELECT customer_id, sum(amount) AS total_amount
FROM transactions
WHERE transaction_date BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY customer_id
ORDER BY total_amount DESC
LIMIT 5;
```

#### ผลลัพธ์ข้อมูล (Top 5 Customers):
| อันดับ | `customer_id` | `total_amount` (ยอดรวม) |
|---|---|---|
| 1 | 2851 | 117,898.43 |
| 2 | 9702 | 116,587.58 |
| 3 | 9015 | 110,819.24 |
| 4 | 4067 | 108,755.59 |
| 5 | 2729 | 108,106.36 |

#### การตรวจสอบ Query Plan (`EXPLAIN ANALYZE`):
```text
Limit  (cost=12133.57..12133.58 rows=5 width=36) (actual time=35.955..35.958 rows=5 loops=1)
  ->  Sort  (cost=12133.57..12158.60 rows=10010 width=36) (actual time=35.954..35.956 rows=5 loops=1)
        Sort Key: (sum(amount)) DESC
        Sort Method: top-N heapsort  Memory: 25kB
        ->  HashAggregate  (cost=11842.18..11967.31 rows=10010 width=36) (actual time=32.647..34.396 rows=9997 loops=1)
              Group Key: customer_id
              Batches: 1  Memory Usage: 4241kB
              ->  Bitmap Heap Scan on transactions  (cost=1427.58..11425.03 rows=83430 width=10) (actual time=2.953..17.244 rows=85284 loops=1)
                    Recheck Cond: ((transaction_date >= '2026-08-01'::date) AND (transaction_date <= '2026-08-31'::date))
                    Heap Blocks: exact=8746
                    ->  Bitmap Index Scan on idx_tx_date  (cost=0.00..1406.73 rows=83430 width=0) (actual time=2.017..2.017 rows=85284 loops=1)
                          Index Cond: ((transaction_date >= '2026-08-01'::date) AND (transaction_date <= '2026-08-31'::date))
Execution Time: 35.994 ms
```

#### คำตอบและเหตุผล:
- **Index ตัวที่ถูกใช้งาน:** **`idx_tx_date`** (`Bitmap Index Scan on idx_tx_date`)
- **เหตุผล:**
  1. ในคำสั่งมีเงื่อนไขการกรอง (`WHERE clause`) อยู่ที่คอลัมน์ `transaction_date` ช่วง `'2026-08-01'` ถึง `'2026-08-31'`
  2. แม้ว่าตารางจะมี index `idx_tx_customer` แต่ `customer_id` ใน query นี้ถูกใช้สำหรับจัดกลุ่ม (`GROUP BY`) ไม่ได้ถูกใช้ในการกรองแถว
  3. Query Planner จึงเลือกใช้ `idx_tx_date` เพื่อคัดกรองแถวธุรกรรมทั้งหมดเฉพาะที่เกิดขึ้นในเดือนสิงหาคม 2026 (ดึงมา 85,284 แถว จาก 1 ล้านแถว) แล้วนำมาคำนวณหายอดรวมรายลูกค้าในหน่วยความจำด้วย HashAggregate

---

### โจทย์ 3: แก้ query ให้ใช้ index ได้ (ห้ามสร้าง index เพิ่ม)

#### คำสั่งเดิมที่มีปัญหา:
```sql
EXPLAIN ANALYZE
SELECT * FROM transactions
WHERE to_char(transaction_date, 'YYYY-MM') = '2026-08';
```
- **Query Plan เดิม:** `Parallel Seq Scan on transactions`
- **Execution Time เดิม:** **97.28 ms** (หรือ ~115 ms)
- **สาเหตุ:** การใช้ฟังก์ชัน `to_char(transaction_date, ...)` ครอบทับคอลัมน์ที่มี index ทำให้ B-tree index `idx_tx_date` ไม่สามารถถูกนำมาใช้ค้นหาได้ (Index Invalidation) ส่งผลให้ Database ต้องทำการ Sequential Scan กวาดอ่านทั้งตาราง 1,000,000 แถว

#### คำสั่งที่แก้ไขแล้ว:
```sql
EXPLAIN ANALYZE
SELECT * FROM transactions
WHERE transaction_date >= '2026-08-01' AND transaction_date <= '2026-08-31';
```
*(หรือเขียนในรูป `WHERE transaction_date BETWEEN '2026-08-01' AND '2026-08-31'`)*

#### ผลลัพธ์หลังแก้ไข:
```text
Bitmap Heap Scan on transactions  (cost=1427.58..11425.03 rows=83430 width=38) (actual time=3.756..18.147 rows=85284 loops=1)
  Recheck Cond: ((transaction_date >= '2026-08-01'::date) AND (transaction_date <= '2026-08-31'::date))
  Heap Blocks: exact=8746
  ->  Bitmap Index Scan on idx_tx_date  (cost=0.00..1406.73 rows=83430 width=0) (actual time=2.538..2.539 rows=85284 loops=1)
        Index Cond: ((transaction_date >= '2026-08-01'::date) AND (transaction_date <= '2026-08-31'::date))
Execution Time: 20.366 ms
```

#### สรุปผล:
- เปลี่ยนจาก **Parallel Seq Scan** กลายมาเป็น **Bitmap Index Scan on idx_tx_date**
- เวลาทำงานลดลงจาก **97.28 ms** เหลือเพียง **20.36 ms** (เร็วขึ้นเกือบ 5 เท่า) โดยไม่ต้องสร้าง Index ใหม่เพิ่มเติม

---

## 4. สรุปหลักการสำคัญของการทำ Database Indexing (Key Takeaways)

1. **เลือกทำ Index บนคอลัมน์ที่มี High Cardinality:** คอลัมน์ที่มีค่าไม่ซ้ำกันจำนวนมาก เช่น `id`, `customer_id` จะให้ผลดีที่สุดเมื่อทำ Index ส่วนคอลัมน์ Low Cardinality เช่น `status` มีเพียง 3 ค่า ไม่ควรทำ Index เดี่ยว
2. **เข้าใจกฎ Leftmost Prefix สำหรับ Composite Index:** หากสร้าง Index แบบผสม `(A, B)` จะสามารถค้นหาตาม `WHERE A = ...` หรือ `WHERE A = ... AND B = ...` ได้ แต่จะไม่สามารถค้นหาด้วย `WHERE B = ...` เพียงอย่างเดียวได้
3. **ระวัง Index Pitfalls:** หลีกเลี่ยงการนำ Function ไปครอบคอลัมน์ หรือการคำนวณทางคณิตศาสตร์บนคอลัมน์ใน WHERE clause เพราะจะทำให้ไม่สามารถใช้ Index ได้
4. **ประโยชน์ของ Index-Only Scan และ Covering Index:** หาก Index เก็บข้อมูลครบทุกคอลัมน์ที่ Query ต้องการ (`SELECT`, `WHERE`, `GROUP BY`, `ORDER BY`) Database Engine จะสามารถตอบ Query ได้จากโครงสร้าง Index โดยตรงโดยไม่ต้องเสียเวลาไปเปิด Table Block (Heap Blocks)
5. **Trade-off ระหว่าง Read vs Write:** ทุก Index ที่สร้างขึ้นจะช่วยให้การอ่านข้อมูล (`SELECT`) เร็วขึ้นอย่างมหาศาล แต่แลกมาด้วยพื้นที่ Disk ที่เพิ่มขึ้น และการเขียนข้อมูล (`INSERT`, `UPDATE`, `DELETE`) ที่ช้าลงเสมอ จึงควรสร้างเฉพาะ Index ที่จำเป็นต่อรูปแบบการใช้งานจริงของระบบ

