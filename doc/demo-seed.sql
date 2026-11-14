-- =====================================================================
-- DEMO DATA for the POS System (30 days of sample sales)
--
-- ⚠️  DEVELOPMENT / DEMO DATABASES ONLY. NEVER run on production.
--
-- Run (Linux/macOS):
--   docker compose exec -T db psql -U pos_user -d pos_db < docs/demo-seed.sql
-- Run (PowerShell):
--   Get-Content docs/demo-seed.sql | docker compose exec -T db psql -U pos_user -d pos_db
--
-- Before running: create two CASHIER accounts in the app (Staff page)
--   dara@shop.com and sokha@shop.com
-- so the "by cashier" report matches real users. (Orders only store the email text.)
--
-- Safe to run twice: products use ON CONFLICT, and the sales block is skipped
-- if demo sales already exist. Cleanup SQL is at the bottom.
-- =====================================================================

BEGIN;

-- ---------- Categories ----------
INSERT INTO categories (name, description) VALUES
    ('Drinks',  'Soft drinks and water'),
    ('Coffee',  'Hot and iced coffee'),
    ('Snacks',  'Chips, biscuits and chocolate'),
    ('Bakery',  'Fresh bread and cakes')
ON CONFLICT (name) DO NOTHING;

-- ---------- Products (500 units each; sales below deduct from this) ----------
INSERT INTO products (name, sku, barcode, price, cost_price, stock_quantity, low_stock_threshold, category_id)
SELECT v.name, v.sku, v.barcode, v.price, v.cost, 500, 10, c.id
FROM (VALUES
    ('Cola 330ml',         'DEMO-COLA',      '8850000000011', 0.75, 0.45, 'Drinks'),
    ('Orange Soda 330ml',  'DEMO-ORANGE',    '8850000000028', 0.75, 0.45, 'Drinks'),
    ('Mineral Water 500ml','DEMO-WATER',     '8850000000035', 0.40, 0.20, 'Drinks'),
    ('Iced Latte',         'DEMO-LATTE',     '8850000000042', 2.25, 0.90, 'Coffee'),
    ('Americano',          'DEMO-AMERICANO', '8850000000059', 1.75, 0.60, 'Coffee'),
    ('Cappuccino',         'DEMO-CAPPU',     '8850000000066', 2.50, 1.00, 'Coffee'),
    ('Potato Chips',       'DEMO-CHIPS',     '8850000000073', 1.20, 0.70, 'Snacks'),
    ('Butter Cookies',     'DEMO-COOKIES',   '8850000000080', 1.50, 0.85, 'Snacks'),
    ('Chocolate Bar',      'DEMO-CHOCO',     '8850000000097', 1.00, 0.55, 'Snacks'),
    ('Croissant',          'DEMO-CROISSANT', '8850000000103', 1.80, 0.80, 'Bakery'),
    ('Banana Cake Slice',  'DEMO-CAKE',      '8850000000110', 2.00, 0.90, 'Bakery'),
    ('Baguette',           'DEMO-BAGUETTE',  '8850000000127', 1.10, 0.45, 'Bakery')
) AS v(name, sku, barcode, price, cost, cat)
JOIN categories c ON c.name = v.cat
ON CONFLICT (sku) DO NOTHING;

-- ---------- Sales: 30 days × 4–12 orders/day, 1–3 lines each ----------
DO $$
DECLARE
    cashiers      text[] := ARRAY['admin@pos.com', 'dara@shop.com', 'sokha@shop.com'];
    methods       text[] := ARRAY['CASH', 'CASH', 'CASH', 'KHQR', 'CARD'];
    prod_ids      bigint[];
    day_offset    int;
    orders_today  int;
    n_items       int;
    oid           bigint;
    pid           bigint;
    pname         text;
    psku          text;
    pprice        numeric;
    qty           int;
    line_amt      numeric;
    subtotal_amt  numeric;
    tax_amt       numeric;
    total_amt     numeric;
    ts            timestamp;
    new_stock     int;
