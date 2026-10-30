-- LAB 06: Workshop  (ทำบน pg_with_index — index ที่สร้างเองให้ DROP ท้ายงาน)
\timing on

-- ============================================================================
-- โจทย์ 1: query นี้ช้า ให้ออกแบบ index แล้วพิสูจน์ด้วย EXPLAIN ANALYZE ก่อน/หลัง
-- ============================================================================
\echo '\n============================================================'
\echo 'โจทย์ 1: ก่อนสร้าง Index (วัด baseline)'
\echo '============================================================'
EXPLAIN ANALYZE
SELECT transaction_date, sum(amount)
FROM transactions
WHERE status = 'pending' AND transaction_date >= '2026-09-01'
GROUP BY transaction_date
ORDER BY transaction_date;

/*
  [การวิเคราะห์สาเหตุที่ Query ช้าก่อนมี Index]:
  - Query กรองด้วย status = 'pending' (equality) และ transaction_date >= '2026-09-01' (range)
  - Index เดิมมีแค่ idx_tx_date (transaction_date) และ idx_tx_customer (customer_id)
  - Planner ใช้ idx_tx_date สแกนช่วงวันที่ ทำให้ดึงข้อมูลขึ้นมาทั้งหมดรวมทุก status
    แล้วต้องมากรอง status = 'pending' ออกใน Heap Scan (Rows Removed by Filter: ~53,791 rows)
  - จากนั้นต้องเสียเวลา HashAggregate และ Quicksort อีกรอบ

  [แนวทางการออกแบบ Index]:
  - แนวทางที่ 1 (Composite Index): CREATE INDEX idx_tx_status_date ON transactions (status, transaction_date);
    ใช้หลักการ Equality First, Range Second ช่วยตัดข้อมูล status ที่ไม่ต้องการออกตั้งแต่ระดับ index
  - แนวทางที่ 2 (Covering Index / Index-Only Scan): CREATE INDEX idx_tx_status_date_amount ON transactions (status, transaction_date, amount);
    รวม column "amount" เข้าไปใน index ด้วย ทำให้ไม่ต้องกระโดดไปอ่าน Table Heap Blocks (Heap Fetches: 0)
    และได้ข้อมูลที่เรียงลำดับตาม transaction_date อยู่แล้ว จึงใช้ GroupAggregate ได้ทันทีโดยไม่ต้อง Quicksort!
*/

\echo '\n============================================================'
\echo 'โจทย์ 1: สร้าง Covering Index (status, transaction_date, amount)'
\echo '============================================================'
CREATE INDEX idx_tx_status_date_amount ON transactions (status, transaction_date, amount);
ANALYZE transactions;

\echo '\n============================================================'
\echo 'โจทย์ 1: หลังสร้าง Index (พิสูจน์ด้วย EXPLAIN ANALYZE)'
\echo '============================================================'
EXPLAIN ANALYZE
SELECT transaction_date, sum(amount)
FROM transactions
WHERE status = 'pending' AND transaction_date >= '2026-09-01'
GROUP BY transaction_date
ORDER BY transaction_date;

-- ลบ Index คืนสภาพตามข้อกำหนดของแล็บ
DROP INDEX idx_tx_status_date_amount;


-- ============================================================================
-- โจทย์ 2: ลูกค้า 5 อันดับที่ยอดสูงสุดในเดือน 2026-08
--           เขียน query เอง แล้วบอกว่า index ตัวไหนถูกใช้
-- ============================================================================
\echo '\n============================================================'
\echo 'โจทย์ 2: แสดงข้อมูลลูกค้า 5 อันดับที่ยอดสูงสุดในเดือน 2026-08'
\echo '============================================================'
SELECT customer_id, sum(amount) AS total_amount
FROM transactions
WHERE transaction_date BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY customer_id
ORDER BY total_amount DESC
LIMIT 5;

\echo '\n============================================================'
\echo 'โจทย์ 2: ตรวจสอบ Plan ด้วย EXPLAIN ANALYZE'
\echo '============================================================'
EXPLAIN ANALYZE
SELECT customer_id, sum(amount) AS total_amount
FROM transactions
WHERE transaction_date BETWEEN '2026-08-01' AND '2026-08-31'
GROUP BY customer_id
ORDER BY total_amount DESC
LIMIT 5;

/*
  [คำตอบข้อ 2]:
  - Query ที่เขียน:
      SELECT customer_id, sum(amount) AS total_amount
      FROM transactions
      WHERE transaction_date BETWEEN '2026-08-01' AND '2026-08-31'
      GROUP BY customer_id
      ORDER BY total_amount DESC
      LIMIT 5;
  - Index ที่ถูกใช้: "idx_tx_date" (Bitmap Index Scan on idx_tx_date)
  - เหตุผล:
    เงื่อนไขใน WHERE clause มีการกรองเฉพาะ transaction_date ในช่วงวันที่ '2026-08-01' ถึง '2026-08-31'
    Query Planner จึงเลือกใช้ idx_tx_date เพื่อดึงเฉพาะแถวที่เกิดขึ้นในเดือนสิงหาคม 2026
    จากนั้นนำมากรุ๊ปตาม customer_id และเรียงลำดับยอดเงินรวม (top-N heapsort) เพื่อตัดเหลือ 5 แถว
*/


-- ============================================================================
-- โจทย์ 3: แก้ query ด้านล่างให้ใช้ index ได้ (ห้ามสร้าง index เพิ่ม)
-- ============================================================================
\echo '\n============================================================'
\echo 'โจทย์ 3: Query เดิมที่ช้าเพราะใช้ฟังก์ชันครอบ Column (เกิด Seq Scan)'
\echo '============================================================'
EXPLAIN ANALYZE
SELECT * FROM transactions
WHERE to_char(transaction_date, 'YYYY-MM') = '2026-08';

/*
  [การวิเคราะห์สาเหตุ]:
  - Query เดิมใช้ to_char(transaction_date, 'YYYY-MM') = '2026-08'
  - การนำ function มาครอบ column ทำลายความสามารถของ B-tree Index (Index Invalidation)
    เพราะ index เก็บค่า raw date ไม่ได้เก็บผลลัพธ์ของ to_char() ทำให้ Planner ต้องทำ Parallel Seq Scan
*/

\echo '\n============================================================'
\echo 'โจทย์ 3: Query ที่แก้ไขแล้ว (ใช้ Range condition ตรงๆ ทำให้ใช้ idx_tx_date ได้)'
\echo '============================================================'
EXPLAIN ANALYZE
SELECT * FROM transactions
WHERE transaction_date >= '2026-08-01' AND transaction_date <= '2026-08-31';

/*
  [คำตอบข้อ 3]:
  - แก้ไขเป็น:
      SELECT * FROM transactions
      WHERE transaction_date >= '2026-08-01' AND transaction_date <= '2026-08-31';
      (หรือ WHERE transaction_date BETWEEN '2026-08-01' AND '2026-08-31')
  - ผลลัพธ์: เปลี่ยนจาก Parallel Seq Scan (~115 ms) มาเป็น Bitmap Index Scan on idx_tx_date (~25 ms)
    โดยไม่ต้องสร้าง Index ใหม่เพิ่มเติม
*/