BEGIN
    IF EXISTS (SELECT 1 FROM order_items WHERE sku LIKE 'DEMO-%') THEN
        RAISE NOTICE 'Demo sales already exist. Skipping.';
        RETURN;
    END IF;

    SELECT array_agg(id) INTO prod_ids FROM products WHERE sku LIKE 'DEMO-%';
    IF prod_ids IS NULL THEN
        RAISE EXCEPTION 'No demo products found.';
    END IF;

    FOR day_offset IN REVERSE 29..0 LOOP
        orders_today := 4 + floor(random() * 9)::int;

        FOR o IN 1..orders_today LOOP
            ts := date_trunc('day', localtimestamp)
                  - make_interval(days => day_offset)
                  + make_interval(hours => 8 + floor(random() * 11)::int,
                                  mins  => floor(random() * 60)::int);
            IF ts > localtimestamp THEN
                CONTINUE;                     -- never create orders in the future
            END IF;

            INSERT INTO orders (order_number, cashier_email, subtotal, discount_amount, tax_rate, tax_amount,
                                total, payment_method, amount_paid, change_amount, status, created_at,
                                payment_currency, exchange_rate, total_khr)
            VALUES ('INV-' || to_char(ts, 'YYYYMMDD') || '-' || lpad(nextval('order_number_seq')::text, 6, '0'),
                    cashiers[1 + floor(random() * 3)::int],
                    0, 0, 10, 0, 0,
                    methods[1 + floor(random() * 5)::int],
                    0, 0, 'COMPLETED', ts, 'USD', 4100, 0)
            RETURNING id INTO oid;

            subtotal_amt := 0;
            n_items := 1 + floor(random() * 3)::int;

            FOR it IN 1..n_items LOOP
                pid := prod_ids[1 + floor(random() * array_length(prod_ids, 1))::int];
                qty := 1 + floor(random() * 3)::int;

                SELECT name, sku, price INTO pname, psku, pprice FROM products WHERE id = pid;
                line_amt := pprice * qty;

                INSERT INTO order_items (order_id, product_id, product_name, sku, unit_price, quantity, line_total)
                VALUES (oid, pid, pname, psku, pprice, qty, line_amt);

                UPDATE products SET stock_quantity = stock_quantity - qty
                 WHERE id = pid
                RETURNING stock_quantity INTO new_stock;

                INSERT INTO stock_movements (product_id, type, quantity, stock_after, reason, created_by, created_at)
                VALUES (pid, 'SALE', -qty, new_stock, 'Demo sale', 'admin@pos.com', ts);

                subtotal_amt := subtotal_amt + line_amt;
            END LOOP;

            tax_amt   := round(subtotal_amt * 0.10, 2);
            total_amt := subtotal_amt + tax_amt;

            UPDATE orders
               SET subtotal      = subtotal_amt,
                   tax_amount    = tax_amt,
                   total         = total_amt,
                   amount_paid   = CASE WHEN payment_method = 'CASH' THEN ceil(total_amt) ELSE total_amt END,
                   change_amount = CASE WHEN payment_method = 'CASH' THEN ceil(total_amt) - total_amt ELSE 0 END,
                   total_khr     = round(total_amt * 4100 / 100) * 100
             WHERE id = oid;
        END LOOP;
    END LOOP;
END $$;

-- Make two products "low stock" so the alert looks real on screenshots
UPDATE products SET stock_quantity = 4 WHERE sku IN ('DEMO-CROISSANT', 'DEMO-LATTE');

COMMIT;

-- =====================================================================
-- CLEANUP (uncomment and run to remove all demo data)
-- =====================================================================
-- BEGIN;
-- DELETE FROM stock_movements WHERE product_id IN (SELECT id FROM products WHERE sku LIKE 'DEMO-%');
-- DELETE FROM orders WHERE id IN (SELECT order_id FROM order_items WHERE sku LIKE 'DEMO-%');  -- items cascade
-- DELETE FROM products WHERE sku LIKE 'DEMO-%';
-- DELETE FROM categories
--  WHERE name IN ('Drinks', 'Coffee', 'Snacks', 'Bakery')
--    AND id NOT IN (SELECT category_id FROM products WHERE category_id IS NOT NULL);
-- COMMIT;
